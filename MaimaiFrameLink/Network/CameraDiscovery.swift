import Foundation
import Network

/// Reliability-first Bonjour discovery.
///
/// Discovery itself uses NetServiceBrowser because it proved more reliable on the
/// user's two iPhones than the stricter NWBrowser-based pairing flow. Once the
/// camera service resolves, all viewer HTTP/AVPlayer traffic is routed through a
/// local PeerHTTPProxy. The proxy opens the actual camera connection with
/// Network.framework + includePeerToPeer, so remote record start/stop, video
/// streaming and ordinary LAN/Personal Hotspot operation all use the same path.
@MainActor
final class CameraDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var baseURL: URL?
    @Published private(set) var status = "撮影側を検索中…"
    @Published private(set) var connectedServiceName: String?

    private let browser = NetServiceBrowser()
    private let proxy = PeerHTTPProxy()
    private var services: [NetService] = []
    private var shouldRun = false
    private var restartWorkItem: DispatchWorkItem?
    private var watchdog: Timer?
    private var connectingService: NetService?
    private var isEstablishingTransport = false

    override init() {
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func start() {
        shouldRun = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        proxy.stop()
        resetResolvedServices()
        baseURL = nil
        connectedServiceName = nil
        isEstablishingTransport = false
        status = "撮影側を検索中…"

        browser.stop()
        browser.searchForServices(ofType: "_maimailens._tcp.", inDomain: "local.")

        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldRun, self.baseURL == nil else { return }
                // Do not destroy an in-flight Bonjour resolve / P2P connection.
                guard self.connectingService == nil, !self.isEstablishingTransport else { return }
                self.status = "撮影側を再検索中…"
                self.restartSearch()
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
        proxy.stop()
        resetResolvedServices()
        baseURL = nil
        connectedServiceName = nil
        isEstablishingTransport = false
    }

    func forceReconnect() {
        guard shouldRun else { start(); return }
        status = "撮影側を再検索中…"
        restartSearch()
    }

    /// Pairing restrictions are intentionally not used. There is normally only
    /// one camera-side device, so this simply performs a fresh discovery.
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

        // Accept the first Maimai camera discovered. No pairing/device-ID gate.
        if baseURL == nil, connectingService == nil, !isEstablishingTransport {
            connectingService = service
            status = "撮影側を発見・接続中…"
            service.resolve(withTimeout: 12)
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
            isEstablishingTransport = false
            proxy.stop()
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
        guard let hostName = sender.hostName,
              sender.port > 0,
              sender.port <= Int(UInt16.max),
              let port = NWEndpoint.Port(rawValue: UInt16(sender.port)) else {
            connectingService = nil
            scheduleRestart()
            return
        }

        connectingService = nil
        isEstablishingTransport = true
        status = "撮影側と通信を確立中…"

        // Keep discovery simple, but route actual traffic through Network.framework
        // so POST /api/record/start, /stop and AVPlayer streaming work on P2P too.
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(hostName), port: port)
        proxy.start(remoteEndpoint: endpoint) { [weak self, weak sender] localURL in
            Task { @MainActor in
                guard let self, self.shouldRun else { return }
                self.isEstablishingTransport = false

                if let localURL {
                    self.baseURL = localURL
                    self.connectedServiceName = sender?.name ?? "MaimaiCamera"
                    self.status = "接続済み"
                } else {
                    self.baseURL = nil
                    self.connectedServiceName = nil
                    self.status = "撮影側への通信に失敗・再試行中…"
                    self.scheduleRestart()
                }
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("Bonjour resolve failed: \(errorDict)")
        if connectingService === sender {
            connectingService = nil
        }
        guard shouldRun, baseURL == nil else { return }

        if let next = services.first(where: { $0 !== sender }) {
            connectingService = next
            next.includesPeerToPeer = true
            next.delegate = self
            status = "別の撮影側へ接続中…"
            next.resolve(withTimeout: 12)
        } else {
            status = "撮影側を再検索中…"
            scheduleRestart()
        }
    }

    private func restartSearch() {
        guard shouldRun else { return }
        browser.stop()
        proxy.stop()
        resetResolvedServices()
        baseURL = nil
        connectedServiceName = nil
        isEstablishingTransport = false
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
