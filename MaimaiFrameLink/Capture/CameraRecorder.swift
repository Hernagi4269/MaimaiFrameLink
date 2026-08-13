import AVFoundation
import UIKit

final class CameraRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "準備中"
    @Published private(set) var is60FPS = false
    @Published private(set) var lastFinishedAt: Date?

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "MaimaiFrameLink.capture")

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

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput) else {
            DispatchQueue.main.async { self.status = "背面カメラを開始できません" }
            return
        }

        do {
            let candidates = camera.formats.filter { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let fpsOK = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 59.9 }
                return d.width == 1920 && d.height == 1080 && fpsOK
            }
            if let format = candidates.last {
                try camera.lockForConfiguration()
                camera.activeFormat = format
                camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
                camera.unlockForConfiguration()
                DispatchQueue.main.async { self.is60FPS = true }
            }
        } catch {
            DispatchQueue.main.async { self.status = "60fps設定に失敗: \(error.localizedDescription)" }
        }

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
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
            }
        }

        // AVCaptureSession must not be started while a configuration transaction is open.
        session.commitConfiguration()
        session.startRunning()

        let configuredFor60FPS = is60FPS
        DispatchQueue.main.async {
            self.status = configuredFor60FPS ? "1080p / 60fps" : "撮影可能（60fps非確認）"
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard session.isRunning, !movieOutput.isRecording else { return }
        updateRotation()
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

    private func updateRotation() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .portrait
        let angle: CGFloat
        switch orientation {
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.lastFinishedAt = Date()
            self.status = error == nil ? (self.is60FPS ? "保存完了・1080p / 60fps" : "保存完了") : "保存エラー: \(error!.localizedDescription)"
            NotificationCenter.default.post(name: .recordingDidFinish, object: nil)
        }
    }
}

extension Notification.Name {
    static let recordingDidFinish = Notification.Name("MaimaiFrameLink.recordingDidFinish")
}
