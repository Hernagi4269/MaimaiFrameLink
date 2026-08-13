import Foundation

final class CameraDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var baseURL: URL?
    @Published private(set) var status = "撮影側を検索中…"

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var shouldRun = false
    private var restartWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func start() {
        shouldRun = true
        restartWorkItem?.cancel()
        services.removeAll()
        baseURL = nil
        status = "撮影側を検索中…"
        browser.stop()
        browser.searchForServices(ofType: "_maimailens._tcp.", inDomain: "local.")
    }

    func stop() {
        shouldRun = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async { self.status = "撮影側を検索中…" }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !services.contains(where: { $0 === service }) else { return }
        services.append(service)
        service.includesPeerToPeer = true
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 === service }
        if baseURL != nil {
            DispatchQueue.main.async {
                self.baseURL = nil
                self.status = "再接続中…"
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        DispatchQueue.main.async { self.status = "検索を再開中…" }
        scheduleRestart()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else {
            sender.resolve(withTimeout: 5)
            return
        }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = sender.port
        DispatchQueue.main.async {
            self.baseURL = comps.url
            self.status = "接続済み: \(sender.name)"
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        DispatchQueue.main.async { self.status = "撮影側を再検索中…" }
        if shouldRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak sender] in
                sender?.resolve(withTimeout: 5)
            }
        }
    }

    private func scheduleRestart() {
        guard shouldRun else { return }
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.start() }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }
}
