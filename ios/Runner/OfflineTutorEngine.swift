import Foundation
import LiteRTLM
import os

/// On-device Gemma inference through the official LiteRT-LM Swift SDK (0.18.1).
///
/// All lifecycle and concurrency rules live in the shared, tested
/// `OfflineTutorRuntimeCore` (`ios/OfflineTutorShared/OfflineTutorLifecycle.swift`).
/// This file only adapts LiteRT-LM to its backend protocols.
///
/// Native lifetime: the SDK's stream context retains its `Conversation`, which
/// retains its `Engine`, until the native layer sends the final chunk (it always
/// sends a `CANCELLED` final chunk after `cancel()`). Dropping our references
/// during a stream is therefore safe; native handles are freed after the stream.
enum OfflineTutorRuntime {
  static let shared = OfflineTutorRuntimeCore(loader: { @Sendable modelURL, modelBytes, cacheURL in
    try await OfflineTutorLiteRTEngine.load(modelURL: modelURL, modelBytes: modelBytes, cacheURL: cacheURL)
  })
}

final class OfflineTutorLiteRTEngine: OfflineTutorEngineHandle, @unchecked Sendable {
  private static let logger = Logger(subsystem: "app.veea.english", category: "OfflineTutor")

  private let engine: Engine
  /// From the model's own metadata (`ModelInfo`), read once per load.
  private let supportsThinking: Bool
  private let lock = NSLock()
  /// Cleared if the runtime refuses a constrained-decoding conversation; output is
  /// still validated by `OfflineTutorOutputParser` either way.
  private var useConstrainedDecoding = true

  /// Diagnostics for the developer smoke test only.
  var constrainedDecodingActive: Bool { lock.withLock { useConstrainedDecoding } }

  private init(engine: Engine, supportsThinking: Bool) {
    self.engine = engine
    self.supportsThinking = supportsThinking
  }

  static func load(modelURL: URL, modelBytes: Int64, cacheURL: URL) async throws -> any OfflineTutorEngineHandle {
    #if os(iOS)
    let available = UInt64(os_proc_available_memory())
    #else
    // Developer smoke test on a Mac host only; iOS always uses the per-process probe.
    let available = ProcessInfo.processInfo.physicalMemory
    #endif
    guard OfflineTutorDevicePolicy.hasLoadHeadroom(availableBytes: available) else {
      throw OfflineTutorError(.insufficientMemory)
    }
    try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    guard let info = ModelInfo(modelPath: modelURL.path), info.isLlmModel(), info.inputModalities.vision else {
      throw OfflineTutorError(.invalidModel)
    }
    let thinking = info.llm?.supportsThinking() ?? false

    // GPU first (the manifest's preferred accelerator), CPU as a local fallback.
    for backend in [Backend.gpu, Backend.cpu()] {
      do {
        let config = try EngineConfig(
          modelPath: modelURL.path, backend: backend, visionBackend: backend,
          maxNumTokens: OfflineTutorLimits.maxContextTokens, cacheDir: cacheURL.path)
        let candidate = Engine(engineConfig: config)
        try await candidate.initialize()
        logger.info("Tutor engine ready on \(backend.rawValue, privacy: .public)")
        return OfflineTutorLiteRTEngine(engine: candidate, supportsThinking: thinking)
      } catch {
        logger.error("Tutor engine init failed on \(backend.rawValue, privacy: .public)")
      }
    }
    throw OfflineTutorError(.modelLoadFailed)
  }

  /// Reasoning is disabled for models that support it; nil leaves others untouched.
  private var thinkingOff: ThinkingConfig? {
    supportsThinking ? ThinkingConfig(enableThinking: false) : nil
  }

  private static var sampler: SamplerConfig? {
    try? SamplerConfig(
      topK: OfflineTutorLimits.samplerTopK, topP: OfflineTutorLimits.samplerTopP,
      temperature: OfflineTutorLimits.samplerTemperature)
  }

