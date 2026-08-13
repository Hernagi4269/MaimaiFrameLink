import AVFoundation
import Foundation
import Photos

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

    private var baseURL: URL?
    private var timer: Timer?
    private var periodicToken: Any?

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
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
                request.timeoutInterval = 2
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    status = "撮影済み動画なし"
                    return
                }
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
                status = "撮影側に接続中…"
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
                await updateAspectRatio(for: item.asset)
                trimStartSeconds = 0
                trimEndSeconds = durationSeconds
                status = "1F送り対応"
            } catch {
                status = "動画情報の取得に失敗"
            }
        }
    }

    private func updateAspectRatio(for asset: AVAsset) async {
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
        } catch {
            // Keep the previous/default ratio if metadata isn't available yet.
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
        if player.timeControlStatus == .playing {
            player.pause(); isPlaying = false
        } else {
            player.play(); isPlaying = true
        }
    }

    func step(_ frames: Int) {
        player.pause(); isPlaying = false
        guard let item = player.currentItem else { return }
        if frames > 0 && item.canStepForward { item.step(byCount: frames) }
        else if frames < 0 && item.canStepBackward { item.step(byCount: frames) }
        else {
            let target = CMTimeAdd(player.currentTime(), CMTime(value: CMTimeValue(frames), timescale: 60))
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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
        request.timeoutInterval = 4
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = "録画操作に失敗しました"
                return
            }
            isRemoteRecording = shouldRecord
            status = shouldRecord ? "撮影側で録画開始" : "撮影側で録画停止"
            if !shouldRecord {
                try? await Task.sleep(for: .milliseconds(700))
                refreshList(forceNewest: true)
            }
        } catch {
            status = "録画操作に失敗: \(error.localizedDescription)"
        }
    }

    func fetchRecordingState() async {
        guard let baseURL else { return }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/record/status"))
            request.timeoutInterval = 2
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recording = object["recording"] as? Bool else { return }
            isRemoteRecording = recording
        } catch { }
    }

    func markTrimStart() {
        trimStartSeconds = min(currentSeconds, max(0, trimEndSeconds - 1.0 / 60.0))
    }

    func markTrimEnd() {
        trimEndSeconds = max(currentSeconds, trimStartSeconds + 1.0 / 60.0)
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
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: remoteURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 || (response as? HTTPURLResponse)?.statusCode == 206 else {
                status = "保存用動画の取得に失敗"
                return
            }

            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else {
                status = "写真への追加権限が必要です"
                return
            }

            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: temporaryURL)
            }
            status = "メインiPhoneの写真に保存しました"
        } catch {
            status = "保存に失敗: \(error.localizedDescription)"
        }
    }
}
