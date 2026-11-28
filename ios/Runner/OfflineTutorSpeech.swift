import AVFoundation
import Foundation
import Speech

/// Event sink shared by dictation and speech output (main thread).
typealias OfflineTutorEventSink = ([String: Any]) -> Void

// MARK: - Dictation

/// On-device Apple Speech dictation for en-US and vi-VN.
///
/// `requiresOnDeviceRecognition` is always true: audio never leaves the device and
/// there is no server fallback. Permissions are requested only when the learner
/// taps the microphone (`start`). Transcripts are forwarded to Flutter only, never
/// logged.
final class OfflineTutorDictation: NSObject {
  private let audioEngine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var session: UInt64 = 0
  private var lastText = ""
  private(set) var isListening = false
  /// True from the `listening:true` event until its matching `listening:false`.
  private var announced = false
  /// True only after this class activated the shared audio session itself.
  private var ownsAudioSession = false

  var emit: OfflineTutorEventSink?

  /// Locales whose recognizer supports on-device recognition. Empty when the user
  /// has denied or is restricted from speech recognition.
  static func availableLocales() -> [String] {
    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .denied || status == .restricted { return [] }
    var capable: [String: Bool] = [:]
    for id in OfflineTutorSpeechPolicy.supportedLocales {
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id))
      capable[id] = recognizer?.supportsOnDeviceRecognition == true
    }
    return OfflineTutorSpeechPolicy.dictationLocales(onDeviceCapable: capable)
  }

  /// Requests permissions if needed, then starts listening. Completion runs on main.
  func start(locale rawLocale: String, completion: @escaping (OfflineTutorError?) -> Void) {
    guard let locale = OfflineTutorSpeechPolicy.normalizedLocale(rawLocale) else {
      completion(OfflineTutorError(.speechLocaleUnsupported)); return
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
      recognizer.supportsOnDeviceRecognition
    else { completion(OfflineTutorError(.speechUnavailable)); return }

    stop(sendFinal: false)
    session &+= 1
    let token = session
    requestPermissions(token: token) { error in
      guard token == self.session else { completion(OfflineTutorError(.cancelled)); return }
      if let error { completion(error); return }
      guard recognizer.isAvailable else { completion(OfflineTutorError(.speechUnavailable)); return }
      do {
        try self.begin(recognizer: recognizer, token: token)
        completion(nil)
      } catch let error as OfflineTutorError {
        self.teardown()
        completion(error)
      } catch {
        self.teardown()
        completion(OfflineTutorError(.speechFailed))
      }
    }
  }

  /// Speech authorization, then microphone permission. If the tutor paused, closed
  /// or stopped while the speech prompt was up (`token` is stale), the microphone
  /// prompt is never shown afterwards.
  private func requestPermissions(token: UInt64, _ completion: @escaping (OfflineTutorError?) -> Void) {
    let askMicrophone = {
      let handle: (Bool) -> Void = { granted in
        DispatchQueue.main.async { completion(granted ? nil : OfflineTutorError(.microphonePermissionDenied)) }
      }
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission(completionHandler: handle)
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission(handle)
      }
    }
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      askMicrophone()
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async {
          guard token == self.session else { completion(OfflineTutorError(.cancelled)); return }
          if status == .authorized { askMicrophone() } else { completion(OfflineTutorError(.speechPermissionDenied)) }
        }
      }
    default:
      completion(OfflineTutorError(.speechPermissionDenied))
    }
  }

  private func begin(recognizer: SFSpeechRecognizer, token: UInt64) throws {
    let audio = AVAudioSession.sharedInstance()
    try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
    try audio.setActive(true, options: .notifyOthersOnDeactivation)
    ownsAudioSession = true

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if #available(iOS 16.0, *) { request.addsPunctuation = true }

    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw OfflineTutorError(.speechUnavailable) }
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
      request?.append(buffer)
    }
    audioEngine.prepare()
    try audioEngine.start()

    self.recognizer = recognizer
    self.request = request
    lastText = ""
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async { self?.handle(result: result, error: error, token: token) }
    }
    isListening = true
    announced = true
    emit?(["type": "listening", "active": true])
  }

  /// Sends the closing `listening:false` exactly once per session.
  private func closeAnnouncement() {
    guard announced else { return }
    announced = false
    emit?(["type": "listening", "active": false])
  }

  private func handle(result: SFSpeechRecognitionResult?, error: Error?, token: UInt64) {
    guard token == session else { return }
    if let result {
      lastText = result.bestTranscription.formattedString
      emit?(["type": "speech", "text": lastText, "isFinal": result.isFinal])
      if result.isFinal { finish() }
      return
    }
    if error != nil {
      let wasActive = announced
      teardown()
      // Keep what was heard; otherwise report a generic failure (no details).
      if wasActive && !lastText.isEmpty {
        emit?(["type": "speech", "text": lastText, "isFinal": true])
      } else if wasActive {
        emit?(OfflineTutorEvents.error(OfflineTutorError(.speechFailed)))
      }
      closeAnnouncement()
    }
  }

  private func finish() {
    teardown()
    closeAnnouncement()
  }

  /// Stops the microphone. With `sendFinal`, asks the recognizer to finalize the
  /// audio so far (the final `speech` event follows asynchronously); otherwise the
  /// session is discarded and a closing event is sent immediately.
  ///
  /// When nothing is active this still invalidates a `start` that is waiting on a
  /// permission prompt, so a late grant never opens the microphone after a
  /// pause/dispose/stop. It does not touch the shared audio session then (that
  /// may belong to the app's other audio features).
  func stop(sendFinal: Bool = true) {
    guard announced || task != nil else {
      session &+= 1
      return
    }
    if sendFinal, isListening, task != nil {
      stopAudio()
      request?.endAudio()
      isListening = false
      // Safety: finalize even if the recognizer never delivers a final result.
      let token = session
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self, token == self.session, self.announced else { return }
        if !self.lastText.isEmpty { self.emit?(["type": "speech", "text": self.lastText, "isFinal": true]) }
        self.session &+= 1
        self.teardown()
        self.closeAnnouncement()
      }
      return
    }
    session &+= 1
    teardown()
    closeAnnouncement()
  }

  private func stopAudio() {
    if audioEngine.isRunning { audioEngine.stop() }
    audioEngine.inputNode.removeTap(onBus: 0)
  }

  private func teardown() {
    stopAudio()
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    recognizer = nil
    isListening = false
    if ownsAudioSession {
      ownsAudioSession = false
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }
}

