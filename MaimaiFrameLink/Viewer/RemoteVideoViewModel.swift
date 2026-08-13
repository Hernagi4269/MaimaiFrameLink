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
