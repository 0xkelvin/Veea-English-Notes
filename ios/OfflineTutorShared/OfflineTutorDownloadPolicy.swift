// Pure policy for the one pinned tutor model download.
//
// Foundation + CryptoKit only, compiled into Runner and into the native tests.
// Source of truth (public, Apache-2.0, not gated; checked 2026-11-28):
//   repo     litert-community/gemma-4-E2B-it-litert-lm
//   revision 6e5c4f1e395deb959c494953478fa5cec4b8008f
//   file     gemma-4-E2B-it.litertlm, 2,588,147,712 bytes
//   sha256   181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c
// The resolve URL answers 302 to the Hugging Face CDN (`*.hf.co`), which serves
// `application/octet-stream` with an exact Content-Length.

import CryptoKit
import Foundation

enum OfflineTutorDownloadPhase: String, Sendable {
  case downloading
  case verifying
  case installing
}

enum OfflineTutorDownloadPolicy {
  /// The only URL the app ever requests. Callers cannot supply another.
  static let pinnedURL = URL(string:
    "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/"
    + "6e5c4f1e395deb959c494953478fa5cec4b8008f/gemma-4-E2B-it.litertlm")!
  static let expectedBytes: Int64 = OfflineTutorLimits.recommendedModelBytes
  static let expectedSHA256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
  static let maxRedirects = 5
  /// Free space kept after the download, staged verification and the first
  /// engine compile cache (~0.9 GB measured for Gemma 4 E2B on GPU).
  static let spareBytes: Int64 = 512 * 1_048_576
  /// Idle timeout between received bytes, and the whole-transfer ceiling. With
  /// `waitsForConnectivity = false` an unreachable network fails immediately.
  static let requestTimeoutSeconds: TimeInterval = 60
  static let resourceTimeoutSeconds: TimeInterval = 3 * 60 * 60

  /// Hugging Face itself and its public CDN hosts only, over HTTPS on 443,
  /// without embedded credentials.
  static func isAllowedURL(_ url: URL?) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else {
      return false
    }
    if url.user != nil || url.password != nil { return false }
    if let port = url.port, port != 443 { return false }
    return host == "huggingface.co" || host == "hf.co"
      || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
  }

  static func allowsRedirect(to url: URL?, redirectsSoFar: Int) -> Bool {
    redirectsSoFar < maxRedirects && isAllowedURL(url)
  }

  /// Validates the final response before or after bytes arrive.
  /// `expectedContentLength` is -1 when the server did not send one.
  static func validateResponse(statusCode: Int, expectedContentLength: Int64, finalURL: URL?) -> OfflineTutorError? {
    guard isAllowedURL(finalURL) else { return OfflineTutorError(.downloadInvalid) }
    guard statusCode == 200 else { return OfflineTutorError(.downloadFailed) }
    if expectedContentLength >= 0 && expectedContentLength != expectedBytes {
      return OfflineTutorError(.downloadInvalid)
    }
    return nil
  }

  /// More bytes than the pinned file means the payload is not the model.
  static func exceedsExpectedSize(bytesWritten: Int64) -> Bool { bytesWritten > expectedBytes }

  /// Download temp + staged/verified file + first engine cache, plus spare.
  static func hasSpaceForDownload(availableBytes: Int64) -> Bool {
    availableBytes >= 2 * expectedBytes + spareBytes
  }

  static func requiredFreeBytes() -> Int64 { 2 * expectedBytes + spareBytes }

  static func fraction(_ done: Int64, of total: Int64) -> Double {
    guard total > 0 else { return 0 }
    return min(1, max(0, Double(done) / Double(total)))
  }

  /// Maps a URLSession failure to a stable tutor error. `ourRejection` wins (we
  /// cancelled the task for a policy reason); then user cancellation.
  static func classify(
    errorDomain: String, errorCode: Int, hasNetworkUnavailableReason: Bool,
    ourRejection: OfflineTutorError?, userCancelled: Bool
  ) -> OfflineTutorError {
    if let ourRejection { return ourRejection }
    if userCancelled { return OfflineTutorError(.cancelled) }
    if hasNetworkUnavailableReason { return OfflineTutorError(.networkRequired) }
    if errorDomain == NSURLErrorDomain {
      switch errorCode {
      case NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed, NSURLErrorCallIsActive:
        return OfflineTutorError(.networkRequired)
      case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile, NSURLErrorCannotMoveFile:
        return OfflineTutorError(.insufficientStorage)
      case NSURLErrorCancelled:
        return OfflineTutorError(.cancelled)
      default:
        return OfflineTutorError(.downloadFailed)
      }
    }
    if errorDomain == NSPOSIXErrorDomain && errorCode == Int(ENOSPC) {
      return OfflineTutorError(.insufficientStorage)
    }
    return OfflineTutorError(.downloadFailed)
  }
}

