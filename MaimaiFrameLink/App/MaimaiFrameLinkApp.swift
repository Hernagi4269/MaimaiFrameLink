import Photos
import SwiftUI

@main
struct MaimaiFrameLinkApp: App {
    init() {
        CameraRecordingBackupService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Camera-side safety backup. It listens to the existing recording-finished notification
/// and copies the finalized movie to Photos without changing the capture pipeline.
final class CameraRecordingBackupService {
    static let shared = CameraRecordingBackupService()

    private var observer: NSObjectProtocol?
    private let savedKey = "MaimaiFrameLink.lastCameraRollBackupID"
    private let errorKey = "MaimaiFrameLink.cameraBackupError"

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .recordingDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard UserDefaults.standard.string(forKey: "deviceRole") == "camera" else { return }
            self?.backupLatestRecording()
        }
    }

    private func backupLatestRecording() {
        guard let latest = VideoStore.shared.latest(),
              UserDefaults.standard.string(forKey: savedKey) != latest.id,
              let sourceURL = VideoStore.shared.url(for: latest.fileName) else { return }

        Task {
            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else {
                await MainActor.run {
                    UserDefaults.standard.set("写真への自動保存権限がありません", forKey: errorKey)
                }
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    options.originalFilename = latest.fileName
                    request.addResource(with: .video, fileURL: sourceURL, options: options)
                }
                await MainActor.run {
                    UserDefaults.standard.set(latest.id, forKey: savedKey)
                    UserDefaults.standard.removeObject(forKey: errorKey)
                }
            } catch {
                await MainActor.run {
                    UserDefaults.standard.set("写真への自動保存に失敗: \(error.localizedDescription)", forKey: errorKey)
                }
            }
        }
    }
}
