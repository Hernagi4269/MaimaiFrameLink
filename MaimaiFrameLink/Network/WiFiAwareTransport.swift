import Foundation
import Network
import SwiftUI

#if canImport(WiFiAware)
import WiFiAware
#endif
#if canImport(DeviceDiscoveryUI)
import DeviceDiscoveryUI
#endif

/// Optional iOS 26+ Wi‑Fi Aware transport.
///
/// This transport is deliberately layered *under* the existing HTTP API. The camera
/// capture pipeline and LocalVideoServer stay untouched. On the camera side, incoming
/// Wi‑Fi Aware TCP connections are tunneled to the existing local HTTP server. On the
/// viewer side, a loopback HTTP proxy tunnels requests over Wi‑Fi Aware. If Wi‑Fi Aware
/// is unavailable or pairing fails, the existing Bonjour / Wi‑Fi / Personal Hotspot path
/// continues to work unchanged.
@MainActor
final class WiFiAwareTransport: ObservableObject {
    static let shared = WiFiAwareTransport()

    @Published private(set) var supported = false
    @Published private(set) var connected = false
    @Published private(set) var status = "Wi‑Fi Aware未使用"
    @Published private(set) var viewerBaseURL: URL?

    private var role: String = ""
    private var controller: AnyObject?

    private init() {}

    func start(role: String) {
        self.role = role
        guard #available(iOS 26.0, *) else {
            supported = false
            connected = false
            viewerBaseURL = nil
            status = "Wi‑Fi Aware非対応OS"
            return
        }

        #if canImport(WiFiAware)
        let isSupported = WACapabilities.supportedFeatures.contains(.wifiAware)
        supported = isSupported
        guard isSupported else {
            connected = false
            viewerBaseURL = nil
            status = "Wi‑Fi Aware非対応端末"
            return
        }

        let c: WiFiAware26Controller
        if let existing = controller as? WiFiAware26Controller {
            c = existing
        } else {
            c = WiFiAware26Controller()
            controller = c
            c.onState = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.connected = state.connected
                    self.status = state.status
                    self.viewerBaseURL = state.viewerBaseURL
                }
            }
        }
        c.start(role: role)
        #else
        supported = false
        connected = false
        viewerBaseURL = nil
        status = "Wi‑Fi Aware frameworkなし"
        #endif
    }

    func stop() {
        if #available(iOS 26.0, *), let c = controller as? WiFiAware26Controller {
            c.stop()
        }
        connected = false
        viewerBaseURL = nil
    }

    func reconnect() {
        stop()
        start(role: role)
    }
}

struct WiFiAwareRoleBar: View {
    let role: String
    @ObservedObject private var transport = WiFiAwareTransport.shared

    var body: some View {
        if #available(iOS 26.0, *), transport.supported {
            HStack(spacing: 8) {
                Circle()
                    .fill(transport.connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(transport.status)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                WiFiAwarePairingButton(role: role)
                Button {
                    transport.reconnect()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Wi‑Fi Aware再接続")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial)
        }
    }
}

struct WiFiAwarePairingButton: View {
    let role: String

    var body: some View {
        if #available(iOS 26.0, *) {
            WiFiAwarePairingButton26(role: role)
        }
    }
}

@available(iOS 26.0, *)
private struct WiFiAwarePairingButton26: View {
    let role: String

