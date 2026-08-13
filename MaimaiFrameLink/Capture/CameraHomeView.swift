import SwiftUI

struct CameraHomeView: View {
    @StateObject private var recorder = CameraRecorder()
    @StateObject private var server = LocalVideoServer()
    let onChangeRole: () -> Void

    var body: some View {
        ZStack {
            CameraPreview(session: recorder.session).ignoresSafeArea()
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recorder.status).font(.headline)
                        Text(server.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("役割変更", action: onChangeRole).buttonStyle(.bordered)
                }
                .padding().background(.black.opacity(0.55))
                Spacer()
                Button(action: recorder.toggleRecording) {
                    ZStack {
                        Circle().fill(.white).frame(width: 82, height: 82)
                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 40, height: 40)
                        } else {
                            Circle().fill(.red).frame(width: 66, height: 66)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .onAppear { server.start() }
        .onDisappear { server.stop() }
    }
}
