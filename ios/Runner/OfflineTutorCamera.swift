import AVFoundation
import CoreImage
import Flutter
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Single owner of the back-camera `AVCaptureSession` for the tutor.
///
/// Intent (main thread): the camera runs only while a tutor preview is attached,
/// Flutter has not paused it (frozen scene, studying, choosing a photo) and the
/// app is in the foreground (`OfflineTutorCameraIntent`). Returning to the
/// foreground never restarts a camera Flutter paused, and nothing here prompts
/// for permission unless a tutor preview is attached and wants the camera.
///
/// Every intent change bumps `generation`; session-queue work and late permission
/// callbacks carry the generation they were issued for and do nothing if it is
/// stale. All session graph edits run on `sessionQueue`.
///
/// Frames stay in memory and are accepted only while the session is running for
/// the current generation; stopping clears them (after draining the frame queue),
/// so `capturePhoto` never returns a frame from an earlier scene. Captures are
/// downscaled, metadata-free, app-owned temporary JPEGs. Nothing is uploaded or
/// saved to Photos.
final class OfflineTutorCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  static let shared = OfflineTutorCamera()

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "app.veea.english.tutor.camera")
  private let frameQueue = DispatchQueue(label: "app.veea.english.tutor.frames")
  private let videoOutput = AVCaptureVideoDataOutput()
  private let ciContext = CIContext(options: [.cacheIntermediates: false])

  /// Guards `latestFrame`, `acceptingFrames` and `generation`.
  private let frameLock = NSLock()
  private var latestFrame: CVPixelBuffer?
  private var acceptingFrames = false
  private var generation: UInt64 = 0

  /// Session queue only.
  private var configured = false

  /// Main thread only.
  private var intent = OfflineTutorCameraIntent()
  private let attached = NSHashTable<OfflineTutorPreviewView>.weakObjects()
  private var requestedRunning = false

  /// Reports errors to Flutter (main thread).
  var onError: ((OfflineTutorError) -> Void)?

  var captureSession: AVCaptureSession { session }

  // MARK: Intent (main thread)

  func attach(_ view: OfflineTutorPreviewView) {
    attached.add(view)
    intent.attachedViews = attached.allObjects.count
    apply()
  }

  func detach(_ view: OfflineTutorPreviewView) {
    attached.remove(view)
    intent.attachedViews = attached.allObjects.count
    apply()
  }

  /// Flutter `pause`: keep the camera off until Flutter `resume`, even across
  /// background/foreground transitions.
  func pause() {
    intent.explicitlyPaused = true
    apply()
  }

  /// Flutter `resume` (live view requested, e.g. starting a new scene).
  func resume() {
    intent.explicitlyPaused = false
    apply(forceRestart: true)
  }

  /// App lifecycle. Foregrounding restores only what Flutter still wants.
  func setBackgrounded(_ backgrounded: Bool) {
    intent.backgrounded = backgrounded
    apply()
  }

  /// Tutor closed: forget previews and Flutter's pause, stop and tear down the
  /// session graph, delete captures. A future preview reconfigures everything.
  func release() {
    attached.removeAllObjects()
    intent.dispose()
    requestedRunning = false
    let gen = bumpGeneration()
    stopOnQueue(generation: gen, teardown: true)
    OfflineTutorImages.purgeCaptures()
  }

  private func bumpGeneration() -> UInt64 {
    frameLock.withLock {
      generation &+= 1
      return generation
    }
  }

  private func isCurrent(_ gen: UInt64) -> Bool { frameLock.withLock { generation == gen } }

  private func apply(forceRestart: Bool = false) {
    let wants = intent.wantsRunning
    guard wants != requestedRunning || (wants && forceRestart) else { return }
    requestedRunning = wants
    let gen = bumpGeneration()
    if wants { start(generation: gen) } else { stopOnQueue(generation: gen, teardown: false) }
  }

  // MARK: Session

  private func start(generation gen: UInt64) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      startOnQueue(generation: gen)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          // Paused, detached, backgrounded or disposed meanwhile: do nothing.
          guard self.isCurrent(gen), self.intent.wantsRunning else { return }
          if granted {
            self.startOnQueue(generation: gen)
          } else {
            self.onError?(OfflineTutorError(.cameraPermissionDenied))
          }
        }
      }
    default:
      onError?(OfflineTutorError(.cameraPermissionDenied))
    }
  }

  private func startOnQueue(generation gen: UInt64) {
    sessionQueue.async {
      guard self.isCurrent(gen) else { return }
      if !self.configured {
        guard self.configure() else {
          DispatchQueue.main.async { if self.isCurrent(gen) { self.onError?(OfflineTutorError(.cameraUnavailable)) } }
          return
        }
      }
      // Restart cleanly so no frame from before this request survives.
      if self.session.isRunning { self.haltRunning() }
      // Check and enable atomically: a stop bumps `generation` under the same lock.
      let stillCurrent: Bool = self.frameLock.withLock {
        guard self.generation == gen else { return false }
        self.latestFrame = nil
        self.acceptingFrames = true
        return true
      }
      guard stillCurrent else { return }
      // A stop requested from now on refuses frames at once and halts after this.
      self.session.startRunning()
    }
  }

  private func stopOnQueue(generation gen: UInt64, teardown: Bool) {
    // Refuse new frames immediately, even before the queue gets to the stop.
    frameLock.withLock {
      acceptingFrames = false
      latestFrame = nil
    }
    sessionQueue.async {
      // A newer start request supersedes this stop (it restarts cleanly itself).
      guard teardown || self.isCurrent(gen) else { return }
      self.haltRunning()
      if teardown && self.configured {
        self.session.beginConfiguration()
        self.session.inputs.forEach { self.session.removeInput($0) }
        self.session.outputs.forEach { self.session.removeOutput($0) }
        self.session.commitConfiguration()
        self.configured = false
      }
    }
  }

  /// Session queue: stop, drain frames already handed to the delegate, clear.
  private func haltRunning() {
    frameLock.withLock { acceptingFrames = false }
    if session.isRunning { session.stopRunning() }
    frameQueue.sync {}
    frameLock.withLock { latestFrame = nil }
  }

  /// Runs on `sessionQueue`.
  private func configure() -> Bool {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
      let input = try? AVCaptureDeviceInput(device: device)
    else { return false }
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
    guard session.canAddInput(input) else { return false }
    session.addInput(input)
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
    guard session.canAddOutput(videoOutput) else {
      session.removeInput(input)
      return false
    }
    session.addOutput(videoOutput)
    if let connection = videoOutput.connection(with: .video) {
      if #available(iOS 17.0, *) {
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
      } else if connection.isVideoOrientationSupported {
        connection.videoOrientation = .portrait
      }
    }
    configured = true
    return true
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    frameLock.withLock { if acceptingFrames { latestFrame = buffer } }
  }

  // MARK: Capture

  /// Writes the latest live frame of the current camera run to an app-owned JPEG
  /// and returns its path. Fails with `CAMERA_UNAVAILABLE` ("not ready") when the
  /// camera is paused, stopped or has not delivered a frame since it (re)started.
  func capturePhoto() throws -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: break
    case .notDetermined: throw OfflineTutorError(.cameraUnavailable)
    default: throw OfflineTutorError(.cameraPermissionDenied)
    }
    guard let frame = frameLock.withLock({ acceptingFrames ? latestFrame : nil }) else {
      throw OfflineTutorError(.cameraUnavailable, message: "The camera is not ready yet. Try again in a moment.")
    }
    let image = CIImage(cvPixelBuffer: frame)
    guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
      throw OfflineTutorError(.cameraUnavailable)
    }
    guard let data = OfflineTutorImages.encodeJPEG(cgImage) else { throw OfflineTutorError(.cameraUnavailable) }
    return try OfflineTutorImages.writeCapture(data)
  }
}