  func makeSession(image: Data, history: [OfflineTutorSceneTurn]) async throws -> any OfflineTutorChatSession {
    // A rebuild replays completed turns: the first user turn carries the image.
    var initial: [Message] = []
    for (index, turn) in history.enumerated() {
      if index == 0 {
        initial.append(Message(contents: [.imageData(image), .text(OfflineTutorPrompt.sceneTurn(question: turn.question))]))
      } else {
        initial.append(Message(OfflineTutorPrompt.followUpTurn(question: turn.question)))
      }
      initial.append(Message(turn.answerJSON, role: .model))
    }
    func config(constrained: Bool) -> ConversationConfig {
      ConversationConfig(
        systemMessage: Message(OfflineTutorPrompt.systemInstruction, role: .system),
        initialMessages: initial,
        samplerConfig: Self.sampler,
        thinkingConfig: thinkingOff,
        automaticToolCalling: false,
        enableResponseFormat: constrained)
    }
    if constrainedDecodingActive {
      do {
        let conversation = try await engine.createConversation(with: config(constrained: true))
        return OfflineTutorLiteRTSession(conversation: conversation, constrained: true, thinkingOff: thinkingOff)
      } catch {
        Self.logger.error("Constrained tutor conversation unavailable; using validated free-form JSON")
        lock.withLock { useConstrainedDecoding = false }
      }
    }
    do {
      let conversation = try await engine.createConversation(with: config(constrained: false))
      return OfflineTutorLiteRTSession(conversation: conversation, constrained: false, thinkingOff: thinkingOff)
    } catch {
      Self.logger.error("Tutor conversation creation failed")
      throw OfflineTutorError(.modelLoadFailed)
    }
  }
}

final class OfflineTutorLiteRTSession: OfflineTutorChatSession, @unchecked Sendable {
  private let conversation: Conversation
  private let constrained: Bool
  private let thinkingOff: ThinkingConfig?

  init(conversation: Conversation, constrained: Bool, thinkingOff: ThinkingConfig?) {
    self.conversation = conversation
    self.constrained = constrained
    self.thinkingOff = thinkingOff
  }

  func tokenCount() -> Int? { try? conversation.getTokenCount() }

  func cancel() { try? conversation.cancel() }

  func send(_ input: OfflineTutorTurnInput) -> AsyncThrowingStream<String, Error> {
    let message: Message
    switch input {
    case .scene(let image, let prompt): message = Message(contents: [.imageData(image), .text(prompt)])
    case .followUp(let prompt): message = Message(prompt)
    }
    // The string overload keeps the schema's property order (see responseSchemaJSON).
    let format = constrained ? try? ResponseFormat.json(schema: OfflineTutorPrompt.responseSchemaJSON) : nil
    // The SDK starts native generation synchronously here, before any suspension,
    // so a cancel issued after `send` returns always reaches a started stream.
    let upstream = conversation.sendMessageStream(
      message, maxOutputTokens: OfflineTutorLimits.maxOutputTokens,
      thinkingConfig: thinkingOff, responseFormat: format)
    return AsyncThrowingStream { continuation in
      let pump = Task {
        do {
          // Visible text content only; thought/tool channels are ignored.
          for try await chunk in upstream { continuation.yield(chunk.toString) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: Self.map(error))
        }
      }
      continuation.onTermination = { _ in pump.cancel() }
    }
  }

  /// Native messages are matched here and never forwarded to Flutter.
  private static func map(_ error: Error) -> OfflineTutorError {
    let native = (error as? LiteRTLMError)?.errorDescription ?? String(describing: error)
    if OfflineTutorConversationPolicy.isCancellation(nativeMessage: native) { return OfflineTutorError(.cancelled) }
    if OfflineTutorConversationPolicy.isContextExhausted(nativeMessage: native) { return OfflineTutorError(.contextFull) }
    return OfflineTutorError(.inferenceFailed)
  }
}
