// Lifecycle and concurrency core for the offline camera tutor.
//
// Foundation-only and backend-agnostic: the production LiteRT-LM adapter lives in
// `ios/Runner/OfflineTutorEngine.swift`, and the native tests drive this exact
// code with a scripted fake backend (`tool/test_offline_tutor.sh`) to exercise
// rapid cancel/reset/unload/reopen interleavings.

import Foundation

// MARK: - Cancellation token

/// One user-visible operation (download, import). Thread-safe, one-way.
final class OfflineTutorCancelToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }

  func cancel() { lock.withLock { cancelled = true } }
}

// MARK: - Ordered control operations

/// FIFO chain for runtime control operations (cancel, reset, unload).
///
/// Each enqueued operation starts only after every earlier one finished, so an
/// old session's reset/unload can never run after a newer session's work that
/// was ordered behind it. Asks capture `tail` when issued and await it before
/// touching the runtime, but are not themselves part of the chain, so a later
/// cancel is never queued behind a long generation.
final class OfflineTutorControlChain: @unchecked Sendable {
  private let lock = NSLock()
  private var last: Task<Void, Never>?

  /// The most recently enqueued operation (nil when none was ever enqueued).
  var tail: Task<Void, Never>? { lock.withLock { last } }

  @discardableResult
  func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    lock.withLock {
      let previous = last
      let task = Task {
        await previous?.value
        await operation()
      }
      last = task
      return task
    }
  }
}

// MARK: - Backend abstraction

struct OfflineTutorSceneTurn: Sendable, Equatable {
  let question: String
  /// Model-facing JSON (`OfflineTutorAnswer.modelTurnJSON`).
  let answerJSON: String
}

enum OfflineTutorTurnInput: Sendable, Equatable {
  /// First user turn of a conversation: the image plus the scene prompt.
  case scene(image: Data, prompt: String)
  case followUp(prompt: String)
}

/// A loaded model. Implementations must be safe to release while a session
/// created from it is still streaming (LiteRT-LM retains its engine per stream).
protocol OfflineTutorEngineHandle: AnyObject, Sendable {
  /// Creates a conversation whose history replays `history` (the first replayed
  /// user turn carries `image`).
  func makeSession(image: Data, history: [OfflineTutorSceneTurn]) async throws -> any OfflineTutorChatSession
}

protocol OfflineTutorChatSession: AnyObject, Sendable {
  /// Tokens currently in the KV cache, or nil when unknown.
  func tokenCount() -> Int?
  /// Streams visible text. Errors are `OfflineTutorError`: `.cancelled` after
  /// `cancel()`, `.contextFull`, or `.inferenceFailed`.
  func send(_ input: OfflineTutorTurnInput) -> AsyncThrowingStream<String, Error>
  /// Interrupts a running `send`; its stream then ends with `.cancelled`.
  func cancel()
}

typealias OfflineTutorEngineLoader = @Sendable (
  _ modelURL: URL, _ modelBytes: Int64, _ cacheURL: URL
) async throws -> any OfflineTutorEngineHandle

// MARK: - Runtime core

