import Foundation
import Network

@MainActor
final class CameraDiscovery: ObservableObject {
    @Published private(set) var baseURL: URL?
    @Published private(set) var status = "撮影側を検索中…"

    private var browser: NWBrowser?
    private let proxy = PeerHTTPProxy()
    private var selectedEndpointDescription: String?
    private var watchdog: Timer?
    private var shouldRun = false

    func start() {
        shouldRun = true
        stopBrowserOnly()
        proxy.stop()
        baseURL = nil
        selectedEndpointDescription = nil
        status = "撮影側を検索中…"

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_maimailens._tcp", domain: "local."), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.shouldRun else { return }
                switch state {
                case .ready:
                    self.status = self.baseURL == nil ? "P2P撮影側を検索中…" : self.status
                case .waiting:
                    self.status = "撮影側への接続待機中…"
                case .failed(let error):
                    print("NWBrowser failed: \(error)")
                    self.status = "再検索中…"
                    self.scheduleRestart()
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handle(results: results)
            }
        }
        browser.start(queue: DispatchQueue(label: "MaimaiFrameLink.browser"))

        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldRun, self.baseURL == nil else { return }
                self.status = "P2P撮影側を再検索中…"
                self.restartBrowser()
            }
        }
    }

    func stop() {
        shouldRun = false
        watchdog?.invalidate()
        watchdog = nil
        stopBrowserOnly()
        proxy.stop()
        baseURL = nil
        selectedEndpointDescription = nil
    }

    func forceReconnect() {
        guard shouldRun else { start(); return }
        restartBrowser()
    }

    private func handle(results: Set<NWBrowser.Result>) {
        guard shouldRun else { return }
        guard let result = results.first(where: {
            if case .service = $0.endpoint { return true }
            return false
        }) else {
            if baseURL != nil {
                baseURL = nil
                proxy.stop()
            }
            selectedEndpointDescription = nil
            status = "撮影側を検索中…"
            return
        }

        let description = String(describing: result.endpoint)
        if selectedEndpointDescription == description, baseURL != nil { return }
        selectedEndpointDescription = description
        baseURL = nil
        status = "撮影側へP2P接続中…"

        proxy.start(remoteEndpoint: result.endpoint) { [weak self] localURL in
            Task { @MainActor in
                guard let self, self.shouldRun else { return }
                if let localURL {
                    self.baseURL = localURL
                    self.status = "接続済み（P2P対応）"
                } else {
                    self.baseURL = nil
                    self.status = "P2P接続を再試行中…"
                    self.scheduleRestart()
                }
            }
        }
    }

    private func restartBrowser() {
        guard shouldRun else { return }
        stopBrowserOnly()
        proxy.stop()
        baseURL = nil
        selectedEndpointDescription = nil
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: "_maimailens._tcp", domain: "local."), using: parameters)
        browser = newBrowser
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed = state { self.scheduleRestart() }
            }
        }
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results: results) }
        }
        newBrowser.start(queue: DispatchQueue(label: "MaimaiFrameLink.browser.restart"))
    }

    private func scheduleRestart() {
        guard shouldRun else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.shouldRun, self.baseURL == nil else { return }
            self.restartBrowser()
        }
    }

    private func stopBrowserOnly() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }
}
