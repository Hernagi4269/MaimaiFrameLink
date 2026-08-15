import Foundation
import Network

@MainActor
final class CameraDiscovery: ObservableObject {
    @Published private(set) var baseURL: URL?
    @Published private(set) var status = "撮影側を検索中…"
    @Published private(set) var connectedServiceName: String?

    private var browser: NWBrowser?
    private let proxy = PeerHTTPProxy()
    private var selectedEndpointDescription: String?
    private var watchdog: Timer?
    private var shouldRun = false
    private let preferredServiceKey = "MaimaiFrameLink.preferredCameraService"
    private var searchStartedAt = Date()
    private var isConnecting = false

    private var preferredServiceName: String? {
        get { UserDefaults.standard.string(forKey: preferredServiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferredServiceKey) }
    }

    func start() {
        shouldRun = true
        searchStartedAt = Date()
        stopBrowserOnly()
        proxy.stop()
        baseURL = nil
        selectedEndpointDescription = nil
        connectedServiceName = nil
        status = "撮影側を検索中…"
        isConnecting = false
        createAndStartBrowser(label: "MaimaiFrameLink.browser")

        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldRun, self.baseURL == nil else { return }
                // The P2P handshake can take several seconds in a congested arcade.
                // Do not tear down an in-flight connection attempt from the watchdog.
                if self.isConnecting { return }
                let elapsed = Date().timeIntervalSince(self.searchStartedAt)
                if elapsed > 12 {
                    self.status = "撮影側を再検索中… ローカルネットワーク権限も確認してください"
                } else {
                    self.status = "P2P撮影側を再検索中…"
                }
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
        connectedServiceName = nil
        isConnecting = false
    }

    func forceReconnect() {
        guard shouldRun else { start(); return }
        searchStartedAt = Date()
        restartBrowser()
    }

    func forgetPreferredCamera() {
        preferredServiceName = nil
        forceReconnect()
    }

    private func createAndStartBrowser(label: String) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: "_maimailens._tcp", domain: "local."), using: parameters)
        browser = newBrowser

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.shouldRun else { return }
                switch state {
                case .ready:
                    self.status = self.baseURL == nil ? "P2P撮影側を検索中…" : self.status
                case .waiting(let error):
                    print("NWBrowser waiting: \(error)")
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

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results: results) }
        }
        newBrowser.start(queue: DispatchQueue(label: label))
    }

    private func serviceName(for endpoint: NWEndpoint) -> String? {
        if case let .service(name, _, _, _) = endpoint { return name }
        return nil
    }

    private func handle(results: Set<NWBrowser.Result>) {
        guard shouldRun else { return }
        let serviceResults = results.filter {
            if case .service = $0.endpoint { return true }
            return false
        }

        guard !serviceResults.isEmpty else {
            if baseURL != nil {
                baseURL = nil
                proxy.stop()
            }
            selectedEndpointDescription = nil
            connectedServiceName = nil
            status = "撮影側を検索中…"
            return
        }

        let selected: NWBrowser.Result
        if let preferredServiceName,
           let preferred = serviceResults.first(where: { serviceName(for: $0.endpoint) == preferredServiceName }) {
            selected = preferred
        } else {
            selected = serviceResults.sorted {
                (serviceName(for: $0.endpoint) ?? "") < (serviceName(for: $1.endpoint) ?? "")
            }.first!
        }

        let description = String(describing: selected.endpoint)
        if selectedEndpointDescription == description, (baseURL != nil || isConnecting) { return }
        selectedEndpointDescription = description
        baseURL = nil
        isConnecting = true
        status = "撮影側へP2P接続確認中…"

        proxy.start(remoteEndpoint: selected.endpoint) { [weak self] localURL in
            Task { @MainActor in
                guard let self, self.shouldRun else { return }
                self.isConnecting = false
                if let localURL {
                    let name = self.serviceName(for: selected.endpoint)
                    self.baseURL = localURL
                    self.connectedServiceName = name
                    if let name { self.preferredServiceName = name }
                    self.status = "接続済み（P2P実通信確認済み）"
                } else {
                    self.baseURL = nil
                    self.connectedServiceName = nil
                    self.status = "P2P実通信に失敗・再試行中…"
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
        connectedServiceName = nil
        isConnecting = false
        createAndStartBrowser(label: "MaimaiFrameLink.browser.restart")
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
