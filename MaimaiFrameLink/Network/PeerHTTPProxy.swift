import Foundation
import Network

/// Local loopback TCP proxy used by AVPlayer/URLSession.
/// The viewer talks to 127.0.0.1, while the proxy opens the real camera-side
/// connection with Network.framework and includePeerToPeer enabled.
///
/// Important: `ready` is called only after the proxy listener is ready AND an
/// actual /api/health request succeeds against the camera endpoint. This avoids
/// displaying a false "connected" state when only the local loopback listener
/// is alive.
final class PeerHTTPProxy {
    private let queue = DispatchQueue(label: "MaimaiFrameLink.peerProxy")
    private var listener: NWListener?
    private var remoteEndpoint: NWEndpoint?
    private var readyHandler: ((URL?) -> Void)?
    private var didFinishStartup = false

    func start(remoteEndpoint: NWEndpoint, ready: @escaping (URL?) -> Void) {
        stop()
        self.remoteEndpoint = remoteEndpoint
        self.readyHandler = ready
        self.didFinishStartup = false

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                listener.newConnectionHandler = { [weak self] client in
                    self?.accept(client)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port else {
                            self.finishStartup(nil)
                            return
                        }
                        let localURL = URL(string: "http://127.0.0.1:\(port.rawValue)")
                        self.probeRemote(remoteEndpoint) { success in
                            self.queue.async {
                                self.finishStartup(success ? localURL : nil)
                                if !success { self.stopInternal() }
                            }
                        }
                    case .failed(let error):
                        print("PeerHTTPProxy listener failed: \(error)")
                        self.finishStartup(nil)
                        self.stopInternal()
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                print("PeerHTTPProxy start failed: \(error)")
                self.finishStartup(nil)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopInternal() }
    }

    private func stopInternal() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        remoteEndpoint = nil
    }

    private func finishStartup(_ url: URL?) {
        guard !didFinishStartup else { return }
        didFinishStartup = true
        let handler = readyHandler
        readyHandler = nil
        DispatchQueue.main.async { handler?(url) }
    }

    private func peerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    private func probeRemote(_ endpoint: NWEndpoint, completion: @escaping (Bool) -> Void) {
        let remote = NWConnection(to: endpoint, using: peerParameters())
        var completed = false

        func finish(_ success: Bool) {
            guard !completed else { return }
            completed = true
            remote.cancel()
            completion(success)
        }

        let timeout = DispatchWorkItem { finish(false) }
        queue.asyncAfter(deadline: .now() + 3.0, execute: timeout)

        remote.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let request = "GET /api/health HTTP/1.1\r\nHost: camera\r\nConnection: close\r\n\r\n"
                remote.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if error != nil {
                        timeout.cancel()
                        finish(false)
                        return
                    }
                    self.receiveProbeResponse(remote, buffer: Data()) { success in
                        timeout.cancel()
                        finish(success)
                    }
                })
            case .failed(let error):
                print("PeerHTTPProxy probe failed: \(error)")
                timeout.cancel()
                finish(false)
            case .cancelled:
                break
            default:
                break
            }
        }
        remote.start(queue: queue)
    }

    private func receiveProbeResponse(_ connection: NWConnection, buffer: Data, completion: @escaping (Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { completion(false); return }
            var merged = buffer
            if let data { merged.append(data) }

            if let headerEnd = merged.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = merged[..<headerEnd.upperBound]
                let header = String(decoding: headerData, as: UTF8.self)
                completion(header.hasPrefix("HTTP/1.1 200"))
                return
            }

            if error != nil || isComplete || merged.count >= 8192 {
                completion(false)
                return
            }
            self.receiveProbeResponse(connection, buffer: merged, completion: completion)
        }
    }

    private func accept(_ client: NWConnection) {
        guard let endpoint = remoteEndpoint else {
            client.cancel()
            return
        }

        let remote = NWConnection(to: endpoint, using: peerParameters())

        client.stateUpdateHandler = { state in
            if case .failed = state { remote.cancel() }
            if case .cancelled = state { remote.cancel() }
        }
        remote.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.pipe(from: client, to: remote, peer: client)
                self?.pipe(from: remote, to: client, peer: remote)
            case .failed(let error):
                print("PeerHTTPProxy remote failed: \(error)")
                client.cancel()
                remote.cancel()
            case .cancelled:
                client.cancel()
            default:
                break
            }
        }

        client.start(queue: queue)
        remote.start(queue: queue)
    }

    private func pipe(from source: NWConnection, to destination: NWConnection, peer: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        source.cancel(); destination.cancel(); peer.cancel()
                        return
                    }
                    if isComplete {
                        source.cancel(); destination.cancel(); peer.cancel()
                    } else {
                        self.pipe(from: source, to: destination, peer: peer)
                    }
                })
            } else if isComplete || error != nil {
                source.cancel(); destination.cancel(); peer.cancel()
            } else {
                self.pipe(from: source, to: destination, peer: peer)
            }
        }
    }
}
