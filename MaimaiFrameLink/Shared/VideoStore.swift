import Foundation

struct VideoInfo: Codable, Identifiable, Equatable {
    let id: String
    let fileName: String
    let createdAt: Date
    let byteSize: Int64
}

struct CameraIdentity: Codable, Equatable {
    let id: String
    let serviceName: String
}

enum AppIdentity {
    private static let cameraIDKey = "MaimaiFrameLink.cameraID"

    static var cameraID: String {
        if let existing = UserDefaults.standard.string(forKey: cameraIDKey), !existing.isEmpty {
            return existing
        }
        let newValue = UUID().uuidString.lowercased()
        UserDefaults.standard.set(newValue, forKey: cameraIDKey)
        return newValue
    }

    static var serviceName: String {
        // Reliability-first: advertise one stable Bonjour name. This avoids
        // discovery filters/pairing state becoming a reason the two phones
        // cannot find each other in the field.
        "MaimaiCamera"
    }
}

final class VideoStore {
    static let shared = VideoStore()
    private let fm = FileManager.default
    private let folderURL: URL
    private let inProgressURL: URL

    private init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folderURL = docs.appendingPathComponent("Recordings", isDirectory: true)
        inProgressURL = docs.appendingPathComponent("InProgress", isDirectory: true)
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: inProgressURL, withIntermediateDirectories: true)
        cleanupStaleInProgressFiles()
    }

    /// Creates a unique recording destination that is intentionally outside the
    /// public recording list. The file only becomes visible after finalizeRecording.
    func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let suffix = UUID().uuidString.prefix(8)
        return inProgressURL.appendingPathComponent("maimai_\(formatter.string(from: Date()))_\(suffix).mp4")
    }

    /// Moves a fully-finalized movie into the public recording directory.
    /// This prevents AVPlayer/remote clients from opening a file while AVFoundation
    /// is still writing its movie header/trailer.
    func finalizeRecording(at temporaryURL: URL) -> VideoInfo? {
        guard fm.fileExists(atPath: temporaryURL.path) else { return nil }
        let destination = folderURL.appendingPathComponent(temporaryURL.lastPathComponent)
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: temporaryURL, to: destination)
            return info(for: destination)
        } catch {
            print("VideoStore finalize failed: \(error)")
            return nil
        }
    }

    func discardInProgress(at url: URL) {
        try? fm.removeItem(at: url)
    }

    func latest() -> VideoInfo? { list().first }

    func list() -> [VideoInfo] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "mp4" }.compactMap { info(for: $0, keys: keys) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func info(for url: URL, keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]) -> VideoInfo? {
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let created = values.creationDate ?? values.contentModificationDate ?? .distantPast
        return VideoInfo(
            id: url.lastPathComponent,
            fileName: url.lastPathComponent,
            createdAt: created,
            byteSize: Int64(values.fileSize ?? 0)
        )
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

    func availableCapacityBytes() -> Int64? {
        do {
            let values = try folderURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
        } catch {
            print("VideoStore capacity check failed: \(error)")
        }
        return nil
    }

    func deleteAll() {
        for item in list() {
            _ = delete(fileName: item.fileName)
        }
    }

    private func cleanupStaleInProgressFiles() {
        guard let files = try? fm.contentsOfDirectory(at: inProgressURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}

enum ProvisioningInfo {
    static var expirationDate: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        let plistEnd = end.upperBound
        let plistData = data[start.lowerBound..<plistEnd]
        guard let object = try? PropertyListSerialization.propertyList(from: Data(plistData), options: [], format: nil),
              let dict = object as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }

    static var daysRemaining: Int? {
        guard let expirationDate else { return nil }
        return Int(floor(expirationDate.timeIntervalSinceNow / 86_400))
    }
}
