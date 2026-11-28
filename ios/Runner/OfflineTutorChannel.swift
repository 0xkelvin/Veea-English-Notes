import Flutter
import Foundation
import UIKit

/// Flutter bridge for the offline camera tutor.
///
/// MethodChannel `veea/offline_tutor`, EventChannel `veea/offline_tutor/events`,
/// platform view `veea/camera_tutor_preview`. All Flutter calls arrive and complete
/// on the main thread. Every pending `ask`/`importModel`/`downloadModel` result is
/// completed exactly once: by its own outcome, or with `CANCELLED`.
///
/// Ordering: runtime control work (cancel, reset, unload) goes through one FIFO
/// `OfflineTutorControlChain`. `cancel`, `reset`, `pause` and `dispose` reply only
/// after their runtime step finished, and an `ask` starts only after every control
/// step issued before it, then presents a runtime ticket, so a late reset/unload
/// from an older scene or session can never erase newer work.
///
/// Model operations (Files import, pinned download, remove) are mutually
/// exclusive with each other and with `ask` (`BUSY`).
///
/// Nothing here logs questions, photos, transcripts, answers or file paths.
final class OfflineTutorPlugin: NSObject, FlutterStreamHandler {
  static let methodChannelName = "veea/offline_tutor"
  static let eventChannelName = "veea/offline_tutor/events"

  private let store = OfflineTutorModelStore.shared
  private let runtime = OfflineTutorRuntime.shared
  private let camera = OfflineTutorCamera.shared
  private let dictation = OfflineTutorDictation()
  private let speaker = OfflineTutorSpeaker()
  private let control = OfflineTutorControlChain()

  private enum ModelOperation: Equatable { case idle, importing, downloading, removing }

  private final class DownloadJob {
    let token = OfflineTutorCancelToken()
    let downloader: OfflineTutorModelDownloader
    var result: FlutterResult?
    var throttle = OfflineTutorProgressThrottle()
    var settled = false
    var settleWaiters: [() -> Void] = []
    var savedIdleTimer: Bool?

    init(store: OfflineTutorModelStore, result: @escaping FlutterResult) {
      downloader = OfflineTutorModelDownloader(store: store, token: token)
      self.result = result
    }
  }

  private var eventSink: FlutterEventSink?
  private var gate = OfflineTutorRequestGate()
  private var pendingAsk: (requestId: Int, generation: UInt64, result: FlutterResult)?
  private var operation = ModelOperation.idle
  private var operationCounter: UInt64 = 0
  private var pendingImport: (id: UInt64, token: OfflineTutorCancelToken, result: FlutterResult)?
  private var download: DownloadJob?
  private var picker: OfflineTutorModelPicker?
  private var observers: [NSObjectProtocol] = []
  /// Bumped by dispose so late async work never touches a newer tutor session.
  private var lifecycle: UInt64 = 0

