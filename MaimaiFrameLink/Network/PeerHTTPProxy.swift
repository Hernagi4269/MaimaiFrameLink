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
                        guard let localURL = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
                            self.finishStartup(nil)
                            self.stopInternal()
                            return
                        }
                        // Validate the exact path the viewer will use: URLSession/AVPlayer
                        // -> loopback listener -> peer-to-peer NWConnection -> camera server.
                        // A direct probe of the remote endpoint alone can report success even
                        // when the local proxy path is not yet usable.
                        self.probeThroughProxy(localURL) { success in
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

    private func probeThroughProxy(_ localURL: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: localURL.appendingPathComponent("api/health"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)

        session.dataTask(with: request) { data, response, error in
            defer { session.invalidateAndCancel() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["ok"] as? Bool) == true else {
                completion(false)
                return
            }
            completion(true)
        }.resume()
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
