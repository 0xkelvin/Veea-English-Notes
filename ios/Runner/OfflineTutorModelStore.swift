import Foundation
import LiteRTLM
import UIKit
import UniformTypeIdentifiers
import os

/// Owns the single tutor model file in private Application Support.
///
/// Layout (all inside the app container, excluded from iCloud/iTunes backup):
///   Library/Application Support/OfflineTutor/model/tutor.litertlm       active model
///   Library/Application Support/OfflineTutor/staging/<uuid>.part        in-progress Files copy
///   Library/Application Support/OfflineTutor/staging/<uuid>.download    verified-download candidate
///   Library/Caches/OfflineTutor/engine-cache/                           LiteRT-LM compile cache
///
/// The caller never supplies a destination path. Inputs are a URL the system
/// document picker returned for a user-chosen file, or a file the pinned
/// downloader moved into `staging`. Both are installed by `install(staged:...)`.
final class OfflineTutorModelStore: @unchecked Sendable {
  static let shared = OfflineTutorModelStore()

  private let fileManager = FileManager.default
  private let lock = NSLock()
  private var busy = false
  private var importToken: OfflineTutorCancelToken?

  private var rootURL: URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("OfflineTutor", isDirectory: true)
  }
  private var modelDirectory: URL { rootURL.appendingPathComponent("model", isDirectory: true) }
  var stagingDirectory: URL { rootURL.appendingPathComponent("staging", isDirectory: true) }
  var modelURL: URL { modelDirectory.appendingPathComponent("tutor.litertlm", isDirectory: false) }
  var engineCacheURL: URL {
    fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OfflineTutor/engine-cache", isDirectory: true)
  }

  /// True while a Files import copy or any install is running.
  var isImporting: Bool { lock.withLock { busy } }

  private func beginExclusive() throws {
    try lock.withLock {
      if busy { throw OfflineTutorError(.busy) }
      busy = true
    }
  }

  private func endExclusive() { lock.withLock { busy = false } }

  /// Free space for important (user-initiated) work on the app's volume.
  func availableCapacity() -> Int64 {
    try? ensureDirectories()
    return availableCapacity(at: rootURL)
  }

  /// A fresh staging path for the downloader (never a caller-provided path).
  func newDownloadStagingURL() throws -> URL {
    try ensureDirectories()
    return stagingDirectory.appendingPathComponent(UUID().uuidString + ".download")
  }

  /// Size of the active model, or nil when absent/invalid.
  func installedModelBytes() -> Int64? {
    guard let values = try? modelURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true, let size = values.fileSize
    else { return nil }
    return Int64(size)
  }

  /// Removes leftovers from an interrupted import (app killed mid-copy).
  func cleanStaging() {
    guard !isImporting else { return }
    try? fileManager.removeItem(at: stagingDirectory)
  }

  func cancelImport() { lock.withLock { importToken?.cancel() } }

  /// Copies the picked file into private storage.
  ///
  /// The copy goes to a staging file first; the active model is replaced only after
  /// size, header and SDK metadata checks pass, using an atomic `replaceItemAt`.
  /// Any failure or cancellation removes the staging file and keeps the old model.
  func importModel(from pickedURL: URL, token: OfflineTutorCancelToken) throws -> Int64 {
    try beginExclusive()
    lock.withLock { importToken = token }
    defer {
      lock.withLock { importToken = nil }
      endExclusive()
    }

    let scoped = pickedURL.startAccessingSecurityScopedResource()
    defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

    guard OfflineTutorModelPolicy.validateName(pickedURL.lastPathComponent) else {
      throw OfflineTutorError(.invalidModel)
    }
    let source = pickedURL.resolvingSymlinksInPath()
    let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey])
    guard values?.isRegularFile == true, values?.isDirectory != true, let rawSize = values?.fileSize else {
      throw OfflineTutorError(.invalidModel)
    }
    let sourceBytes = Int64(rawSize)
    if let error = OfflineTutorModelPolicy.validateSize(sourceBytes) { throw error }

    try ensureDirectories()
    let available = availableCapacity(at: rootURL)
    guard OfflineTutorModelPolicy.hasSpaceForImport(sourceBytes: sourceBytes, availableBytes: available) else {
      throw OfflineTutorError(.insufficientStorage)
    }

    let staging = stagingDirectory.appendingPathComponent(UUID().uuidString + ".part")
    do {
      try copyChunked(from: source, to: staging, expectedBytes: sourceBytes, token: token)
      try commit(staged: staging, expectedBytes: sourceBytes, token: token)
      return sourceBytes
    } catch {
      try? fileManager.removeItem(at: staging)
      if let tutorError = error as? OfflineTutorError { throw tutorError }
      throw OfflineTutorError(.importFailed)
    }
  }

  /// Installs a file the pinned downloader already verified (size, header and
  /// SHA-256). Re-checks size and SDK metadata, then replaces atomically. The
  /// staged file is always consumed or deleted; the old model survives failure.
  func installDownloaded(staged: URL, expectedBytes: Int64, token: OfflineTutorCancelToken) throws {
    guard staged.deletingLastPathComponent().standardizedFileURL == stagingDirectory.standardizedFileURL,
      staged.pathExtension == "download"
    else {
      throw OfflineTutorError(.downloadFailed)
    }
    do {
      try beginExclusive()
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
    defer { endExclusive() }
    do {
      try commit(staged: staged, expectedBytes: expectedBytes, token: token)
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
  }

  /// Validates and atomically promotes a staged file. Cancellation is honoured up
  /// to the moment of the swap (checked under the store lock right before it).
  private func commit(staged: URL, expectedBytes: Int64, token: OfflineTutorCancelToken) throws {
    if token.isCancelled { throw OfflineTutorError(.cancelled) }
    try validateStagedModel(at: staged, expectedBytes: expectedBytes)
    try excludeFromBackup(staged)
    try lock.withLock {
      if token.isCancelled { throw OfflineTutorError(.cancelled) }
      if fileManager.fileExists(atPath: modelURL.path) {
        _ = try fileManager.replaceItemAt(modelURL, withItemAt: staged, backupItemName: nil, options: [])
      } else {
        try fileManager.moveItem(at: staged, to: modelURL)
      }
    }
    try? excludeFromBackup(modelURL)
    try? fileManager.removeItem(at: engineCacheURL)
  }

  func removeModel() throws {
    try beginExclusive()
    defer { endExclusive() }
    if fileManager.fileExists(atPath: modelURL.path) {
      try fileManager.removeItem(at: modelURL)
    }
    try? fileManager.removeItem(at: engineCacheURL)
    try? fileManager.removeItem(at: stagingDirectory)
  }

  /// Deletes one staged candidate (download cancelled or rejected).
  func discardStaged(_ url: URL) {
    guard url.deletingLastPathComponent().standardizedFileURL == stagingDirectory.standardizedFileURL else { return }
    try? fileManager.removeItem(at: url)
  }

  // MARK: - Private

  private func ensureDirectories() throws {
    for dir in [rootURL, modelDirectory, stagingDirectory] {
      try fileManager.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    try excludeFromBackup(rootURL)
  }

  private func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = url
    try mutable.setResourceValues(values)
  }

  private func availableCapacity(at url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
  }

  private func copyChunked(
    from source: URL, to destination: URL, expectedBytes: Int64, token: OfflineTutorCancelToken
  ) throws {
    guard fileManager.createFile(atPath: destination.path, contents: nil) else {
      throw OfflineTutorError(.importFailed)
    }
    let reader = try FileHandle(forReadingFrom: source)
    defer { try? reader.close() }
    let writer = try FileHandle(forWritingTo: destination)
    defer { try? writer.close() }

    let chunkSize = 8 * 1_048_576
    var copied: Int64 = 0
    var header: [UInt8] = []
    while true {
      if token.isCancelled { throw OfflineTutorError(.cancelled) }
      let chunk: Data = try autoreleasepool {
        try reader.read(upToCount: chunkSize) ?? Data()
      }
      if chunk.isEmpty { break }
      if header.isEmpty {
        header = Array(chunk.prefix(OfflineTutorLimits.modelMagic.count))
        guard OfflineTutorModelPolicy.validateHeader(header) else { throw OfflineTutorError(.invalidModel) }
      }
      copied += Int64(chunk.count)
      // Guard against a file that grows while being copied.
      if copied > expectedBytes { throw OfflineTutorError(.invalidModel) }
      try writer.write(contentsOf: chunk)
    }
    guard copied == expectedBytes else { throw OfflineTutorError(.importFailed) }
    try writer.synchronize()
  }

  /// Uses the official SDK metadata reader to confirm a vision-capable LLM.
  private func validateStagedModel(at url: URL, expectedBytes: Int64) throws {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
    guard Int64(size) == expectedBytes else { throw OfflineTutorError(.importFailed) }
    guard let info = ModelInfo(modelPath: url.path) else { throw OfflineTutorError(.invalidModel) }
    guard info.isLlmModel() else { throw OfflineTutorError(.invalidModel) }
    guard info.inputModalities.vision else {
      throw OfflineTutorError(.invalidModel, message: "This model cannot read photos. Import a vision model such as Gemma 4 E2B.")
    }
    let backends = info.supportedBackends(for: .text)
    if !backends.isEmpty && !backends.contains(.gpu) && !backends.contains(.cpu) {
      throw OfflineTutorError(.invalidModel, message: "This model was built for a different chip and cannot run on iPhone.")
    }
  }
}

// MARK: - Document picker

/// Presents the Files picker for `.litertlm` files. `asCopy: false` so the system does
/// not duplicate a multi-gigabyte file into tmp; the store does a single verified copy.
final class OfflineTutorModelPicker: NSObject, UIDocumentPickerDelegate {
  private var completion: ((URL?) -> Void)?
  private var retainSelf: OfflineTutorModelPicker?
  private weak var controller: UIDocumentPickerViewController?

  static var contentTypes: [UTType] {
    var types: [UTType] = []
    if let litertlm = UTType(filenameExtension: "litertlm") { types.append(litertlm) }
    // Unregistered extensions often surface as generic data; the store re-validates.
    types.append(.data)
    return types
  }

  func present(from presenter: UIViewController, completion: @escaping (URL?) -> Void) {
    self.completion = completion
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.contentTypes, asCopy: false)
    picker.allowsMultipleSelection = false
    picker.shouldShowFileExtensions = true
    picker.delegate = self
    retainSelf = self
    controller = picker
    presenter.present(picker, animated: true)
  }

  /// Closes the picker (tutor disposed); completes with nil exactly once.
  func dismiss() {
    let picker = controller
    controller = nil
    finish(nil)
    picker?.dismiss(animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finish(urls.first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  private func finish(_ url: URL?) {
    let callback = completion
    completion = nil
    retainSelf = nil
    callback?(url)
  }
}
