import Foundation
import Darwin

/// Bonjour discovery with a conservative recovery policy.
///
/// Important: once a working camera has been resolved, transient Bonjour events do
/// not immediately tear the connection down. This keeps an already-working LAN /
/// Personal Hotspot connection alive instead of repeatedly rebuilding it.
@MainActor
final class CameraDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published private(set) var baseURL: URL?
    @Published private(set) var status = "撮影側を検索中…"
    @Published private(set) var connectedServiceName: String?
    @Published private(set) var controlHost: String?
    @Published private(set) var controlPort: Int?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var shouldRun = false
    private var restartWorkItem: DispatchWorkItem?
    private var watchdog: Timer?
    private var connectingService: NetService?
    private var removalCheckWorkItem: DispatchWorkItem?

    private lazy var probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    override init() {
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func start() {
        // Scene activation can call start repeatedly. Never destroy a connection
        // that is already usable just because the app returned to the foreground.
        if shouldRun, baseURL != nil { return }

        shouldRun = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        removalCheckWorkItem?.cancel()
        removalCheckWorkItem = nil

        if baseURL == nil {
            status = "撮影側を検索中…"
            beginSearch(resetServices: services.isEmpty == false)
        }

        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldRun, self.baseURL == nil else { return }
                guard self.connectingService == nil else { return }
                self.status = "撮影側を再検索中…"
                self.beginSearch(resetServices: true)
            }
        }
    }

    func stop() {
        shouldRun = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        removalCheckWorkItem?.cancel()
        removalCheckWorkItem = nil
        watchdog?.invalidate()
        watchdog = nil
        browser.stop()
        resetResolvedServices()
        baseURL = nil
        connectedServiceName = nil
        controlHost = nil
        controlPort = nil
    }

    /// Explicit user-requested reconnect. Ordinary video reloads must not call this.
    func forceReconnect() {
        guard shouldRun else { start(); return }
        removalCheckWorkItem?.cancel()
        baseURL = nil
        connectedServiceName = nil
        controlHost = nil
        controlPort = nil
        status = "通信を再接続中…"
        beginSearch(resetServices: true)
    }

    func forgetPreferredCamera() {
        forceReconnect()
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        if baseURL == nil { status = "撮影側を検索中…" }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard shouldRun else { return }
        guard !services.contains(where: { $0 === service }) else { return }

        services.append(service)
        service.includesPeerToPeer = true
        service.delegate = self

        guard baseURL == nil, connectingService == nil else { return }
        connectingService = service
        status = "撮影側を発見・接続確認中…"
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 === service }
        if connectingService === service { connectingService = nil }

        // Bonjour advertisements can disappear momentarily when iOS changes network
        // paths. Do not throw away a connection that may still be perfectly usable.
        guard connectedServiceName == service.name, baseURL != nil else { return }
        status = "接続状態を確認中…"
        scheduleCurrentConnectionVerification()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("Bonjour search failed: \(errorDict)")
        guard baseURL == nil else { return }
        status = "検索を再開中…"
        scheduleRestart()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard shouldRun else { return }
        guard sender.port > 0 else {
            connectingService = nil
            scheduleRestart()
            return
        }

        let candidates = candidateURLs(for: sender)
        guard !candidates.isEmpty else {
            connectingService = nil
            scheduleRestart()
            return
        }

        connectingService = nil
        status = "撮影側の応答を確認中…"

        Task {
            if let workingURL = await firstWorkingURL(from: candidates) {
                guard shouldRun else { return }
                baseURL = workingURL
                connectedServiceName = sender.name
                controlHost = workingURL.host
                controlPort = workingURL.port ?? sender.port
                status = "接続済み: \(sender.name)"
            } else {
                guard shouldRun, baseURL == nil else { return }
                status = "撮影側の応答待ち・再検索中…"
                scheduleRestart()
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("Bonjour resolve failed: \(errorDict)")
        if connectingService === sender { connectingService = nil }
        guard shouldRun, baseURL == nil else { return }

        if let next = services.first(where: { $0 !== sender }) {
            connectingService = next
            next.includesPeerToPeer = true
            next.delegate = self
            status = "別の撮影側へ接続確認中…"
            next.resolve(withTimeout: 10)
        } else {
            status = "撮影側を再検索中…"
            scheduleRestart()
        }
    }

    private func beginSearch(resetServices: Bool) {
        guard shouldRun else { return }
        browser.stop()
        if resetServices { resetResolvedServices() }
        browser.searchForServices(ofType: "_maimailens._tcp.", inDomain: "local.")
    }

    private func scheduleRestart() {
        guard shouldRun else { return }
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.shouldRun, self.baseURL == nil else { return }
                self.beginSearch(resetServices: true)
            }
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: item)
    }

    private func scheduleCurrentConnectionVerification() {
        removalCheckWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.shouldRun, let currentURL = self.baseURL else { return }
                if await self.isReachable(currentURL) {
                    self.status = "接続済み: \(self.connectedServiceName ?? "MaimaiCamera")"
                    return
                }

                self.baseURL = nil
                self.connectedServiceName = nil
                self.controlHost = nil
                self.controlPort = nil
                self.status = "通信切断・自動再接続中…"
                self.beginSearch(resetServices: true)
            }
        }
        removalCheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func firstWorkingURL(from candidates: [URL]) async -> URL? {
        // Give each resolved address more than one chance. Network transitions can
        // make the first request fail even though the service is already reachable.
        for attempt in 0..<2 {
            for url in candidates {
                if await isReachable(url) { return url }
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 350_000_000) }
        }
        return nil
    }

    private func isReachable(_ base: URL) async -> Bool {
        let url = base.appendingPathComponent("api/record/status")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        do {
            let (_, response) = try await probeSession.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func candidateURLs(for service: NetService) -> [URL] {
        var urls: [URL] = []

        if let host = service.hostName,
           let url = makeURL(host: host, port: service.port) {
            urls.append(url)
        }

        // mDNS host-name lookup can occasionally be the unstable part on a LAN.
        // Keep an IPv4 numeric address as a fallback when the service provides one.
        for data in service.addresses ?? [] {
            guard let host = ipv4Host(from: data), let url = makeURL(host: host, port: service.port) else { continue }
            if !urls.contains(url) { urls.append(url) }
        }

        return urls
    }

    private func makeURL(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        return components.url
    }

    private func ipv4Host(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer -> String? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let address = baseAddress.assumingMemoryBound(to: sockaddr.self)
            guard address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(data.count),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { return nil }
            return String(cString: host)
        }
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
