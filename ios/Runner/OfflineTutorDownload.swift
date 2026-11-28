import Foundation

/// Downloads the one pinned tutor model file (see `OfflineTutorDownloadPolicy`).
///
/// - One instance per user-initiated attempt; nothing starts automatically.
/// - Ephemeral session: no cookies, credentials, URL cache or Authorization
///   header; HTTPS to Hugging Face and its public CDN only, every redirect
///   checked against the allowlist.
/// - Wi-Fi only: `allowsCellularAccess`, `allowsExpensiveNetworkAccess` and
///   `allowsConstrainedNetworkAccess` are false and `waitsForConnectivity` is
///   false, so an unusable network fails at once (`NETWORK_REQUIRED`) instead of
///   waiting indefinitely; a stalled transfer fails after the idle timeout.
/// - Bytes stream to URLSession's temporary file (never into memory). The file is
///   moved into private staging inside `didFinishDownloadingTo`, before that
///   delegate method returns, because the system deletes it afterwards.
/// - Foreground only. The app cancels the attempt when it goes to the background
///   or the tutor is paused/disposed; the next attempt starts from zero.
///
/// All delegate callbacks run on a private serial queue. `finished` is called
/// exactly once, on that queue, after the session is invalidated.
final class OfflineTutorModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  typealias Progress = (Double) -> Void
  typealias Finished = (Result<URL, OfflineTutorError>) -> Void

  private let store: OfflineTutorModelStore
  private let token: OfflineTutorCancelToken
  private let delegateQueue: OperationQueue
  private var session: URLSession?
  private var progress: Progress?
  private var finished: Finished?

  // Delegate-queue state.
  private var redirects = 0
  private var responseChecked = false
  private var rejection: OfflineTutorError?
  private var staged: URL?

  init(store: OfflineTutorModelStore, token: OfflineTutorCancelToken) {
    self.store = store
    self.token = token
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "app.veea.english.tutor.download"
    delegateQueue = queue
    super.init()
  }

  static func makeConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.allowsCellularAccess = false
    config.allowsExpensiveNetworkAccess = false
    config.allowsConstrainedNetworkAccess = false
    config.waitsForConnectivity = false
    config.timeoutIntervalForRequest = OfflineTutorDownloadPolicy.requestTimeoutSeconds
    config.timeoutIntervalForResource = OfflineTutorDownloadPolicy.resourceTimeoutSeconds
    config.httpCookieAcceptPolicy = .never
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpMaximumConnectionsPerHost = 1
    return config
  }

  func start(progress: @escaping Progress, finished: @escaping Finished) {
    delegateQueue.addOperation { [self] in
      self.progress = progress
      self.finished = finished
      if token.isCancelled {
        complete(.failure(OfflineTutorError(.cancelled)))
        return
      }
      var request = URLRequest(url: OfflineTutorDownloadPolicy.pinnedURL)
      request.httpMethod = "GET"
      // Exact bytes: no transfer compression that could change sizes.
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      let session = URLSession(configuration: Self.makeConfiguration(), delegate: self, delegateQueue: delegateQueue)
      self.session = session
      session.downloadTask(with: request).resume()
    }
  }

  /// Idempotent. The pending attempt then finishes with `.cancelled` (unless a
  /// policy rejection was already recorded) and its temp files are removed.
  func cancel() {
    token.cancel()
    delegateQueue.addOperation { [self] in session?.invalidateAndCancel() }
  }

  private func reject(_ error: OfflineTutorError, _ task: URLSessionTask) {
    if rejection == nil { rejection = error }
    task.cancel()
  }

  private func complete(_ result: Result<URL, OfflineTutorError>) {
    guard let callback = finished else { return }
    finished = nil
    progress = nil
    session?.finishTasksAndInvalidate()
    session = nil
    if case .failure = result, let staged {
      store.discardStaged(staged)
      self.staged = nil
    }
    callback(result)
  }

  // MARK: URLSessionTaskDelegate

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard OfflineTutorDownloadPolicy.allowsRedirect(to: request.url, redirectsSoFar: redirects) else {
      reject(OfflineTutorError(.downloadInvalid), task)
      completionHandler(nil)
      return
    }
    redirects += 1
    var next = request
    next.setValue(nil, forHTTPHeaderField: "Authorization")
    next.setValue(nil, forHTTPHeaderField: "Cookie")
    next.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    completionHandler(next)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // Default server-trust evaluation only; never answer a credential prompt.
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  // MARK: URLSessionDownloadDelegate

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    if token.isCancelled { downloadTask.cancel(); return }
    if !responseChecked {
      responseChecked = true
      if let error = checkResponse(downloadTask) { reject(error, downloadTask); return }
    }
    if OfflineTutorDownloadPolicy.exceedsExpectedSize(bytesWritten: totalBytesWritten) {
      reject(OfflineTutorError(.downloadInvalid), downloadTask)
      return
    }
    progress?(OfflineTutorDownloadPolicy.fraction(totalBytesWritten, of: OfflineTutorDownloadPolicy.expectedBytes))
  }

  private func checkResponse(_ task: URLSessionTask) -> OfflineTutorError? {
    guard let http = task.response as? HTTPURLResponse else { return OfflineTutorError(.downloadFailed) }
    return OfflineTutorDownloadPolicy.validateResponse(
      statusCode: http.statusCode, expectedContentLength: http.expectedContentLength, finalURL: http.url)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // Runs before the system deletes `location`: validate, then move it now.
    if rejection != nil || token.isCancelled { return }
    if let error = checkResponse(downloadTask) { rejection = error; return }
    let size = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
    guard Int64(size) == OfflineTutorDownloadPolicy.expectedBytes else {
      rejection = OfflineTutorError(.downloadInvalid)
      return
    }
    do {
      let target = try store.newDownloadStagingURL()
      try FileManager.default.moveItem(at: location, to: target)
      staged = target
    } catch {
      rejection = OfflineTutorError(.insufficientStorage)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if error == nil, rejection == nil, !token.isCancelled, let staged {
      self.staged = nil
      complete(.success(staged))
      return
    }
    let nsError = error.map { $0 as NSError }
    let unavailable = (error as? URLError)?.networkUnavailableReason != nil
    let mapped = OfflineTutorDownloadPolicy.classify(
      errorDomain: nsError?.domain ?? NSURLErrorDomain, errorCode: nsError?.code ?? 0,
      hasNetworkUnavailableReason: unavailable, ourRejection: rejection, userCancelled: token.isCancelled)
    complete(.failure(error == nil && rejection == nil && !token.isCancelled ? OfflineTutorError(.downloadFailed) : mapped))
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    // `invalidateAndCancel` before the task reported completion: finish once.
    complete(.failure(token.isCancelled ? OfflineTutorError(.cancelled) : OfflineTutorError(.downloadFailed)))
  }
}
