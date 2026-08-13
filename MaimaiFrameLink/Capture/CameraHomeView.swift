import SwiftUI

enum CaptureLayout: String, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }
    var title: String { self == .portrait ? "縦" : "横" }
    var icon: String { self == .portrait ? "rectangle.portrait" : "rectangle.landscape" }
}

struct CameraHomeView: View {
    @StateObject private var recorder = CameraRecorder()
    @StateObject private var server = LocalVideoServer()
    @AppStorage("captureOrientation") private var storedOrientation = ManualCaptureOrientation.portrait.rawValue
    let onChangeRole: () -> Void

    private var selectedOrientation: ManualCaptureOrientation {
        ManualCaptureOrientation(rawValue: storedOrientation) ?? .portrait
    }

    private var selectedLayout: CaptureLayout {
        selectedOrientation.isPortrait ? .portrait : .landscape
    }

    private var isReversed: Bool {
        selectedOrientation.isReversed
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: recorder.session, orientation: selectedOrientation)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomControls
            }
        }
        .onAppear {
            recorder.setCaptureOrientation(selectedOrientation)
            server.start()
        }
        .onDisappear {
            server.stop()
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recorder.status)
                    .font(.headline)
                Text(server.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("役割変更") {
                onChangeRole()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.52))
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            orientationPanel

            Button(action: recorder.toggleRecording) {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 82, height: 82)
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.red)
                            .frame(width: 40, height: 40)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 66, height: 66)
                    }
                }
            }
            .accessibilityLabel(recorder.isRecording ? "録画停止" : "録画開始")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background(.black.opacity(0.52))
    }

    private var orientationPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                orientationModeButton(.portrait)
                orientationModeButton(.landscape)

                Divider()
                    .frame(height: 28)

                reverseButton
            }

            Text(orientationDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var reverseButton: some View {
        if isReversed {
            Button {
                setReversed(false)
            } label: {
                Label("180°", systemImage: "rotate.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(recorder.isRecording)
        } else {
            Button {
                setReversed(true)
            } label: {
                Label("180°", systemImage: "rotate.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(recorder.isRecording)
        }
    }

    @ViewBuilder
    private func orientationModeButton(_ layout: CaptureLayout) -> some View {
        if layout == selectedLayout {
            Button {
                setLayout(layout)
            } label: {
                Label(layout.title, systemImage: layout.icon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(recorder.isRecording)
        } else {
            Button {
                setLayout(layout)
            } label: {
                Label(layout.title, systemImage: layout.icon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(recorder.isRecording)
        }
    }

    private var orientationDescription: String {
        let base = selectedLayout == .portrait ? "縦撮影" : "横撮影"
        return isReversed ? "\(base)・180°反転" : "\(base)・標準方向"
    }

    private func setLayout(_ layout: CaptureLayout) {
        let orientation: ManualCaptureOrientation
        switch (layout, isReversed) {
        case (.portrait, false): orientation = .portrait
        case (.portrait, true): orientation = .portraitUpsideDown
        case (.landscape, false): orientation = .landscapeLeft
        case (.landscape, true): orientation = .landscapeRight
        }
        applyCaptureOrientation(orientation)
    }

    private func setReversed(_ reversed: Bool) {
        let orientation: ManualCaptureOrientation
        switch (selectedLayout, reversed) {
        case (.portrait, false): orientation = .portrait
        case (.portrait, true): orientation = .portraitUpsideDown
        case (.landscape, false): orientation = .landscapeLeft
        case (.landscape, true): orientation = .landscapeRight
        }
        applyCaptureOrientation(orientation)
    }

    private func applyCaptureOrientation(_ orientation: ManualCaptureOrientation) {
        storedOrientation = orientation.rawValue
        recorder.setCaptureOrientation(orientation)
    }
}
