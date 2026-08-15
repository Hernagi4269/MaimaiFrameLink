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

enum CameraLens: String, CaseIterable, Identifiable {
    case ultraWide
    case wide
    case telephoto

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ultraWide: return "0.5×"
        case .wide: return "1×"
        case .telephoto: return "望遠"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide: return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }
}

final class CameraRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "準備中"
    @Published private(set) var formatLabel = "1080p / 60fps"
    @Published private(set) var is60FPS = false
    @Published private(set) var lastFinishedAt: Date?
    @Published private(set) var captureOrientation: ManualCaptureOrientation = .portrait
    @Published private(set) var availableLenses: [CameraLens] = [.wide]
    @Published private(set) var selectedLens: CameraLens = .wide
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var minExposureBias: Float = -2
    @Published private(set) var maxExposureBias: Float = 2
    @Published private(set) var isAEAFLocked = false
    @Published private(set) var audioEnabled = false
    @Published private(set) var lastRecordingVerification = ""
    @Published private(set) var healthWarning = ""
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var freeSpaceLabel = ""
    @Published private(set) var systemPressureLabel = "正常"

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "MaimaiFrameLink.capture")
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var observerTokens: [NSObjectProtocol] = []
    private let finishLock = NSLock()
    private var finishCallbacks: [(VideoInfo?) -> Void] = []
    @Published private(set) var lastRecordingError = ""
    private var pressureTimer: DispatchSourceTimer?

    override init() {
        super.init()
        installStabilityObservers()
        refreshHealthState()
        requestPermissionsAndConfigure()
    }

    deinit {
        pressureTimer?.cancel()
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
    }

    private func installStabilityObservers() {
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshHealthState()
        })
        observerTokens.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshHealthState()
        })
        observerTokens.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            self.healthWarning = "カメラが一時中断されました"
            self.status = "撮影中断"
        })
        observerTokens.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refreshHealthState()
            self.recoverCaptureSession(reason: "中断復帰")
        })
        observerTokens.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            let nsError = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = nsError?.localizedDescription ?? "不明なエラー"
            self.healthWarning = "カメラエラー: \(message)・自動復旧を試行します"
            self.recoverCaptureSession(reason: message)
        })
        observerTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.isRecording { self.healthWarning = "音声入出力が変更されました。録音状態を確認してください" }
        })
    }

    func refreshHealthState() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let bytes = VideoStore.shared.availableCapacityBytes() {
            let gb = Double(bytes) / 1_073_741_824.0
            freeSpaceLabel = String(format: "空き %.1fGB", gb)
            if bytes < 500_000_000 {
                healthWarning = "ストレージ残量が少なすぎます"
            } else if bytes < 2_000_000_000, healthWarning.isEmpty {
                healthWarning = "ストレージ残量が少なくなっています"
            }
        }

        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            healthWarning = "端末が高温です。60fps維持が難しくなる可能性があります"
        case .critical:
            healthWarning = "端末が非常に高温です。録画停止の可能性があります"
        default:
            if healthWarning.contains("高温") { healthWarning = "" }
        }
    }

    private func requestPermissionsAndConfigure() {
        Task {
            let cameraOK = await AVCaptureDevice.requestAccess(for: .video)
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            guard cameraOK else {
                await MainActor.run { self.status = "カメラ権限が必要です" }
                return
            }
            if micOK { configureRecordingAudioSession() }
            sessionQueue.async { self.configureSession(includeAudio: micOK) }
        }
    }

    private func configureRecordingAudioSession() {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try audio.setPreferredSampleRate(48_000)
            try audio.setActive(true)
        } catch {
            print("Recording audio session configuration failed: \(error)")
        }
    }

    private func configureSession(includeAudio: Bool) {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        var configurationCommitted = false
        defer {
            if !configurationCommitted { session.commitConfiguration() }
        }

        let lenses = discover60FPSLenses()
        DispatchQueue.main.async {
            self.availableLenses = lenses.isEmpty ? [.wide] : lenses
        }

        let initialLens: CameraLens = lenses.contains(.wide) ? .wide : (lenses.first ?? .wide)
        guard let camera = device(for: initialLens),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput) else {
            DispatchQueue.main.async { self.status = "背面カメラを開始できません" }
            return
        }

        let configuredFor60FPS = configureStable1080p60(camera)
        videoDevice = camera
        videoInput = cameraInput
        cameraInput.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 60)
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

        configureMovieOutput()

        session.commitConfiguration()
        configurationCommitted = true
        session.startRunning()

        let actual = actualCaptureDescription(camera)
        DispatchQueue.main.async {
            self.selectedLens = initialLens
            self.is60FPS = configuredFor60FPS && actual.isFHD60
            self.formatLabel = actual.label
            self.audioEnabled = includeAudio && self.movieOutput.connection(with: .audio) != nil
            self.status = self.is60FPS ? "撮影可能" : "60fpsを確認できません"
            self.updateExposureRange(camera)
        }
        startSystemPressureMonitor(camera)
    }

    private func configureMovieOutput() {
        if let connection = movieOutput.connection(with: .video) {
            connection.preferredVideoStabilizationMode = .off
            if movieOutput.availableVideoCodecTypes.contains(.h264) {
                // AVCaptureMovieFileOutput automatically chooses an H.264 profile and
                // bitrate appropriate for the active high-frame-rate capture format.
                // Forcing encoder tuning here made recording less portable across iPhones.
                movieOutput.setOutputSettings([
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoExpectedSourceFrameRateKey: 60,
                        AVVideoAverageBitRateKey: 20_000_000,
                        AVVideoMaxKeyFrameIntervalKey: 60
                    ]
                ], for: connection)
            }
        }

        if let audioConnection = movieOutput.connection(with: .audio) {
            movieOutput.setOutputSettings([
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ], for: audioConnection)
        }
    }

    private func discover60FPSLenses() -> [CameraLens] {
        CameraLens.allCases.filter { lens in
            guard let camera = device(for: lens) else { return false }
            return has1080p60Format(camera)
        }
    }

    private func device(for lens: CameraLens) -> AVCaptureDevice? {
        AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
    }

    private func has1080p60Format(_ camera: AVCaptureDevice) -> Bool {
        camera.formats.contains { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == 1920, dimensions.height == 1080 else { return false }
            return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 60 && $0.maxFrameRate >= 60 }
        }
    }

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

        guard let selected = candidates.min(by: { lhs, rhs in
            let lhsDistance = abs(lhs.maxFPS - targetFPS)
            let rhsDistance = abs(rhs.maxFPS - targetFPS)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.minFPS > rhs.minFPS
        }) else { return false }

        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            camera.activeFormat = selected.format
            if #available(iOS 18.0, *), selected.format.isAutoVideoFrameRateSupported {
                camera.isAutoVideoFrameRateEnabled = false
            }
            camera.automaticallyAdjustsVideoHDREnabled = false
            if selected.format.isVideoHDRSupported { camera.isVideoHDREnabled = false }

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
            DispatchQueue.main.async { self.status = "60fps設定に失敗: \(error.localizedDescription)" }
            return false
        }
    }

    private func actualCaptureDescription(_ camera: AVCaptureDevice) -> (label: String, isFHD60: Bool) {
        let d = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let seconds = CMTimeGetSeconds(camera.activeVideoMinFrameDuration)
        let fps = seconds > 0 ? Int((1.0 / seconds).rounded()) : 0
        let label = d.width == 1920 && d.height == 1080 ? "1080p / \(fps)fps" : "\(d.width)×\(d.height) / \(fps)fps"
        return (label, d.width == 1920 && d.height == 1080 && fps >= 59)
    }

    private func configureInitialFocus(_ camera: AVCaptureDevice) {
        if camera.isSmoothAutoFocusSupported { camera.isSmoothAutoFocusEnabled = true }
        if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if camera.isFocusModeSupported(.autoFocus) {
            camera.focusMode = .autoFocus
        } else if camera.isFocusModeSupported(.locked) {
            camera.focusMode = .locked
        }
    }

    func focus(at devicePoint: CGPoint) {
        let clamped = CGPoint(x: min(max(devicePoint.x, 0), 1), y: min(max(devicePoint.y, 0), 1))
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.videoDevice else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = clamped }
                if camera.isFocusModeSupported(.autoFocus) { camera.focusMode = .autoFocus }
                if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = clamped }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                } else if camera.isExposureModeSupported(.autoExpose) {
                    camera.exposureMode = .autoExpose
                }
                DispatchQueue.main.async { self.isAEAFLocked = false }
            } catch {
                DispatchQueue.main.async { self.status = "フォーカス設定に失敗: \(error.localizedDescription)" }
            }
        }
    }

    func setAEAFLocked(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.videoDevice else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if locked {
                    if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked }
                    if camera.isExposureModeSupported(.locked) { camera.exposureMode = .locked }
                } else {
                    configureInitialFocus(camera)
                    if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
                }
                DispatchQueue.main.async { self.isAEAFLocked = locked }
            } catch {
                DispatchQueue.main.async { self.status = "AE/AF設定に失敗: \(error.localizedDescription)" }
            }
        }
    }

    func setExposureBias(_ value: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.videoDevice else { return }
            let clamped = min(max(value, camera.minExposureTargetBias), camera.maxExposureTargetBias)
            do {
                try camera.lockForConfiguration()
                camera.setExposureTargetBias(clamped, completionHandler: nil)
                camera.unlockForConfiguration()
                DispatchQueue.main.async { self.exposureBias = clamped }
            } catch {
                DispatchQueue.main.async { self.status = "露出補正に失敗: \(error.localizedDescription)" }
            }
        }
    }

    private func updateExposureRange(_ camera: AVCaptureDevice) {
        minExposureBias = max(camera.minExposureTargetBias, -3)
        maxExposureBias = min(camera.maxExposureTargetBias, 3)
        exposureBias = camera.exposureTargetBias
    }

    func selectLens(_ lens: CameraLens) {
        guard !isRecording, lens != selectedLens else { return }
        sessionQueue.async { [weak self] in
            guard let self, let newDevice = self.device(for: lens), self.has1080p60Format(newDevice) else { return }
            guard let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

            self.session.beginConfiguration()
            if let oldInput = self.videoInput { self.session.removeInput(oldInput) }
            guard self.session.canAddInput(newInput) else {
                if let oldInput = self.videoInput, self.session.canAddInput(oldInput) { self.session.addInput(oldInput) }
                self.session.commitConfiguration()
                return
            }
            let ok = self.configureStable1080p60(newDevice)
            self.session.addInput(newInput)
            self.videoInput = newInput
            self.videoDevice = newDevice
            newInput.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 60)
            self.configureMovieOutput()
            self.session.commitConfiguration()
            self.applyRotationToMovieOutput()

            let actual = self.actualCaptureDescription(newDevice)
            DispatchQueue.main.async {
                self.selectedLens = lens
                self.is60FPS = ok && actual.isFHD60
                self.formatLabel = actual.label
                self.updateExposureRange(newDevice)
                self.status = self.is60FPS ? "撮影可能" : "60fpsを確認できません"
            }
        }
    }

    func setCaptureOrientation(_ orientation: ManualCaptureOrientation) {
        guard !isRecording else { return }
        captureOrientation = orientation
        applyRotationToMovieOutput()
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            _ = startRecording()
        }
    }

    @discardableResult
    func startRecording() -> Bool {
        // Reliability-first recording core: this intentionally mirrors the
        // early on-device shutter path that was proven to record correctly.
        // Remote recording calls this exact same method on the main thread.
        guard session.isRunning else {
            lastRecordingError = "Capture Sessionが停止しています"
            status = "録画開始不可・カメラ未起動"
            return false
        }
        guard !movieOutput.isRecording, !isRecording else {
            return false
        }

        refreshHealthState()
        if let bytes = VideoStore.shared.availableCapacityBytes(), bytes < 500_000_000 {
            lastRecordingError = "空き容量不足"
            status = "空き容量不足で録画できません"
            return false
        }

        applyRotationToMovieOutput()
        configureRecordingAudioSession()
        let url = VideoStore.shared.newRecordingURL()
        lastRecordingError = ""

        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        status = "録画中"
        return true
    }

    func stopRecording() {
        guard movieOutput.isRecording else {
            if isRecording {
                isRecording = false
                status = "録画は開始されていません"
            }
            return
        }
        movieOutput.stopRecording()
    }

    func stopRecording(completion: @escaping (VideoInfo?) -> Void) {
        guard movieOutput.isRecording else {
            isRecording = false
            completion(VideoStore.shared.latest())
            return
        }

        finishLock.lock()
        finishCallbacks.append(completion)
        finishLock.unlock()
        movieOutput.stopRecording()
    }

    private func applyRotationToMovieOutput() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        let angle = captureOrientation.rotationAngle
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let finishedSuccessfully: Bool
        if let nsError = error as NSError? {
            finishedSuccessfully = (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        } else {
            finishedSuccessfully = true
        }

        let latest: VideoInfo?
        if finishedSuccessfully {
            latest = VideoStore.shared.finalizeRecording(at: outputFileURL)
        } else {
            VideoStore.shared.discardInProgress(at: outputFileURL)
            latest = nil
        }

        finishLock.lock()
        let callbacks = finishCallbacks
        finishCallbacks.removeAll()
        finishLock.unlock()

        DispatchQueue.main.async {
            self.isRecording = false
            self.lastFinishedAt = Date()
            if !finishedSuccessfully {
                self.lastRecordingError = error?.localizedDescription ?? "録画が開始直後に終了しました"
            }
            if finishedSuccessfully, latest != nil {
                self.status = "保存完了"
            } else {
                self.status = "保存エラー: \(error?.localizedDescription ?? "動画確定に失敗")"
            }
            self.refreshHealthState()
            NotificationCenter.default.post(name: .recordingDidFinish, object: latest)
            callbacks.forEach { $0(latest) }
        }

        if let latest, let finalURL = VideoStore.shared.url(for: latest.fileName) {
            Task { await verifyRecording(at: finalURL) }
        }
    }

    private func recoverCaptureSession(reason: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                if self.session.isRunning {
                    self.healthWarning = ""
                    self.status = self.isRecording ? "録画中" : (self.is60FPS ? "撮影可能" : self.status)
                } else {
                    self.healthWarning = "カメラ自動復旧に失敗しました: \(reason)"
                }
            }
        }
    }

    private func startSystemPressureMonitor(_ camera: AVCaptureDevice) {
        pressureTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self, weak camera] in
            guard let self, let camera else { return }
            let level = camera.systemPressureState.level
            let label: String
            let warning: String?
            let shouldStopRecording: Bool
            switch level {
            case .nominal:
                label = "正常"; warning = nil; shouldStopRecording = false
            case .fair:
                label = "やや高い"; warning = nil; shouldStopRecording = false
            case .serious:
                label = "高い"; warning = "カメラ負荷が高くなっています。発熱に注意してください"; shouldStopRecording = false
            case .critical:
                label = "非常に高い"; warning = "カメラ負荷が非常に高くなっています。端末を冷ましてください"; shouldStopRecording = false
            case .shutdown:
                label = "停止レベル"; warning = "カメラがシステム負荷で停止する可能性があります"; shouldStopRecording = false
            default:
                label = "不明"; warning = nil; shouldStopRecording = false
            }
            DispatchQueue.main.async {
                self.systemPressureLabel = label
                if let warning { self.healthWarning = warning }
            }
            // Never stop a maimai recording proactively because of pressure alone.
            // AVCaptureSession interruption/runtime-error handling remains responsible for
            // genuine camera shutdowns. A warning is safer than creating a sub-second clip.
        }
        pressureTimer = timer
        timer.resume()
    }

    private func verifyRecording(at url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }
            let size = try await videoTrack.load(.naturalSize)
            let fps = try await videoTrack.load(.nominalFrameRate)
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            let text = "\(Int(size.width))×\(Int(size.height)) / \(Int(fps.rounded()))fps / \(audioTrack == nil ? "音声なし" : "音声あり")"
            await MainActor.run {
                self.lastRecordingVerification = text
                self.status = "保存完了・\(text)"
            }
        } catch {
            await MainActor.run { self.lastRecordingVerification = "録画検証失敗" }
        }
    }
}

extension Notification.Name {
    static let recordingDidFinish = Notification.Name("MaimaiFrameLink.recordingDidFinish")
}
