import Foundation

struct VideoInfo: Codable, Identifiable, Equatable {
    let id: String
    let fileName: String
    let createdAt: Date
    let byteSize: Int64
}

final class VideoStore {
    static let shared = VideoStore()
    private let fm = FileManager.default
    private let folderURL: URL

    private init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folderURL = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return folderURL.appendingPathComponent("maimai_\(formatter.string(from: Date())).mp4")
    }

    func latest() -> VideoInfo? { list().first }

    func list() -> [VideoInfo] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "mp4" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return VideoInfo(id: url.lastPathComponent,
                             fileName: url.lastPathComponent,
                             createdAt: values.creationDate ?? .distantPast,
                             byteSize: Int64(values.fileSize ?? 0))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func url(for fileName: String) -> URL? {
        let safe = URL(fileURLWithPath: fileName).lastPathComponent
        let url = folderURL.appendingPathComponent(safe)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func delete(fileName: String) -> Bool {
        guard let url = url(for: fileName) else { return false }
        do {
            try fm.removeItem(at: url)
            return true
        } catch {
            print("VideoStore delete failed: \(error)")
            return false
        }
    }

    func deleteAll() {
        for item in list() {
            _ = delete(fileName: item.fileName)
        }
    }
}
