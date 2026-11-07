import Foundation
import Darwin

enum NativeGateError: LocalizedError {
  case unavailable, storage, unknownApplication, invalidDuration, authorizationRequired, tooManyApplications

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Screen Time protection is not available in this build."
    case .storage: return "Protection settings could not be saved. Please try again."
    case .unknownApplication: return "Select this app again in Screen Time settings."
    case .invalidDuration: return "Screen Time unlocks support 15 or 30 minutes."
    case .authorizationRequired: return "Allow Screen Time access before enabling protection."
    case .tooManyApplications: return "Choose up to 50 individual apps for Screen Time protection."
    }
  }
}

/// All main-app and extension reads/writes and shield updates use one file lock.
/// Atomic replacement protects against a process being killed during a write.
final class NativeGateStore {
  static let appGroup = "group.com.nintran.veeaEnglishApp"
  private let directory: URL

  init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  static func shared() throws -> NativeGateStore {
    guard let root = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroup
    ) else { throw NativeGateError.unavailable }
    return try NativeGateStore(directory: root.appendingPathComponent("ScreenTime", isDirectory: true))
  }

  func read() throws -> NativeGateState {
    try locked { try load() }
  }

  @discardableResult
  func update<T>(
    _ action: (inout NativeGateState) throws -> T,
    apply: (NativeGateState) -> Void = { _ in }
  ) throws -> T {
    try locked {
      var state = try load()
      let result = try action(&state)
      try save(state)
      // Keep applying ManagedSettings inside the same cross-process lock.
      apply(state)
      return result
    }
  }

  func disable(apply: (NativeGateState) -> Void) throws {
    try locked {
      var state = (try? load()) ?? NativeGateState()
      state.enabled = false
      state.passes = [:]
      state.pendingChallenge = nil
      try save(state)
      apply(state)
    }
  }

  private func load() throws -> NativeGateState {
    let file = directory.appendingPathComponent("state.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return NativeGateState() }
    return try JSONDecoder().decode(NativeGateState.self, from: Data(contentsOf: file))
  }

  private func save(_ state: NativeGateState) throws {
    let file = directory.appendingPathComponent("state.json")
    var options: Data.WritingOptions = .atomic
    #if os(iOS)
    options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try JSONEncoder().encode(state).write(to: file, options: options)
  }

  private func locked<T>(_ action: () throws -> T) throws -> T {
    let path = directory.appendingPathComponent("state.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw NativeGateError.storage }
    defer { close(descriptor) }
    // An app process can be suspended while holding the lock. Bound the wait so
    // a shield action can report failure instead of hanging behind that process.
    var acquired = false
    for _ in 0..<100 {
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
      guard errno == EWOULDBLOCK || errno == EAGAIN else { throw NativeGateError.storage }
      usleep(10_000)
    }
    guard acquired else { throw NativeGateError.storage }
    defer { flock(descriptor, LOCK_UN) }
    return try action()
  }
}
