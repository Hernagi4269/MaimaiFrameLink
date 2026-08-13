import Foundation
import Network

final class LocalVideoServer: ObservableObject {
    @Published private(set) var status = "共有待機中"
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "MaimaiFrameLink.http")

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: .any)
            l.service = NWListener.Service(name: "MaimaiCamera", type: "_maimailens._tcp")
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.status = "確認側から接続可能"
                    case .failed(let error):
                        self?.status = "共有エラー: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] in self?.handle($0) }
            l.start(queue: queue)
            listener = l
        } catch {
            status = "共有開始失敗: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection, buffer: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { connection.cancel(); print(error); return }
            var merged = buffer
            if let data { merged.append(data) }
            if merged.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, requestData: merged)
            } else if merged.count < 65536 {
                self.receiveHeaders(connection, buffer: merged)
            } else {
                self.sendText(connection, code: 400, text: "Bad Request")
            }
        }
    }

    private func respond(_ connection: NWConnection, requestData: Data) {
        guard let request = String(data: requestData, encoding: .utf8) else {
            sendText(connection, code: 400, text: "Bad Request"); return
        }
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { sendText(connection, code: 400, text: "Bad Request"); return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { sendText(connection, code: 400, text: "Bad Request"); return }
        let method = String(parts[0])
        let path = String(parts[1]).removingPercentEncoding ?? String(parts[1])

        if path == "/api/latest" {
            guard let latest = VideoStore.shared.latest(),
                  let json = try? JSONEncoder.iso8601.encode(latest) else {
                sendJSON(connection, code: 404, data: Data("{}".utf8)); return
            }
            sendJSON(connection, code: 200, data: json)
            return
        }
        if path == "/api/list" {
            let data = (try? JSONEncoder.iso8601.encode(VideoStore.shared.list())) ?? Data("[]".utf8)
            sendJSON(connection, code: 200, data: data)
            return
        }
        if path.hasPrefix("/videos/") {
            let name = String(path.dropFirst("/videos/".count))
            guard let url = VideoStore.shared.url(for: name) else { sendText(connection, code: 404, text: "Not Found"); return }
            serveVideo(connection, url: url, requestLines: lines, headOnly: method == "HEAD")
            return
        }
        sendText(connection, code: 404, text: "Not Found")
    }

    private func serveVideo(_ connection: NWConnection, url: URL, requestLines: [String], headOnly: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeNum = attrs[.size] as? NSNumber else { sendText(connection, code: 500, text: "File Error"); return }
        let size = sizeNum.int64Value
        var start: Int64 = 0
        var end: Int64 = max(0, size - 1)
        var partial = false
        if let rangeLine = requestLines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = rangeLine.range(of: "bytes=") {
            let raw = rangeLine[eq.upperBound...].split(separator: ",").first.map(String.init) ?? ""
            let pair = raw.split(separator: "-", omittingEmptySubsequences: false)
            if let s = pair.first, let value = Int64(s) { start = max(0, value); partial = true }
            if pair.count > 1, !pair[1].isEmpty, let value = Int64(pair[1]) { end = min(size - 1, value) }
        }
        guard start <= end, start < size else {
            let headers = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nConnection: close\r\n\r\n"
            send(connection, data: Data(headers.utf8)); return
        }
        let length = end - start + 1
        var headers = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        headers += "Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: \(length)\r\n"
        if partial { headers += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        headers += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        if headOnly { send(connection, data: Data(headers.utf8)); return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { sendText(connection, code: 500, text: "File Error"); return }
        do { try handle.seek(toOffset: UInt64(start)) } catch { try? handle.close(); sendText(connection, code: 500, text: "Seek Error"); return }
        sendFileChunk(connection, handle: handle, remaining: length, header: Data(headers.utf8))
    }

    private func sendFileChunk(_ connection: NWConnection, handle: FileHandle, remaining: Int64, header: Data? = nil) {
        if let header {
            connection.send(content: header, completion: .contentProcessed { [weak self] error in
                if error != nil { try? handle.close(); connection.cancel(); return }
                self?.sendFileChunk(connection, handle: handle, remaining: remaining)
            })
            return
        }
        guard remaining > 0 else { try? handle.close(); connection.cancel(); return }
        let count = Int(min(256 * 1024, remaining))
        let data = try? handle.read(upToCount: count)
        guard let data, !data.isEmpty else { try? handle.close(); connection.cancel(); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            self?.sendFileChunk(connection, handle: handle, remaining: remaining - Int64(data.count))
        })
    }

    private func sendJSON(_ connection: NWConnection, code: Int, data: Data) {
        let header = "HTTP/1.1 \(code) OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        send(connection, data: Data(header.utf8) + data)
    }

    private func sendText(_ connection: NWConnection, code: Int, text: String) {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(code) Error\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        send(connection, data: Data(header.utf8) + body)
    }

    private func send(_ connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