// MARK: - Speech output

/// Speaks tagged English/Vietnamese segments in order with installed system voices.
/// `AVSpeechSynthesizer` is fully local; no network voice API is used.
final class OfflineTutorSpeaker: NSObject, AVSpeechSynthesizerDelegate {
  private var synthesizer: AVSpeechSynthesizer?
  private var pending = 0
  private var generation: UInt64 = 0

  var emit: OfflineTutorEventSink?

  /// Picks an installed voice for a supported locale, preferring higher quality.
  static func voice(for locale: String) -> AVSpeechSynthesisVoice? {
    let prefix = String(locale.prefix(2))
    let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
      guard voice.language == locale || voice.language.hasPrefix(prefix + "-") else { return false }
      if #available(iOS 17.0, *) {
        // Personal Voice requires separate authorization; never use it implicitly.
        if voice.voiceTraits.contains(.isPersonalVoice) { return false }
      }
      return true
    }
    let exact = candidates.filter { $0.language == locale }
    let pool = exact.isEmpty ? candidates : exact
    return pool.max { $0.quality.rawValue < $1.quality.rawValue }
  }

  func speak(_ segments: [OfflineTutorSpeechPolicy.Segment]) throws {
    var utterances: [AVSpeechUtterance] = []
    for segment in segments {
      guard let voice = Self.voice(for: segment.language) else {
        let name = segment.language == "vi-VN" ? "Vietnamese" : "English"
        throw OfflineTutorError(
          .voiceUnavailable,
          message: "No installed \(name) voice. Add one in Settings > Accessibility > Spoken Content > Voices.")
      }
      let utterance = AVSpeechUtterance(string: segment.text)
      utterance.voice = voice
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (segment.language == "en-US" ? 0.9 : 1.0)
      utterance.postUtteranceDelay = 0.15
      utterances.append(utterance)
    }
    stop()
    let audio = AVAudioSession.sharedInstance()
    try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    try? audio.setActive(true)
    let synth = AVSpeechSynthesizer()
    synth.delegate = self
    synthesizer = synth
    generation &+= 1
    pending = utterances.count
    emit?(["type": "speaking", "active": true])
    utterances.forEach { synth.speak($0) }
  }

  func stop() {
    guard let synth = synthesizer else { return }
    generation &+= 1
    synthesizer = nil
    synth.delegate = nil
    synth.stopSpeaking(at: .immediate)
    pending = 0
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    emit?(["type": "speaking", "active": false])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    DispatchQueue.main.async { self.utteranceEnded(synthesizer) }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    DispatchQueue.main.async { self.utteranceEnded(synthesizer) }
  }

  private func utteranceEnded(_ synth: AVSpeechSynthesizer) {
    guard synth === synthesizer else { return }
    pending -= 1
    if pending <= 0 { stop() }
  }
}

enum OfflineTutorEvents {
  static func error(_ error: OfflineTutorError) -> [String: Any] {
    ["type": "error", "code": error.code.rawValue, "message": error.message]
  }
}
