import SwiftUI

struct CameraHomeView: View {
    @StateObject private var recorder = CameraRecorder()
    @StateObject private var server = LocalVideoServer()
    @AppStorage("captureOrientation") private var storedOrientation = ManualCaptureOrientation.portrait.rawValue
    let onChangeRole: () -> Void

    private var selectedOrientation: ManualCaptureOrientation {
        ManualCaptureOrientation(rawValue: storedOrientation) ?? .portrait
    }

    var body: some View {
        ZStack {
            CameraPreview(session: recorder.session, orientation: selectedOrientation)
                .ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recorder.status).font(.headline)
                        Text(server.status).font(.caption).foregroundStyle(.secondary)
                        Text("向き固定: \(selectedOrientation.title)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                    Spacer()
                    Button("役割変更") {
                        unlockInterfaceOrientation()
                        onChangeRole()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(.black.opacity(0.55))

                orientationControls
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55))

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
        .onAppear {
            recorder.setCaptureOrientation(selectedOrientation)
            applyManualInterfaceOrientation(selectedOrientation)
            server.start()
        }
        .onDisappear {
            server.stop()
        }
    }
    private var orientationControls: some View {
        HStack(spacing: 8) {
            ForEach(ManualCaptureOrientation.allCases) { orientation in
                orientationButton(for: orientation)
            }
        }
    }

    @ViewBuilder
    private func orientationButton(for orientation: ManualCaptureOrientation) -> some View {
        if orientation == selectedOrientation {
            Button(orientation.title) {
                selectOrientation(orientation)
            }
            .buttonStyle(.borderedProminent)
            .disabled(recorder.isRecording)
        } else {
            Button(orientation.title) {
                selectOrientation(orientation)
            }
            .buttonStyle(.bordered)
            .disabled(recorder.isRecording)
        }
    }

    private func selectOrientation(_ orientation: ManualCaptureOrientation) {
        storedOrientation = orientation.rawValue
        recorder.setCaptureOrientation(orientation)
        applyManualInterfaceOrientation(orientation)
    }

}