// MARK: - Image helpers

enum OfflineTutorImages {
  static var captureDirectory: URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("offline_tutor", isDirectory: true)
  }

  private static let maxKeptCaptures = 6
  nonisolated(unsafe) private static var captureSequence: UInt64 = 0

  /// Re-encodes as JPEG with no EXIF/GPS/TIFF properties, longest side <= 1024.
  static func encodeJPEG(_ image: CGImage) -> Data? {
    var source = image
    if let target = OfflineTutorPathPolicy.scaledSize(width: image.width, height: image.height),
      target.width != image.width || target.height != image.height
    {
      guard let scaled = scale(image, width: target.width, height: target.height) else { return nil }
      source = scaled
    }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: OfflineTutorLimits.jpegQuality]
    CGImageDestinationAddImage(dest, source, options as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
  }

  private static func scale(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  static func writeCapture(_ data: Data) throws -> String {
    let fm = FileManager.default
    let dir = captureDirectory
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      // Zero-padded sequence keeps names sortable by age without file timestamps.
      captureSequence &+= 1
      let stamp = String(format: "%020llu", UInt64(Date().timeIntervalSince1970 * 1000) &* 1000 &+ captureSequence % 1000)
      let url = dir.appendingPathComponent("scene-\(stamp)-\(UUID().uuidString).jpg")
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      pruneCaptures(keeping: url)
      return url.path
    } catch {
      throw OfflineTutorError(.cameraUnavailable)
    }
  }

  private static func pruneCaptures(keeping newest: URL) {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: captureDirectory, includingPropertiesForKeys: nil)
    else { return }
    let sorted = files.filter { $0.lastPathComponent.hasPrefix("scene-") }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    for file in sorted.dropFirst(maxKeptCaptures) where file != newest { try? fm.removeItem(at: file) }
  }

  static func purgeCaptures() {
    try? FileManager.default.removeItem(at: captureDirectory)
  }

  /// Resolves `path` and accepts it only inside this app's tmp or Caches directory.
  static func allowedImageURL(_ path: String) -> URL? {
    guard let resolved = realPath(path) else { return nil }
    let roots = [NSTemporaryDirectory(),
                 FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path]
      .compactMap(realPath)
    guard OfflineTutorPathPolicy.isAllowedImagePath(resolvedPath: resolved, allowedRoots: roots) else { return nil }
    let url = URL(fileURLWithPath: resolved)
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true, let size = values.fileSize, size > 0,
      Int64(size) <= OfflineTutorLimits.maxImageInputBytes
    else { return nil }
    return url
  }

  private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// Loads a validated image file as a model-ready JPEG (orientation applied,
  /// longest side <= 1024, metadata stripped). Runs off the main thread.
  static func modelInput(fromPath path: String) throws -> Data {
    guard let url = allowedImageURL(path),
      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw OfflineTutorError(.invalidImage) }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: OfflineTutorLimits.maxImagePixelSide,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let data = encodeJPEG(image)
    else { throw OfflineTutorError(.invalidImage) }
    return data
  }
}

// MARK: - Platform view

final class OfflineTutorPreviewView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  private let camera: OfflineTutorCamera

  init(frame: CGRect, camera: OfflineTutorCamera) {
    self.camera = camera
    super.init(frame: frame)
    backgroundColor = .black
    previewLayer.videoGravity = .resizeAspectFill
    previewLayer.session = camera.captureSession
    isAccessibilityElement = true
    accessibilityLabel = "Camera preview"
    camera.attach(self)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func detach() {
    previewLayer.session = nil
    camera.detach(self)
  }
}

final class OfflineTutorPreviewPlatformView: NSObject, FlutterPlatformView {
  private let preview: OfflineTutorPreviewView

  init(frame: CGRect, camera: OfflineTutorCamera) {
    preview = OfflineTutorPreviewView(frame: frame, camera: camera)
  }

  func view() -> UIView { preview }

  deinit {
    let preview = self.preview
    DispatchQueue.main.async { preview.detach() }
  }
}

final class OfflineTutorPreviewFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "veea/camera_tutor_preview"
  private let camera: OfflineTutorCamera

  init(camera: OfflineTutorCamera) { self.camera = camera }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    OfflineTutorPreviewPlatformView(frame: frame, camera: camera)
  }
}