/// Owns the engine, the live conversation and the retained scene.
///
/// - `load` and `ask` hold an exclusive FIFO lock for their whole duration (the
///   actor is reentrant across `await`), so two never interleave and a new ask
///   never touches the engine while a cancelled stream is still unwinding.
/// - `cancel`, `reset` and `unload` never take the lock: they must interrupt.
///   They bump `epoch`, cancel the active stream and mutate state immediately.
/// - Every ask carries a `ticket` (the epoch observed after the caller's earlier
///   control operations completed). A queued ask whose ticket is stale is
///   rejected as `.cancelled` the moment it gets the lock, and a running ask
///   re-checks after every suspension, so a late result can never repopulate a
///   scene that was reset or unloaded.
actor OfflineTutorRuntimeCore {
  private let loader: OfflineTutorEngineLoader
  private let timeoutNanoseconds: UInt64

  private var engine: (any OfflineTutorEngineHandle)?
  private var loadedModelBytes: Int64?
  private var conversation: (any OfflineTutorChatSession)?
  private var sceneImage: Data?
  private var sceneTurns: [OfflineTutorSceneTurn] = []
  private var activeSession: (any OfflineTutorChatSession)?
  private var timedOut = false
  private var overflowed = false
  private var epoch: UInt64 = 0
  private var loadEpoch: UInt64 = 0

  private var locked = false
  private var lockWaiters: [CheckedContinuation<Void, Never>] = []

  init(loader: @escaping OfflineTutorEngineLoader,
       timeoutSeconds: TimeInterval = OfflineTutorLimits.inferenceTimeoutSeconds) {
    self.loader = loader
    self.timeoutNanoseconds = UInt64(max(0.001, timeoutSeconds) * 1_000_000_000)
  }

  // MARK: Exclusive lock (FIFO)

  private func acquire() async {
    if !locked { locked = true; return }
    await withCheckedContinuation { lockWaiters.append($0) }
  }

  private func release() {
    if lockWaiters.isEmpty { locked = false } else { lockWaiters.removeFirst().resume() }
  }

  // MARK: Observation (tests and the channel)

  var isLoaded: Bool { engine != nil }
  var hasScene: Bool { sceneImage != nil }
  var completedTurns: Int { sceneTurns.count }
  var hasLiveConversation: Bool { conversation != nil }
  /// The ticket an ask must present; read after awaiting earlier control work.
  var ticket: UInt64 { epoch }
  /// The ticket a load must present; changes only on `unload` (dispose, memory
  /// warning, model replacement), not on `cancel`/`reset`.
  var loadTicket: UInt64 { loadEpoch }

  // MARK: Lifecycle

  /// Loads the model unless an equal one is loaded. With `loadTicket`, a load
  /// requested before an `unload` (for example by an ask from a tutor session
  /// that was disposed while this load waited for the lock) is refused, and one
  /// that was already initializing is discarded, so a closed tutor never ends up
  /// holding the model. Cancellation never waits for this: `unload` does not
  /// take the lock.
  func load(modelURL: URL, modelBytes: Int64, cacheURL: URL, loadTicket: UInt64? = nil) async throws {
    await acquire()
    defer { release() }
    if let loadTicket, loadTicket != loadEpoch { throw OfflineTutorError(.cancelled) }
    if engine != nil, loadedModelBytes == modelBytes { return }
    dropEngine()
    let startLoadEpoch = loadEpoch
    let handle = try await loader(modelURL, modelBytes, cacheURL)
    // Unloaded or disposed while initializing: discard instead of resurrecting.
    guard loadEpoch == startLoadEpoch else { throw OfflineTutorError(.cancelled) }
    engine = handle
    loadedModelBytes = modelBytes
  }

  /// Releases the model. The scene (image + completed turns) is kept so a later
  /// load can rebuild the conversation; `reset` clears it.
  func unload() {
    epoch &+= 1
    loadEpoch &+= 1
    dropEngine()
  }

  private func dropEngine() {
    activeSession?.cancel()
    conversation = nil
    engine = nil
    loadedModelBytes = nil
  }

  /// Cancels generation and forgets the conversation, scene image and history.
  func reset() {
    epoch &+= 1
    activeSession?.cancel()
    conversation = nil
    sceneImage = nil
    sceneTurns = []
  }

  /// Cancels generation. An interrupted turn leaves the KV cache in an unknown
  /// state, so the live conversation is dropped while the scene image and the
  /// completed turns are kept; the next follow-up rebuilds the conversation.
  /// An idle completed conversation is kept untouched.
  func cancel() {
    epoch &+= 1
    if let active = activeSession {
      active.cancel()
      conversation = nil
    }
  }

  // MARK: Ask

  /// Runs one tutor turn and returns canonical contract JSON.
  func ask(question: String, newImage: Data?, ticket: UInt64) async throws -> String {
    await acquire()
    defer { release() }
    guard epoch == ticket else { throw OfflineTutorError(.cancelled) }
    let startEpoch = epoch
    func ensureCurrent() throws { if epoch != startEpoch { throw OfflineTutorError(.cancelled) } }

    guard let engine else { throw OfflineTutorError(.modelMissing) }
    let plan: OfflineTutorTurnPlan
    switch OfflineTutorConversationPolicy.plan(
      hasNewImage: newImage != nil, hasLiveConversation: conversation != nil,
      hasRetainedScene: sceneImage != nil, completedTurns: sceneTurns.count)
    {
    case .success(let value): plan = value
    case .failure(let error): throw error
    }

    let target: any OfflineTutorChatSession
    let input: OfflineTutorTurnInput
    switch plan {
    case .newScene:
      guard let image = newImage else { throw OfflineTutorError(.invalidImage) }
      // A new photo replaces the old scene whether or not this turn succeeds.
      conversation = nil
      sceneImage = nil
      sceneTurns = []
      target = try await engine.makeSession(image: image, history: [])
      try ensureCurrent()
      sceneImage = image
      input = .scene(image: image, prompt: OfflineTutorPrompt.sceneTurn(question: question))
    case .rebuildScene:
      guard let image = sceneImage else { throw OfflineTutorError(.noScene) }
      let history = sceneTurns
      target = try await engine.makeSession(image: image, history: history)
      try ensureCurrent()
      input = history.isEmpty
        ? .scene(image: image, prompt: OfflineTutorPrompt.sceneTurn(question: question))
        : .followUp(prompt: OfflineTutorPrompt.followUpTurn(question: question))
    case .followUp:
      guard let live = conversation else { throw OfflineTutorError(.noScene) }
      let used = live.tokenCount() ?? OfflineTutorLimits.maxContextTokens
      guard OfflineTutorConversationPolicy.fitsContext(currentTokens: used, questionCharacters: question.count) else {
        throw OfflineTutorError(.contextFull)
      }
      target = live
      input = .followUp(prompt: OfflineTutorPrompt.followUpTurn(question: question))
    }
    conversation = target

    let raw = try await stream(input, on: target)
    try ensureCurrent()
    switch OfflineTutorOutputParser.parse(raw) {
    case .success(let answer):
      let asked = question.isEmpty ? OfflineTutorAskRequest.defaultSceneQuestion : question
      sceneTurns.append(OfflineTutorSceneTurn(question: asked, answerJSON: answer.modelTurnJSON()))
      return answer.jsonString()
    case .failure(let error):
      // The unusable model turn is now in the KV cache; rebuild cleanly next time.
      conversation = nil
      throw error
    }
  }

  private func stream(_ input: OfflineTutorTurnInput, on target: any OfflineTutorChatSession) async throws -> String {
    activeSession = target
    timedOut = false
    overflowed = false
    defer { activeSession = nil }

    let nanoseconds = timeoutNanoseconds
    let timeout = Task { [weak self] in
      try await Task.sleep(nanoseconds: nanoseconds)
      await self?.fireTimeout(for: target)
    }
    defer { timeout.cancel() }

    var text = ""
    do {
      for try await chunk in target.send(input) {
        text += chunk
        if text.utf8.count > OfflineTutorLimits.maxRawOutputBytes, !overflowed {
          overflowed = true
          target.cancel()
        }
      }
    } catch {
      // Only this ask can have set `conversation` (it holds the lock); a
      // concurrent cancel/reset/unload has already cleared it.
      conversation = nil
      let code = (error as? OfflineTutorError)?.code ?? .inferenceFailed
      if code == .cancelled {
        if overflowed { throw OfflineTutorError(.invalidOutput) }
        throw OfflineTutorError(timedOut ? .inferenceTimeout : .cancelled)
      }
      throw OfflineTutorError(code == .contextFull ? .contextFull : .inferenceFailed)
    }
    if overflowed || timedOut {
      conversation = nil
      throw OfflineTutorError(overflowed ? .invalidOutput : .inferenceTimeout)
    }
    return text
  }

  private func fireTimeout(for target: any OfflineTutorChatSession) {
    guard let active = activeSession, active === target else { return }
    timedOut = true
    target.cancel()
  }
}

// MARK: - Camera intent

/// Whether the tutor camera should be running. Main-thread state only.
///
/// - `explicitlyPaused` is set by Flutter `pause` (frozen scene, studying,
///   choosing a photo) and cleared only by Flutter `resume` or `dispose`.
/// - `backgrounded` follows the app; returning to the foreground restores the
///   camera only if Flutter had not paused it and a preview is attached.
/// - Without an attached preview the camera never runs and no permission
///   prompt is shown.
struct OfflineTutorCameraIntent: Equatable, Sendable {
  var attachedViews = 0
  var explicitlyPaused = false
  var backgrounded = false

  var wantsRunning: Bool { attachedViews > 0 && !explicitlyPaused && !backgrounded }

  /// Tutor closed: forget views and Flutter's pause; app state is kept.
  mutating func dispose() {
    attachedViews = 0
    explicitlyPaused = false
  }
}
