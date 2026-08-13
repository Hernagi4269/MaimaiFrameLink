import Foundation
import Network

/// Local loopback TCP proxy used by AVPlayer/URLSession.
/// The viewer talks to 127.0.0.1, while the proxy opens the real camera-side
/// connection with Network.framework and includePeerToPeer enabled.
final class PeerHTTPProxy {
    private let queue = DispatchQueue(label: "MaimaiFrameLink.peerProxy")
    private var listener: NWListener?
    private var remoteEndpoint: NWEndpoint?
    private var readyHandler: ((URL?) -> Void)?

    func start(remoteEndpoint: NWEndpoint, ready: @escaping (URL?) -> Void) {
        stop()
        self.remoteEndpoint = remoteEndpoint
        self.readyHandler = ready

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
                        guard let port = listener?.port else { return }
                        DispatchQueue.main.async {
                            self.readyHandler?(URL(string: "http://127.0.0.1:\(port.rawValue)"))
                        }
                    case .failed(let error):
                        print("PeerHTTPProxy listener failed: \(error)")
                        DispatchQueue.main.async { self.readyHandler?(nil) }
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
                DispatchQueue.main.async { self.readyHandler?(nil) }
            }
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        remoteEndpoint = nil
    }

    private func accept(_ client: NWConnection) {
        guard let endpoint = remoteEndpoint else {
            client.cancel()
            return
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let remote = NWConnection(to: endpoint, using: parameters)

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