/// Bounds `modelDownload` events: at most ~100 per phase (1% steps), at least
/// 250 ms apart, always the first value of a phase and the 100% value.
struct OfflineTutorProgressThrottle: Sendable {
  static let minimumStep = 0.01
  static let minimumInterval: TimeInterval = 0.25

  private var phase: OfflineTutorDownloadPhase?
  private var lastValue = -1.0
  private var lastTime = -Double.infinity

  mutating func next(phase newPhase: OfflineTutorDownloadPhase, fraction: Double, now: TimeInterval) -> Double? {
    let value = min(1, max(0, fraction.isFinite ? fraction : 0))
    let emit: Bool
    if phase != newPhase {
      emit = true
    } else if value >= 1 && lastValue < 1 {
      emit = true
    } else {
      emit = value - lastValue >= Self.minimumStep && now - lastTime >= Self.minimumInterval
    }
    guard emit else { return nil }
    phase = newPhase
    lastValue = value
    lastTime = now
    return value
  }
}

/// Streams a local file through SHA-256 in bounded chunks (never loads it whole).
enum OfflineTutorFileVerifier {
  static func sha256Hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Checks size, `LITERTLM` header and digest. Returns nil when the file matches.
  /// Cancellation is checked between chunks and reported as `.cancelled`.
  static func verify(
    fileURL: URL, expectedBytes: Int64, expectedSHA256: String,
    chunkSize: Int = 8 * 1_048_576,
    isCancelled: () -> Bool, progress: (Double) -> Void
  ) -> OfflineTutorError? {
    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
    guard size?.isRegularFile == true, let bytes = size?.fileSize, Int64(bytes) == expectedBytes else {
      return OfflineTutorError(.downloadInvalid)
    }
    guard let reader = try? FileHandle(forReadingFrom: fileURL) else { return OfflineTutorError(.downloadFailed) }
    defer { try? reader.close() }
    var hasher = SHA256()
    var read: Int64 = 0
    let magic = OfflineTutorLimits.modelMagic
    var header: [UInt8] = []
    while true {
      if isCancelled() { return OfflineTutorError(.cancelled) }
      let chunk: Data
      do {
        chunk = try autoreleasepool { try reader.read(upToCount: max(1, chunkSize)) ?? Data() }
      } catch {
        return OfflineTutorError(.downloadFailed)
      }
      if chunk.isEmpty { break }
      if header.count < magic.count {
        header += chunk.prefix(magic.count - header.count)
        if header.count == magic.count, !OfflineTutorModelPolicy.validateHeader(header) {
          return OfflineTutorError(.downloadInvalid)
        }
      }
      hasher.update(data: chunk)
      read += Int64(chunk.count)
      if read > expectedBytes { return OfflineTutorError(.downloadInvalid) }
      progress(OfflineTutorDownloadPolicy.fraction(read, of: expectedBytes))
    }
    guard read == expectedBytes, header.count == magic.count else { return OfflineTutorError(.downloadInvalid) }
    let digest = sha256Hex(hasher.finalize())
    guard digest == expectedSHA256.lowercased() else { return OfflineTutorError(.downloadInvalid) }
    return nil
  }
}