    var body: some View {
        #if canImport(WiFiAware) && canImport(DeviceDiscoveryUI)
        if role == "camera" {
            DevicePairingView(.wifiAware(.connecting(to: .mflinkService, from: .userSpecifiedDevices))) {
                Label("ペアリング", systemImage: "link.badge.plus")
            } fallback: {
                Label("利用不可", systemImage: "wifi.exclamationmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if role == "viewer" {
            DevicePicker(.wifiAware(.connecting(to: .userSpecifiedDevices, from: .mflinkService))) { _ in
                WiFiAwareTransport.shared.reconnect()
            } label: {
                Label("ペアリング", systemImage: "link.badge.plus")
            } fallback: {
                Label("利用不可", systemImage: "wifi.exclamationmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        #else
        EmptyView()
        #endif
    }
}

#if canImport(WiFiAware)
@available(iOS 26.0, *)
private let mflinkAwareServiceName = "_mflink._tcp"

@available(iOS 26.0, *)
private extension WAPublishableService {
    static var mflinkService: WAPublishableService {
        allServices[mflinkAwareServiceName]!
    }
}

@available(iOS 26.0, *)
private extension WASubscribableService {
    static var mflinkService: WASubscribableService {
        allServices[mflinkAwareServiceName]!
    }
}

@available(iOS 26.0, *)
private struct WiFiAwareState {
    var connected: Bool
    var status: String
    var viewerBaseURL: URL?
}

@available(iOS 26.0, *)
private final class WiFiAware26Controller: NSObject {
    var onState: ((WiFiAwareState) -> Void)?

    private var publisherTask: Task<Void, Never>?
    private var subscriberTask: Task<Void, Never>?
    private var proxy: WiFiAwareLoopbackProxy?
    private let resolver = LocalCameraServerResolver()
    private var role = ""

    func start(role: String) {
        guard self.role != role || (publisherTask == nil && subscriberTask == nil) else { return }
        stop()
        self.role = role

        if role == "camera" {
            startPublisher()
        } else if role == "viewer" {
            startSubscriber()
        }
    }

    func stop() {
        publisherTask?.cancel()
        publisherTask = nil
        subscriberTask?.cancel()
        subscriberTask = nil
        proxy?.stop()
        proxy = nil
    }

    private func emit(_ connected: Bool, _ status: String, baseURL: URL? = nil) {
        onState?(WiFiAwareState(connected: connected, status: status, viewerBaseURL: baseURL))
    }

    private func startPublisher() {
        emit(false, "Wi‑Fi Aware待受準備中…")
        publisherTask = Task { [weak self] in
            guard let self else { return }
            do {
                let localPort = try await resolver.resolvePort()
                guard !Task.isCancelled else { return }

                let listener = try NetworkListener(
                    for: .wifiAware(.connecting(to: .mflinkService, from: .allPairedDevices)),
                    using: .parameters {
                        TCP()
                    }
                    .wifiAware { $0.performanceMode = .bulk }
                    .serviceClass(.bestEffort)
                )
                .onStateUpdate { [weak self] _, state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.emit(false, "Wi‑Fi Aware待受中")
                        case .failed(let error):
                            self.emit(false, "Wi‑Fi Aware待受失敗: \(error.localizedDescription)")
                        default:
                            break
                        }
                    }
                }

                try await listener.run { [weak self] connection in
                    guard let self else { return }
                    Task { @MainActor in self.emit(true, "Wi‑Fi Aware接続中") }
                    Task.detached {
                        await WiFiAwareByteTunnel.bridgeAwareToLocalHTTP(connection, localPort: localPort)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.emit(false, "Wi‑Fi Aware待受失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startSubscriber() {
        emit(false, "Wi‑Fi Aware探索中…")
        subscriberTask = Task { [weak self] in
            guard let self else { return }
            do {
                let browser = NetworkBrowser(
                    for: .wifiAware(.connecting(to: .allPairedDevices, from: .mflinkService))
                )
                .onStateUpdate { [weak self] _, state in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .failed(let error) = state {
                            self.emit(false, "Wi‑Fi Aware探索失敗: \(error.localizedDescription)")
                        }
                    }
                }

                let endpoint = try await browser.run { endpoints in
                    if let first = endpoints.first {
                        return .finish(first)
                    }
                    return .continue
                }
                guard !Task.isCancelled else { return }

                let p = try WiFiAwareLoopbackProxy(endpoint: endpoint)
                proxy = p
                try p.start()
                guard let baseURL = p.baseURL else {
                    throw URLError(.cannotConnectToHost)
                }
                await MainActor.run { [weak self] in
                    self?.emit(true, "Wi‑Fi Aware直接接続", baseURL: baseURL)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.emit(false, "Wi‑Fi Aware接続失敗: \(error.localizedDescription)")
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private enum WiFiAwareByteTunnel {
    static func bridgeAwareToLocalHTTP(_ aware: NetworkConnection<TCP>, localPort: UInt16) async {
        guard let port = NWEndpoint.Port(rawValue: localPort) else { return }
        let local = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        local.start(queue: DispatchQueue(label: "MFL.WA.CameraLocal"))
        await bridge(aware: aware, nw: local)
    }

    static func bridgeLocalHTTPToAware(_ local: NWConnection, endpoint: WAEndpoint) async {
        let aware = NetworkConnection(
            to: endpoint,
            using: .parameters {
                TCP()
            }
            .wifiAware { $0.performanceMode = .bulk }
            .serviceClass(.bestEffort)
        )
        await bridge(aware: aware, nw: local)
    }

    private static func bridge(aware: NetworkConnection<TCP>, nw: NWConnection) async {
        async let aToB: Void = pumpAwareToNW(aware, nw)
        async let bToA: Void = pumpNWToAware(nw, aware)
        _ = await (aToB, bToA)
        nw.cancel()
    }

    private static func pumpAwareToNW(_ aware: NetworkConnection<TCP>, _ nw: NWConnection) async {
        do {
            while !Task.isCancelled {
                let data = try await aware.receive(atLeast: 1, atMost: 128 * 1024).content
                if data.isEmpty { break }
                try await sendNW(nw, data: data)
            }
        } catch { }
    }

    private static func pumpNWToAware(_ nw: NWConnection, _ aware: NetworkConnection<TCP>) async {
        do {
            while !Task.isCancelled {
                let data = try await receiveNW(nw)
                if data.isEmpty { break }
                try await aware.send(data)
            }
        } catch { }
    }

    private static func receiveNW(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func sendNW(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

@available(iOS 26.0, *)
private final class WiFiAwareLoopbackProxy {
    let endpoint: WAEndpoint
    private var listener: NWListener?
    var baseURL: URL? {
        guard let port = listener?.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port.rawValue)")
    }

    init(endpoint: WAEndpoint) throws {
        self.endpoint = endpoint
    }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let l = try NWListener(using: parameters, on: .any)
        l.newConnectionHandler = { [endpoint] connection in
            connection.start(queue: DispatchQueue(label: "MFL.WA.ViewerLoopback"))
            Task.detached {
                await WiFiAwareByteTunnel.bridgeLocalHTTPToAware(connection, endpoint: endpoint)
            }
        }
        l.start(queue: DispatchQueue(label: "MFL.WA.ProxyListener"))
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

private final class LocalCameraServerResolver: NSObject, @unchecked Sendable, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var timer: Timer?

    func resolvePort() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.continuation = continuation
                let browser = NetServiceBrowser()
                self.browser = browser
                browser.delegate = self
                browser.includesPeerToPeer = true
                browser.searchForServices(ofType: "_maimailens._tcp.", inDomain: "local.")
                self.timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                    self?.finish(.failure(URLError(.timedOut)))
                }
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name == "MaimaiCamera" else { return }
        service.delegate = self
        service.includesPeerToPeer = true
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0, let port = UInt16(exactly: sender.port) else { return }
        finish(.success(port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        if continuation != nil { finish(.failure(URLError(.cannotFindHost))) }
    }

    private func finish(_ result: Result<UInt16, Error>) {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
            self.browser?.stop()
            self.browser = nil
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }
}
#endif
