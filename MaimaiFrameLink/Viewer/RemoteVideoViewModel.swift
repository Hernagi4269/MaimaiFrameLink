import AVFoundation
import Foundation

@MainActor
final class RemoteVideoViewModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var latest: VideoInfo?
    @Published var status = "動画待機中"
    @Published var isPlaying = false
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0

    private var baseURL: URL?
    private var timer: Timer?
    private var periodicToken: Any?

    deinit {
        timer?.invalidate()
        if let token = periodicToken { player.removeTimeObserver(token) }
    }

    func connect(baseURL: URL?) {
        guard self.baseURL != baseURL else { return }
        self.baseURL = baseURL
        timer?.invalidate()
        guard baseURL != nil else { status = "撮影側を検索中…"; return }
        refreshLatest(forceLoad: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLatest(forceLoad: false) }
        }
    }

    func refreshLatest(forceLoad: Bool = false) {
        guard let baseURL else { return }
        let url = baseURL.appendingPathComponent("api/latest")
        Task {
            do {
                var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 2
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { status = "撮影済み動画なし"; return }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let info = try decoder.decode(VideoInfo.self, from: data)
                if forceLoad || info.id != latest?.id {
                    latest = info
                    load(info)
                }
            } catch {
                status = "撮影側に接続中…"
            }
        }
    }

    private func load(_ info: VideoInfo) {
        guard let baseURL else { return }
        player.pause(); isPlaying = false
        let url = baseURL.appendingPathComponent("videos").appendingPathComponent(info.fileName)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        status = "最新動画を読み込み中"
        addObserver()
        Task {
            do {
                let duration = try await item.asset.load(.duration)
                durationSeconds = max(0, duration.seconds)
                status = "最新動画・1F送り対応"
            } catch { status = "動画情報の取得に失敗" }
        }
    }

    private func addObserver() {
        if let token = periodicToken { player.removeTimeObserver(token) }
        periodicToken = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            self?.currentSeconds = max(0, time.seconds)
        }
    }

    func togglePlay() {
        if player.timeControlStatus == .playing { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
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
}
