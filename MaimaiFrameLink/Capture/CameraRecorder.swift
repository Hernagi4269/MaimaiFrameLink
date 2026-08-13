import AVFoundation
import UIKit

enum ManualCaptureOrientation: String, CaseIterable, Identifiable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    var id: String { rawValue }

    var isPortrait: Bool {
        self == .portrait || self == .portraitUpsideDown
    }

    var isReversed: Bool {
        self == .portraitUpsideDown || self == .landscapeRight
    }

    var rotationAngle: CGFloat {
        switch self {
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        case .portraitUpsideDown: return 270
        case .portrait: return 90
        }
    }
}

final class CameraRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "準備中"
    @Published private(set) var is60FPS = false
    @Published private(set) var lastFinishedAt: Date?
    @Published private(set) var captureOrientation: ManualCaptureOrientation = .portrait

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "MaimaiFrameLink.capture")
    private var videoDevice: AVCaptureDevice?

    override init() {
        super.init()
        requestPermissionsAndConfigure()
    }

    private func requestPermissionsAndConfigure() {
        Task {
            let cameraOK = await AVCaptureDevice.requestAccess(for: .video)
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            guard cameraOK else {
                await MainActor.run { self.status = "カメラ権限が必要です" }
                return
            }
            sessionQueue.async { self.configureSession(includeAudio: micOK) }
        }
    }

    private func configureSession(includeAudio: Bool) {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        var configurationCommitted = false
        defer {
            if !configurationCommitted {
                session.commitConfiguration()
            }
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput) else {
            DispatchQueue.main.async { self.status = "背面カメラを開始できません" }
            return
        }

        let configuredFor60FPS = configureStable1080p60(camera)
        videoDevice = camera
        session.addInput(cameraInput)

        if includeAudio,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        guard session.canAddOutput(movieOutput) else {
            DispatchQueue.main.async { self.status = "録画出力を開始できません" }
            return
        }
        session.addOutput(movieOutput)
        movieOutput.movieFragmentInterval = .invalid

        if let connection = movieOutput.connection(with: .video) {
            connection.preferredVideoStabilizationMode = .off
            if movieOutput.availableVideoCodecTypes.contains(.h264) {
                movieOutput.setOutputSettings([
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoExpectedSourceFrameRateKey: 60,
                        AVVideoAverageBitRateKey: 16_000_000
                    ]
                ], for: connection)
            }
        }

        session.commitConfiguration()
        configurationCommitted = true
        session.startRunning()

        DispatchQueue.main.async {
            self.is60FPS = configuredFor60FPS
            self.status = configuredFor60FPS ? "1080p / 60fps" : "撮影可能（60fps非確認）"
        }
    }

    /// Selects a normal 1080p format whose supported range is closest to 60 fps.
    /// This deliberately avoids picking the last 1080p format because that can be a
    /// 120/240-fps slow-motion format and can cause unstable exposure/preview behavior.
    private func configureStable1080p60(_ camera: AVCaptureDevice) -> Bool {
        let targetFPS = 60.0
        let candidates: [(format: AVCaptureDevice.Format, maxFPS: Double, minFPS: Double)] = camera.formats.compactMap { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == 1920, dimensions.height == 1080 else { return nil }

            guard let range = format.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= targetFPS && $0.maxFrameRate >= targetFPS
            }) else { return nil }

            return (format, range.maxFrameRate, range.minFrameRate)
        }

        // Prefer a standard 60-fps format over slow-motion 120/240-fps formats.
        guard let selected = candidates.min(by: { lhs, rhs in
            let lhsDistance = abs(lhs.maxFPS - targetFPS)
            let rhsDistance = abs(rhs.maxFPS - targetFPS)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }

            let lhsSubtype = CMFormatDescriptionGetMediaSubType(lhs.format.formatDescription)
            let rhsSubtype = CMFormatDescriptionGetMediaSubType(rhs.format.formatDescription)
            let fullRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if lhsSubtype == fullRange && rhsSubtype != fullRange { return true }
            if rhsSubtype == fullRange && lhsSubtype != fullRange { return false }

            // Prefer the less extreme lower bound as a final tie breaker.
            return lhs.minFPS > rhs.minFPS
        }) else {
            return false
        }

        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            camera.activeFormat = selected.format

            // Automatic low-light frame-rate switching conflicts with a strict 60-fps
            // recording workflow on devices that expose this option.
            if #available(iOS 18.0, *), selected.format.isAutoVideoFrameRateSupported {
                camera.isAutoVideoFrameRateEnabled = false
            }

            camera.automaticallyAdjustsVideoHDREnabled = false
            if selected.format.isVideoHDRSupported {
                camera.isVideoHDREnabled = false
            }

            let frameDuration = CMTime(value: 1, timescale: 60)
            camera.activeVideoMinFrameDuration = frameDuration
            camera.activeVideoMaxFrameDuration = frameDuration

            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            configureInitialFocus(camera)
            return true
        } catch {
            DispatchQueue.main.async {
                self.status = "60fps設定に失敗: \(error.localizedDescription)"
            }
            return false
        }
    }


    /// Camera.app-like stable focus behavior for a fixed gameplay camera:
    /// perform a single autofocus pass at the center, then let AVFoundation lock it.
    /// A later screen tap performs another one-shot autofocus at that point.
    private func configureInitialFocus(_ camera: AVCaptureDevice) {
        if camera.isSmoothAutoFocusSupported {
            camera.isSmoothAutoFocusEnabled = true
        }

        if camera.isFocusPointOfInterestSupported {
            camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }

        if camera.isFocusModeSupported(.autoFocus) {
            camera.focusMode = .autoFocus
        } else if camera.isFocusModeSupported(.locked) {
            camera.focusMode = .locked
        }
    }

    /// Re-focuses once at the tapped preview point. The point is in AVFoundation's
    /// normalized capture-device coordinate system (0...1).
    func focus(at devicePoint: CGPoint) {
        let clamped = CGPoint(
            x: min(max(devicePoint.x, 0), 1),
            y: min(max(devicePoint.y, 0), 1)
        )

        sessionQueue.async { [weak self] in
            guard let self, let camera = self.videoDevice else { return }

            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }

                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = clamped
                }
                if camera.isFocusModeSupported(.autoFocus) {
                    camera.focusMode = .autoFocus
                }

                // Match the familiar tap-to-focus behavior by metering exposure at
                // the same point while keeping exposure adaptive to arcade lighting.
                if camera.isExposurePointOfInterestSupported {
                    camera.exposurePointOfInterest = clamped
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                } else if camera.isExposureModeSupported(.autoExpose) {
                    camera.exposureMode = .autoExpose
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "フォーカス設定に失敗: \(error.localizedDescription)"
                }
            }
        }
    }

    func setCaptureOrientation(_ orientation: ManualCaptureOrientation) {
        guard !isRecording else { return }
        captureOrientation = orientation
        applyRotationToMovieOutput()
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard session.isRunning, !movieOutput.isRecording else { return }
        applyRotationToMovieOutput()
        let url = VideoStore.shared.newRecordingURL()
        movieOutput.startRecording(to: url, recordingDelegate: self)
        DispatchQueue.main.async {
            self.isRecording = true
            self.status = self.is60FPS ? "録画中 1080p / 60fps" : "録画中"
        }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    private func applyRotationToMovieOutput() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        let angle = captureOrientation.rotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.lastFinishedAt = Date()
            self.status = error == nil
                ? (self.is60FPS ? "保存完了・1080p / 60fps" : "保存完了")
                : "保存エラー: \(error!.localizedDescription)"
            NotificationCenter.default.post(name: .recordingDidFinish, object: nil)
        }
    }
}

extension Notification.Name {
    static let recordingDidFinish = Notification.Name("MaimaiFrameLink.recordingDidFinish")
}
