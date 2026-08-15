import SwiftUI

struct RootView: View {
    @AppStorage("deviceRole") private var deviceRole = ""

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
