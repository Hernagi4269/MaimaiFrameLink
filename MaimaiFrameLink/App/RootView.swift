import SwiftUI

struct RootView: View {
    @AppStorage("deviceRole") private var deviceRole = ""

    var body: some View {
        Group {
            if deviceRole == "camera" {
                CameraHomeView(onChangeRole: { deviceRole = "" })
            } else if deviceRole == "viewer" {
                ViewerHomeView(onChangeRole: { deviceRole = "" })
            } else {
                rolePicker
            }
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
