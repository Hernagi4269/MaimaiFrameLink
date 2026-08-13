import Foundation

final class CameraDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var baseURL: URL?
    @Published private(set) var status = "撮影側を検索中…"
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        services.removeAll(); baseURL = nil
        browser.searchForServices(ofType: "_maimailens._tcp.", inDomain: "local.")
    }

    func stop() { browser.stop() }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
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
        DispatchQueue.main.async { self.status = "撮影側の接続に失敗" }
    }
}
