import SwiftUI
import UIKit

struct RootView: View {
    @AppStorage("deviceRole") private var deviceRole = ""
    @AppStorage("MaimaiFrameLink.cameraBackupError") private var cameraBackupError = ""

    var body: some View {
        VStack(spacing: 0) {
            if let days = ProvisioningInfo.daysRemaining, days <= 2 {
                Text(days < 0 ? "署名期限が切れています。Sideloadlyで再署名してください" : "署名期限まであと \(max(0, days + 1)) 日です")
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.yellow)
            }
            if deviceRole == "camera", !cameraBackupError.isEmpty {
                Text(cameraBackupError)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.red)
            }
            Group {
                if deviceRole == "camera" {
                    CameraHomeView(onChangeRole: { deviceRole = "" })
                } else if deviceRole == "viewer" {
                    ViewerHomeView(onChangeRole: { deviceRole = "" })
                } else {
                    rolePicker
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .onAppear { updateIdleTimer() }
        .onChange(of: deviceRole) { _, _ in updateIdleTimer() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func updateIdleTimer() {
        // Low Power Mode forces a short Auto-Lock interval, so camera role explicitly
        // disables the idle timer. Viewer role remains free to lock normally.
        UIApplication.shared.isIdleTimerDisabled = (deviceRole == "camera")
    }

    private var rolePicker: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 64))
            Text("Maimai Frame Link")
                .font(.largeTitle.bold())
            Text("同じアプリを2台のiPhoneに入れ、役割だけ分けます。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("このiPhoneを撮影側にする") { deviceRole = "camera" }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("このiPhoneを確認側にする") { deviceRole = "viewer" }
                .buttonStyle(.bordered)
                .controlSize(.large)
            Spacer()
        }
        .padding(24)
    }
}
