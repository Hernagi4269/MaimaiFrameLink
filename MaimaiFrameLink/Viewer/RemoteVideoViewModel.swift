import AVFoundation
import Foundation
import Photos

private struct RecordingStopResponse: Decodable {
    let ok: Bool
    let recording: Bool?
    let latest: VideoInfo?
}

@MainActor
final class RemoteVideoViewModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var videos: [VideoInfo] = []
    @Published var selectedIndex = 0
    @Published var status = "動画待機中"
    @Published var isPlaying = false
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var videoAspectRatio: CGFloat = 9.0 / 16.0
    @Published var isBusy = false
    @Published var isRemoteRecording = false
    @Published var trimStartSeconds: Double = 0
    @Published var trimEndSeconds: Double = 0
    @Published var videoFrameRate: Double = 60

    private var baseURL: URL?
    private var timer: Timer?
    private var periodicToken: Any?
    private var consecutiveConnectionFailures = 0

    init() {
        configurePlaybackAudio()
        player.isMuted = false
        player.volume = 1.0
    }

    private func configurePlaybackAudio() {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
        } catch {
            print("Playback audio session configuration failed: \(error)")
        }
    }

    var current: VideoInfo? {
        guard videos.indices.contains(selectedIndex) else { return nil }
        return videos[selectedIndex]
    }

    var positionText: String {
        guard !videos.isEmpty else { return "0 / 0" }
        return "\(selectedIndex + 1) / \(videos.count)"
    }

    var canGoOlder: Bool { selectedIndex + 1 < videos.count }
    var canGoNewer: Bool { selectedIndex > 0 }

    var currentFrame: Int { frameNumber(for: currentSeconds) }
    var totalFrames: Int { max(0, Int((durationSeconds * effectiveFrameRate).rounded(.down))) }
    var currentFrameText: String { "F\(currentFrame)" }
    var framePositionText: String { "F\(currentFrame) / F\(totalFrames)  •  \(formatFPS(effectiveFrameRate))fps" }
    var trimStartDisplayText: String { "\(formatTime(trimStartSeconds))  •  F\(frameNumber(for: trimStartSeconds))" }
    var trimEndDisplayText: String { "\(formatTime(trimEndSeconds))  •  F\(frameNumber(for: trimEndSeconds))" }
    var trimRangeDisplayText: String {
        let frames = max(0, frameNumber(for: trimEndSeconds) - frameNumber(for: trimStartSeconds))
        return "\(formatTime(max(0, trimEndSeconds - trimStartSeconds)))  •  \(frames)F"
    }
    var hasValidTrimRange: Bool { trimEndSeconds > trimStartSeconds + (0.5 / effectiveFrameRate) }

    private var effectiveFrameRate: Double {
        guard videoFrameRate.isFinite, videoFrameRate > 1 else { return 60 }
        return videoFrameRate
    }

    func connect(baseURL: URL?) {
        guard self.baseURL != baseURL else { return }
        self.baseURL = baseURL
        timer?.invalidate()
        if baseURL == nil {
            if let token = periodicToken {
                player.removeTimeObserver(token)
                periodicToken = nil
            }
            player.pause()
            videos = []
            selectedIndex = 0
            status = "撮影側を検索中…"
            return
        }
        refreshList(forceNewest: true)
        Task { await fetchRecordingState() }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshList(forceNewest: false) }
        }
    }

    func refreshList(forceNewest: Bool = false) {
        guard let baseURL else { return }
        let url = baseURL.appendingPathComponent("api/list")
        let previouslySelectedID = current?.id
        let wasOnNewest = selectedIndex == 0

        Task {
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    status = "撮影済み動画なし"
                    return
                }
                consecutiveConnectionFailures = 0
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let newVideos = try decoder.decode([VideoInfo].self, from: data)
                guard !newVideos.isEmpty else {
                    videos = []
                    selectedIndex = 0
                    player.replaceCurrentItem(with: nil)
                    status = "撮影済み動画なし"
                    return
                }

                let newestChanged = newVideos.first?.id != videos.first?.id
                videos = newVideos

                if forceNewest || (wasOnNewest && newestChanged) {
                    selectedIndex = 0
                    loadCurrent()
                } else if let previouslySelectedID,
                          let idx = newVideos.firstIndex(where: { $0.id == previouslySelectedID }) {
                    selectedIndex = idx
                    if player.currentItem == nil { loadCurrent() }
                } else {
                    selectedIndex = min(selectedIndex, max(0, newVideos.count - 1))
                    loadCurrent()
                }
            } catch {
                consecutiveConnectionFailures += 1
                status = consecutiveConnectionFailures >= 2
                    ? "P2P通信を再確立中… 再読込も使用できます"
                    : "撮影側との通信を確立中…"
            }
        }
    }

    func goOlder() {
        guard canGoOlder else { return }
        selectedIndex += 1
        loadCurrent()
    }

    func goNewer() {
        guard canGoNewer else { return }
        selectedIndex -= 1
        loadCurrent()
    }

    private func loadCurrent() {
        guard let info = current, let baseURL else { return }
        player.pause(); isPlaying = false
        currentSeconds = 0
        durationSeconds = 0
        let url = baseURL.appendingPathComponent("videos").appendingPathComponent(info.fileName)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        status = "動画を読み込み中"
        addObserver()
        Task {
            do {
                let duration = try await item.asset.load(.duration)
                durationSeconds = max(0, duration.seconds)
                await updateVideoMetadata(for: item.asset)
                trimStartSeconds = 0
                trimEndSeconds = durationSeconds
                status = "1F送り対応"
            } catch {
                status = "動画情報の取得に失敗"
            }
        }
    }

    private func updateVideoMetadata(for asset: AVAsset) async {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = CGRect(origin: .zero, size: size).applying(transform)
            let width = abs(transformed.width)
            let height = abs(transformed.height)
            if width > 0, height > 0 {
                videoAspectRatio = width / height
            }

            let nominalRate = Double(try await track.load(.nominalFrameRate))
            if nominalRate.isFinite, nominalRate > 1 {
                videoFrameRate = nominalRate
            } else {
                let minDuration = try await track.load(.minFrameDuration)
                if minDuration.seconds.isFinite, minDuration.seconds > 0 {
                    videoFrameRate = 1.0 / minDuration.seconds
                }
            }
        } catch {
            // Keep safe defaults when metadata is not available yet.
        }
    }

    private func addObserver() {
        if let token = periodicToken { player.removeTimeObserver(token) }
        periodicToken = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: nil) { [weak self] time in
            let seconds = max(0, time.seconds)
            Task { @MainActor [weak self] in
                self?.currentSeconds = seconds
            }
        }
    }

    func togglePlay() {
        configurePlaybackAudio()
        player.isMuted = false
        player.volume = 1.0
        if player.timeControlStatus == .playing {
            player.pause(); isPlaying = false
        } else {
            player.play(); isPlaying = true
        }
    }

    func step(_ frames: Int) {
        player.pause(); isPlaying = false
        guard player.currentItem != nil else { return }

        // Use exact-time seeking so the displayed frame, trim points and playback position
        // all share the same source of truth even for streamed video.
        let frameDuration = 1.0 / effectiveFrameRate
        let current = actualPlaybackSeconds()
        let targetSeconds = min(max(0, current + Double(frames) * frameDuration), durationSeconds)
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 60000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentSeconds = self.actualPlaybackSeconds()
            }
        }
    }

    func seek(seconds: Double) {
        player.pause(); isPlaying = false
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func reloadConnection() {
        player.pause()
        isPlaying = false
        status = "再読み込み中…"
        refreshList(forceNewest: true)
        Task { await fetchRecordingState() }
    }

    func setRemoteRecording(_ shouldRecord: Bool) async {
        guard let baseURL, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let path = shouldRecord ? "api/record/start" : "api/record/stop"
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        // Stop waits for AVCaptureMovieFileOutput to finish writing the file.
        request.timeoutInterval = shouldRecord ? 10 : 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                status = "録画操作に失敗しました"
                await fetchRecordingState()
                return
            }

            isRemoteRecording = shouldRecord
            if shouldRecord {
                status = "撮影側で録画開始"
                return
            }

            // The camera side responds only after the new MP4 is fully finalized.
            // Load that exact file immediately instead of waiting for list polling.
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let stop = try? decoder.decode(RecordingStopResponse.self, from: data),
               let latest = stop.latest {
                applyFinishedRecording(latest)
                status = "録画停止・最新動画を読み込み中"
            } else {
                status = "録画停止・最新動画を確認中"
                refreshList(forceNewest: true)
            }
        } catch {
            status = "録画操作に失敗: \(error.localizedDescription)"
            await fetchRecordingState()
        }
    }

    func resumeAfterForeground() {
        configurePlaybackAudio()
        player.isMuted = false
        player.volume = 1.0
        status = "撮影側の状態を復元中…"
        refreshList(forceNewest: false)
        Task { await fetchRecordingState() }
    }

    private func applyFinishedRecording(_ latest: VideoInfo) {
        var updated = videos.filter { $0.id != latest.id }
        updated.insert(latest, at: 0)
        videos = updated
        selectedIndex = 0
        loadCurrent()
    }

    func fetchRecordingState() async {
        guard let baseURL else { return }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/record/status"))
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recording = object["recording"] as? Bool else { return }
            isRemoteRecording = recording
        } catch { }
    }

    func markTrimStart() {
        let now = actualPlaybackSeconds()
        currentSeconds = now
        let minimumGap = 1.0 / effectiveFrameRate
        trimStartSeconds = min(now, max(0, trimEndSeconds - minimumGap))
    }

    func markTrimEnd() {
        let now = actualPlaybackSeconds()
        currentSeconds = now
        let minimumGap = 1.0 / effectiveFrameRate
        trimEndSeconds = max(now, trimStartSeconds + minimumGap)
        trimEndSeconds = min(trimEndSeconds, durationSeconds)
    }

    private func actualPlaybackSeconds() -> Double {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return currentSeconds }
        return min(max(0, seconds), max(0, durationSeconds))
    }

    private func frameNumber(for seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return max(0, Int((max(0, seconds) * effectiveFrameRate).rounded(.down)))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, remainder)
    }

    private func formatFPS(_ fps: Double) -> String {
        if abs(fps.rounded() - fps) < 0.05 { return String(Int(fps.rounded())) }
        return String(format: "%.2f", fps)
    }

    func exportTrimToPhotos() async {
        guard let info = current, let baseURL, !isBusy, trimEndSeconds > trimStartSeconds else { return }
        isBusy = true
        defer { isBusy = false }
        status = "切り抜き用動画を取得中…"
        do {
            let remoteURL = baseURL.appendingPathComponent("videos").appendingPathComponent(info.fileName)
            let (downloadURL, response) = try await URLSession.shared.download(from: remoteURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
                status = "動画取得に失敗"; return
            }
            let localInput = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try? FileManager.default.removeItem(at: localInput)
            try FileManager.default.moveItem(at: downloadURL, to: localInput)
            defer { try? FileManager.default.removeItem(at: localInput) }

            let asset = AVURLAsset(url: localInput)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                status = "切り抜きを開始できません"; return
            }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("maimai_trim_\(UUID().uuidString).mp4")
            try? FileManager.default.removeItem(at: output)
            exporter.outputURL = output
            exporter.outputFileType = .mp4
            exporter.timeRange = CMTimeRange(
                start: CMTime(seconds: trimStartSeconds, preferredTimescale: 60000),
                duration: CMTime(seconds: trimEndSeconds - trimStartSeconds, preferredTimescale: 60000)
            )
            await withCheckedContinuation { continuation in
                exporter.exportAsynchronously { continuation.resume() }
            }
            guard exporter.status == .completed else {
                status = "切り抜きに失敗: \(exporter.error?.localizedDescription ?? "不明なエラー")"
                return
            }
            defer { try? FileManager.default.removeItem(at: output) }
            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else { status = "写真への追加権限が必要です"; return }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: output)
            }
            status = "切り抜き動画を新規保存しました"
        } catch {
            status = "切り抜きに失敗: \(error.localizedDescription)"
        }
    }

    func deleteCurrent() async {
        guard let info = current, let baseURL, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let url = baseURL.appendingPathComponent("api/videos").appendingPathComponent(info.fileName)
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 4
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = "削除に失敗しました"
                return
            }
            status = "動画を削除しました"
            player.replaceCurrentItem(with: nil)
            refreshList(forceNewest: selectedIndex == 0)
        } catch {
            status = "削除に失敗: \(error.localizedDescription)"
        }
    }

    func saveCurrentToPhotos() async {
        guard let info = current, let baseURL, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = "保存用動画を取得中…"

        let remoteURL = baseURL.appendingPathComponent("videos").appendingPathComponent(info.fileName)
        var localURL: URL?

        do {
            let (downloadedURL, response) = try await URLSession.shared.download(from: remoteURL)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 206 else {
                status = "保存用動画の取得に失敗"
                return
            }

            // URLSession の download 一時URLは拡張子を持たない場合があるため、
            // Photos に渡す前に明示的な .mp4 ファイルへ移す。
            let destinationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MaimaiFrameLink_\(UUID().uuidString)")
                .appendingPathExtension("mp4")
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: downloadedURL, to: destinationURL)
            localURL = destinationURL

            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else {
                status = "写真への追加権限が必要です"
                return
            }

            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = info.fileName
                request.addResource(with: .video, fileURL: destinationURL, options: options)
            }

            status = "メインiPhoneの写真に保存しました"
        } catch {
            status = "保存に失敗: \(error.localizedDescription)"
        }

        if let localURL {
            try? FileManager.default.removeItem(at: localURL)
        }
    }
}
