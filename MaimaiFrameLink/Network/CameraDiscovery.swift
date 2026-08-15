import Foundation

/// Simple Bonjour discovery tuned for reliability rather than strict pairing.
/// NetServiceBrowser/NetService both opt in to Apple's peer-to-peer path, while
/// still working on ordinary Wi-Fi and Personal Hotspot networks.
@MainActor
final class CameraDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var baseURL: URL?
    @Published private(set) var status = "撮影側を検索中…"
    @Published private(set) var connectedServiceName: String?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var shouldRun = false
    private var restartWorkItem: DispatchWorkItem?
    private var watchdog: Timer?
    private var connectingService: NetService?

    override init() {
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func start() {
        shouldRun = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        resetResolvedServices()
        baseURL = nil
        connectedServiceName = nil
        status = "撮影側を検索中…"

        browser.stop()
        browser.searchForServices(ofType: "_maimailens._tcp.", inDomain: "local.")

        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldRun, self.baseURL == nil else { return }
                // Do not continuously tear down an active resolve. If nothing is
                // resolving, restart Bonjour discovery in the simplest possible way.
                if self.connectingService == nil {
                    self.status = "撮影側を再検索中…"
                    self.restartSearch()
                }
            }
        }
    }

    func stop() {
        shouldRun = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        watchdog?.invalidate()
        watchdog = nil
        browser.stop()
        resetResolvedServices()
        baseURL = nil
        connectedServiceName = nil
    }

    func forceReconnect() {
        guard shouldRun else { start(); return }
        baseURL = nil
        connectedServiceName = nil
        status = "撮影側を再検索中…"
        restartSearch()
    }

    /// Pairing restrictions were intentionally removed. This remains for UI
    /// compatibility and simply performs a fresh discovery.
    func forgetPreferredCamera() {
        forceReconnect()
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        status = "撮影側を検索中…"
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard shouldRun else { return }
        guard !services.contains(where: { $0 === service }) else { return }

        services.append(service)
        service.includesPeerToPeer = true
        service.delegate = self

        // Reliability-first behavior: the first Maimai camera found is accepted.
        // There is no device-ID filtering or preferred-device gate.
        if baseURL == nil, connectingService == nil {
            connectingService = service
            status = "撮影側を発見・接続中…"
            service.resolve(withTimeout: 10)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 === service }
        if connectingService === service {
            connectingService = nil
        }
        if connectedServiceName == service.name {
            baseURL = nil
            connectedServiceName = nil
            status = "撮影側が切断されました・再検索中…"
            scheduleRestart()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("Bonjour search failed: \(errorDict)")
        status = "検索を再開中…"
        scheduleRestart()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard shouldRun else { return }
        guard let host = sender.hostName, sender.port > 0 else {
            connectingService = nil
            scheduleRestart()
            return
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = sender.port

        guard let url = components.url else {
            connectingService = nil
            scheduleRestart()
            return
        }

        connectingService = nil
        baseURL = url
        connectedServiceName = sender.name
        status = "接続済み: \(sender.name)"
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("Bonjour resolve failed: \(errorDict)")
        if connectingService === sender {
            connectingService = nil
        }
        guard shouldRun, baseURL == nil else { return }

        // Try another already-discovered service before restarting the browser.
        if let next = services.first(where: { $0 !== sender }) {
            connectingService = next
            next.includesPeerToPeer = true
            next.delegate = self
            status = "別の撮影側へ接続中…"
            next.resolve(withTimeout: 10)
        } else {
            status = "撮影側を再検索中…"
            scheduleRestart()
        }
    }

    private func restartSearch() {
        guard shouldRun else { return }
        browser.stop()
        resetResolvedServices()
        baseURL = nil
        connectedServiceName = nil
        browser.searchForServices(ofType: "_maimailens._tcp.", inDomain: "local.")
    }

    private func scheduleRestart() {
        guard shouldRun else { return }
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.shouldRun, self.baseURL == nil else { return }
                self.restartSearch()
            }
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func resetResolvedServices() {
        connectingService = nil
        services.forEach {
            $0.delegate = nil
            $0.stop()
        }
        services.removeAll()
    }
}