  static func register(with registrar: FlutterPluginRegistrar) -> OfflineTutorPlugin {
    let plugin = OfflineTutorPlugin()
    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
    methods.setMethodCallHandler { [weak plugin] call, result in
      guard let plugin else { result(FlutterMethodNotImplemented); return }
      plugin.handle(call, result: result)
    }
    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: registrar.messenger())
    events.setStreamHandler(plugin)
    registrar.register(OfflineTutorPreviewFactory(camera: plugin.camera), withId: OfflineTutorPreviewFactory.viewType)
    plugin.wire()
    return plugin
  }

  private func wire() {
    let sink: OfflineTutorEventSink = { [weak self] event in self?.send(event) }
    dictation.emit = sink
    speaker.emit = sink
    camera.onError = { [weak self] error in self?.send(OfflineTutorEvents.error(error)) }
    store.cleanStaging()
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.enterBackground() })
    observers.append(center.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // Restores the camera only if a preview is attached and Flutter has not
      // paused it (a frozen scene stays frozen; a closed tutor stays off).
      self?.camera.setBackgrounded(false)
    })
    observers.append(center.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.releaseModelForMemory() })
  }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  // MARK: Events

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func send(_ event: [String: Any]) {
    if Thread.isMainThread { eventSink?(event) } else { DispatchQueue.main.async { self.eventSink?(event) } }
  }

  private func modelEvent(_ state: String) { send(["type": "model", "state": state]) }

  // MARK: Dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStatus": result(currentStatus().channelMap)
    case "importModel": importModel(result)
    case "downloadModel": downloadModel(result)
    case "cancelModelDownload": cancelModelDownload(result)
    case "removeModel": removeModel(result)
    case "capturePhoto": capturePhoto(result)
    case "ask": ask(call.arguments, result: result)
    case "cancel":
      interruptAsk()
      runControl(reply: result) { runtime in await runtime.cancel() }
    case "reset":
      interruptAsk()
      runControl(reply: result) { runtime in await runtime.reset() }
    case "startListening": startListening(call.arguments, result: result)
    case "stopListening": dictation.stop(sendFinal: true); result(nil)
    case "speak": speak(call.arguments, result: result)
    case "stopSpeaking": speaker.stop(); result(nil)
    case "pause": pause(result)
    case "resume": camera.resume(); result(nil)
    case "dispose": dispose(result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func flutterError(_ error: Error) -> FlutterError {
    let tutorError = (error as? OfflineTutorError) ?? OfflineTutorError(.inferenceFailed)
    return FlutterError(code: tutorError.code.rawValue, message: tutorError.message, details: nil)
  }

  private func cancelledError() -> FlutterError { flutterError(OfflineTutorError(.cancelled)) }

  /// Enqueues runtime control work in order; replies (if given) after it ran.
  private func runControl(
    reply: FlutterResult? = nil, _ operation: @escaping @Sendable (OfflineTutorRuntimeCore) async -> Void
  ) {
    let runtime = self.runtime
    let task = control.enqueue { await operation(runtime) }
    guard let reply else { return }
    Task {
      await task.value
      await MainActor.run { reply(nil) }
    }
  }

  // MARK: Status

  private static var deviceFacts: OfflineTutorDeviceFacts {
    #if targetEnvironment(simulator)
    let simulator = true
    #else
    let simulator = false
    #endif
    return OfflineTutorDeviceFacts(
      isSimulator: simulator,
      osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
  }

  private func currentStatus(message: String? = nil) -> OfflineTutorStatus {
    // The LiteRT-LM SDK is statically linked into this target, so the runtime is
    // present whenever the device itself is supported.
    OfflineTutorStatus.make(
      facts: Self.deviceFacts, runtimeLinked: true, modelBytes: store.installedModelBytes(),
      speechLocales: OfflineTutorDictation.availableLocales(), overrideMessage: message)
  }

  private var modelWorkBusy: Bool { operation != .idle || pendingAsk != nil || store.isImporting }

  private func nextOperationId() -> UInt64 {
    operationCounter &+= 1
    return operationCounter
  }

  // MARK: Model import (Files)

  private func importModel(_ result: @escaping FlutterResult) {
    let status = currentStatus()
    // Never copy gigabytes onto a phone that cannot run the model.
    guard status.canRun else {
      result(flutterError(OfflineTutorError(.unsupportedDevice, message: status.message))); return
    }
    guard !modelWorkBusy else { result(flutterError(OfflineTutorError(.busy))); return }
    guard let presenter = topViewController() else {
      result(flutterError(OfflineTutorError(.importFailed))); return
    }
    let id = nextOperationId()
    let token = OfflineTutorCancelToken()
    operation = .importing
    pendingImport = (id, token, result)
    let picker = OfflineTutorModelPicker()
    self.picker = picker
    picker.present(from: presenter) { [weak self] url in
      guard let self else { return }
      if self.picker === picker { self.picker = nil }
      // Disposed or otherwise finished while the picker was open: ignore the pick.
      guard self.pendingImport?.id == id, !token.isCancelled else { return }
      guard let url else { self.finishImport(id, value: nil); return }
      self.modelEvent("importing")
      let store = self.store
      // Release the engine (it maps the old file) before replacing the model.
      let unload = self.control.enqueue { [runtime = self.runtime] in
        await runtime.cancel()
        await runtime.unload()
      }
      Task {
        await unload.value
        let outcome: Result<Int64, Error> = await Task.detached(priority: .userInitiated) {
          do { return .success(try store.importModel(from: url, token: token)) } catch { return .failure(error) }
        }.value
        await MainActor.run {
          switch outcome {
          case .success:
            self.modelEvent("imported")
            self.finishImport(id, value: self.currentStatus().channelMap)
          case .failure(let error):
            self.modelEvent("importFailed")
            self.finishImport(id, value: self.flutterError(error))
          }
        }
      }
    }
  }

  private func finishImport(_ id: UInt64, value: Any?) {
    guard let pending = pendingImport, pending.id == id else { return }
    pendingImport = nil
    if operation == .importing { operation = .idle }
    pending.result(value)
  }

  /// Completes a pending import with CANCELLED and stops its copy (dispose).
  private func abortImport() {
    let pending = pendingImport
    pendingImport = nil
    pending?.token.cancel()
    store.cancelImport()
    // The picker's completion now sees a cancelled token and does nothing.
    picker?.dismiss()
    picker = nil
    if operation == .importing { operation = .idle }
    pending?.result(cancelledError())
  }

  // MARK: Model download (pinned URL only)

  private func downloadModel(_ result: @escaping FlutterResult) {
    let status = currentStatus()
    guard status.canRun else {
      result(flutterError(OfflineTutorError(.unsupportedDevice, message: status.message))); return
    }
    guard !modelWorkBusy, download == nil else { result(flutterError(OfflineTutorError(.busy))); return }
    // Already installed at the pinned size: nothing to fetch.
    if status.modelReady && status.modelBytes == OfflineTutorDownloadPolicy.expectedBytes {
      result(status.channelMap); return
    }
    guard OfflineTutorDownloadPolicy.hasSpaceForDownload(availableBytes: store.availableCapacity()) else {
      let gb = Double(OfflineTutorDownloadPolicy.requiredFreeBytes()) / 1_000_000_000
      result(flutterError(OfflineTutorError(
        .insufficientStorage,
        message: String(format: "Free at least %.1f GB of storage, then download the AI model again.", gb))))
      return
    }
    let job = DownloadJob(store: store, result: result)
    download = job
    operation = .downloading
    job.savedIdleTimer = UIApplication.shared.isIdleTimerDisabled
    // Keep the screen awake while the user waits (the download is foreground-only).
    UIApplication.shared.isIdleTimerDisabled = true
    modelEvent("downloading")
    emitProgress(job, .downloading, 0)
    job.downloader.start(
      progress: { [weak self, weak job] fraction in
        DispatchQueue.main.async {
          guard let self, let job else { return }
          self.emitProgress(job, .downloading, fraction)
        }
      },
      finished: { [weak self] outcome in
        DispatchQueue.main.async { self?.downloadFinished(job, outcome) }
      })
  }

  private func emitProgress(_ job: DownloadJob, _ phase: OfflineTutorDownloadPhase, _ fraction: Double) {
    guard download === job, !job.token.isCancelled,
      let value = job.throttle.next(phase: phase, fraction: fraction, now: Date().timeIntervalSinceReferenceDate)
    else { return }
    send(["type": "modelDownload", "progress": value, "phase": phase.rawValue])
  }

  private func downloadFinished(_ job: DownloadJob, _ outcome: Result<URL, OfflineTutorError>) {
    switch outcome {
    case .failure(let error):
      completeDownload(job, value: flutterError(error))
      settle(job)
    case .success(let staged):
      guard download === job, !job.token.isCancelled else {
        store.discardStaged(staged)
        completeDownload(job, value: cancelledError())
        settle(job)
        return
      }
      emitProgress(job, .verifying, 0)
      let token = job.token
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let failure = OfflineTutorFileVerifier.verify(
          fileURL: staged, expectedBytes: OfflineTutorDownloadPolicy.expectedBytes,
          expectedSHA256: OfflineTutorDownloadPolicy.expectedSHA256,
          isCancelled: { token.isCancelled },
          progress: { fraction in
            DispatchQueue.main.async { [weak self] in self?.emitProgress(job, .verifying, fraction) }
          })
        DispatchQueue.main.async {
          guard let self else { OfflineTutorModelStore.shared.discardStaged(staged); return }
          self.verified(job, staged: staged, failure: failure)
        }
      }
    }
  }

  private func verified(_ job: DownloadJob, staged: URL, failure: OfflineTutorError?) {
    if failure != nil || download !== job || job.token.isCancelled {
      store.discardStaged(staged)
      let error = job.token.isCancelled ? OfflineTutorError(.cancelled) : (failure ?? OfflineTutorError(.cancelled))
      completeDownload(job, value: flutterError(error))
      settle(job)
      return
    }
    emitProgress(job, .installing, 0)
    let store = self.store
    let token = job.token
    // Release the engine (it maps the old file) before replacing the model.
    let unload = control.enqueue { [runtime = self.runtime] in
      await runtime.cancel()
      await runtime.unload()
    }
    Task {
      await unload.value
      let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
        do {
          try store.installDownloaded(
            staged: staged, expectedBytes: OfflineTutorDownloadPolicy.expectedBytes, token: token)
          return .success(())
        } catch {
          return .failure(error)
        }
      }.value
      await MainActor.run {
        switch outcome {
        case .success:
          self.emitProgress(job, .installing, 1)
          self.modelEvent("installed")
          // Reported only after the verified file is the active model.
          self.completeDownload(job, value: self.currentStatus().channelMap)
        case .failure(let error):
          let code = (error as? OfflineTutorError)?.code
          let mapped: OfflineTutorError
          switch code {
          case .cancelled?: mapped = OfflineTutorError(.cancelled)
          case .busy?: mapped = OfflineTutorError(.busy)
          case .invalidModel?: mapped = OfflineTutorError(.downloadInvalid)
          default:
            mapped = OfflineTutorError(
              .downloadFailed, message: "The AI model could not be installed. Your previous model was kept.")
          }
          self.modelEvent("downloadFailed")
          self.completeDownload(job, value: self.flutterError(mapped))
        }
        self.settle(job)
      }
    }
  }

  private func completeDownload(_ job: DownloadJob, value: Any?) {
    guard let result = job.result else { return }
    job.result = nil
    result(value)
  }

  private func restoreIdleTimer(_ job: DownloadJob) {
    guard let saved = job.savedIdleTimer else { return }
    job.savedIdleTimer = nil
    UIApplication.shared.isIdleTimerDisabled = saved
  }

  /// The job's network, verification and install work has fully stopped.
  private func settle(_ job: DownloadJob) {
    guard !job.settled else { return }
    job.settled = true
    restoreIdleTimer(job)
    if download === job {
      download = nil
      if operation == .downloading { operation = .idle }
    }
    let waiters = job.settleWaiters
    job.settleWaiters = []
    waiters.forEach { $0() }
  }

  /// Cancels the attempt: the pending `downloadModel` completes once with
  /// CANCELLED right away; partial files are deleted; the old model is kept.
  private func abortDownload() -> DownloadJob? {
    guard let job = download else { return nil }
    job.token.cancel()
    job.downloader.cancel()
    completeDownload(job, value: cancelledError())
    restoreIdleTimer(job)
    return job
  }

  /// Replies after the download, verification or install step has stopped (or a
  /// 15 s safety limit), so Flutter's following `getStatus` is accurate.
  private func cancelModelDownload(_ result: @escaping FlutterResult) {
    guard let job = abortDownload() else { result(nil); return }
    if job.settled { result(nil); return }
    var replied = false
    let reply = {
      guard !replied else { return }
      replied = true
      result(nil)
    }
    job.settleWaiters.append(reply)
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: reply)
  }

  // MARK: Model removal

  private func removeModel(_ result: @escaping FlutterResult) {
    guard operation == .idle, download == nil, !store.isImporting else {
      result(flutterError(OfflineTutorError(.busy))); return
    }
    operation = .removing
    // Cancel any running answer first, then release the engine before deleting.
    interruptAsk()
    let store = self.store
    let release = control.enqueue { [runtime = self.runtime] in
      await runtime.cancel()
      await runtime.unload()
      await runtime.reset()
    }
    Task {
      await release.value
      let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
        do { try store.removeModel(); return .success(()) } catch { return .failure(error) }
      }.value
      await MainActor.run {
        if self.operation == .removing { self.operation = .idle }
        switch outcome {
        case .success:
          self.modelEvent("removed")
          result(self.currentStatus().channelMap)
        case .failure(let error):
          result(self.flutterError(error))
        }
      }
    }
  }

  private func releaseModelForMemory() {
    guard pendingAsk == nil, operation == .idle else { return }
    runControl { runtime in await runtime.unload() }
    modelEvent("unloaded")
  }

  // MARK: Camera

  private func capturePhoto(_ result: @escaping FlutterResult) {
    speaker.stop()
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let path = try self.camera.capturePhoto()
        DispatchQueue.main.async { result(path) }
      } catch {
        DispatchQueue.main.async { result(self.flutterError(error)) }
      }
    }
  }

  // MARK: Ask

  private func ask(_ arguments: Any?, result: @escaping FlutterResult) {
    let request: OfflineTutorAskRequest
    switch OfflineTutorAskRequest.parse(arguments) {
    case .success(let value): request = value
    case .failure(let error): result(flutterError(error)); return
    }
    let status = currentStatus()
    guard status.canRun else { result(flutterError(OfflineTutorError(.unsupportedDevice, message: status.message))); return }
    guard status.modelReady, let modelBytes = store.installedModelBytes() else {
      result(flutterError(OfflineTutorError(.modelMissing))); return
    }
    guard operation == .idle, !store.isImporting else { result(flutterError(OfflineTutorError(.busy))); return }
    let generation: UInt64
    switch gate.begin(requestId: request.requestId) {
    case .success(let value): generation = value
    case .failure(let error): result(flutterError(error)); return
    }
    pendingAsk = (request.requestId, generation, result)

    // Every control step issued before this ask (reset of the old scene, a
    // previous session's unload) completes before the runtime is touched.
    let barrier = control.tail
    let modelURL = store.modelURL
    let cacheURL = store.engineCacheURL
    let runtime = self.runtime
    Task {
      do {
        await barrier?.value
        // Observed after earlier control steps; a later dispose/unload makes it stale.
        let loadTicket = await runtime.loadTicket
        var image: Data?
        if let path = request.imagePath {
          image = try await Task.detached(priority: .userInitiated) {
            try OfflineTutorImages.modelInput(fromPath: path)
          }.value
        }
        guard await MainActor.run(body: { self.gate.isCurrent(requestId: request.requestId, generation: generation) })
        else { throw OfflineTutorError(.cancelled) }
        if await !runtime.isLoaded {
          await MainActor.run { self.modelEvent("loading") }
          try await runtime.load(
            modelURL: modelURL, modelBytes: modelBytes, cacheURL: cacheURL, loadTicket: loadTicket)
          await MainActor.run { self.modelEvent("ready") }
        }
        // Read the ticket, then confirm the request is still current. Any later
        // cancel/reset invalidates the gate first and bumps the ticket after.
        let ticket = await runtime.ticket
        guard await MainActor.run(body: { self.gate.isCurrent(requestId: request.requestId, generation: generation) })
        else { throw OfflineTutorError(.cancelled) }
        let json = try await runtime.ask(question: request.question, newImage: image, ticket: ticket)
        await MainActor.run { self.completeAsk(request.requestId, generation, value: json) }
      } catch {
        await MainActor.run { self.completeAsk(request.requestId, generation, value: self.flutterError(error)) }
      }
    }
  }

  private func completeAsk(_ requestId: Int, _ generation: UInt64, value: Any) {
    guard gate.finish(requestId: requestId, generation: generation),
      let pending = pendingAsk, pending.requestId == requestId, pending.generation == generation
    else { return }
    pendingAsk = nil
    pending.result(value)
  }

  /// Completes the pending ask with CANCELLED right away (never waits on native
  /// teardown) and invalidates its generation so a late result is dropped. The
  /// caller enqueues the matching runtime step.
  private func interruptAsk() {
    if let pending = pendingAsk {
      pendingAsk = nil
      pending.result(cancelledError())
    }
    gate.invalidate()
  }

  // MARK: Speech

  private func startListening(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let locale = (arguments as? [String: Any])?["locale"] as? String else {
      result(flutterError(OfflineTutorError(.invalidArguments))); return
    }
    speaker.stop()
    let token = lifecycle
    dictation.start(locale: locale) { [weak self] error in
      guard let self else { return }
      // The dictation session token already rejected stale starts (every
      // pause/dispose/stop invalidates it). Never stop here: a late callback from a
      // disposed tutor must not tear down dictation a reopened tutor started.
      result(token != self.lifecycle ? self.cancelledError() : error.map { self.flutterError($0) })
    }
  }

  private func speak(_ arguments: Any?, result: @escaping FlutterResult) {
    switch OfflineTutorSpeechPolicy.parseSegments(arguments) {
    case .failure(let error):
      result(flutterError(error))
    case .success(let segments):
      // Never speak into an open microphone.
      dictation.stop(sendFinal: false)
      do {
        try speaker.speak(segments)
        result(nil)
      } catch {
        result(flutterError(error))
      }
    }
  }

  // MARK: Lifecycle

  /// Stops audio input/output and in-flight work shared by pause and background.
  /// Keeps the loaded model, the scene and an idle completed conversation.
  private func quiesce() {
    dictation.stop(sendFinal: false)
    speaker.stop()
    interruptAsk()
    _ = abortDownload()
  }

  /// Flutter `pause`: camera off until Flutter `resume` (frozen scene, studying,
  /// choosing a photo, app backgrounded). Replies after the runtime cancel ran.
  private func pause(_ result: @escaping FlutterResult) {
    quiesce()
    camera.pause()
    runControl(reply: result) { runtime in await runtime.cancel() }
  }

  /// App background: same as pause for audio, inference and download (a
  /// download is cancelled, not left hanging), but the camera remembers whether
  /// Flutter wanted it, so foregrounding restores exactly that.
  private func enterBackground() {
    quiesce()
    camera.setBackgrounded(true)
    runControl { runtime in await runtime.cancel() }
  }

  /// Releases everything for this tutor session. A later preview/ask starts fresh.
  /// The reset/unload is ordered before any later ask, so it can never erase a
  /// reopened session; replies after it ran.
  private func dispose(_ result: @escaping FlutterResult) {
    lifecycle &+= 1
    quiesce()
    abortImport()
    camera.release()
    modelEvent("unloaded")
    runControl(reply: result) { runtime in
      await runtime.reset()
      await runtime.unload()
    }
  }

  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
      .flatMap { $0.windows }
    var top = (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}
