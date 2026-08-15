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
    @AppStorage("dimScreenWhileRecording") private var dimScreenWhileRecording = true
    @State private var showSettings = false
    @State private var showPreviewWhileRecording = false
    @Environment(\.scenePhase) private var scenePhase
    let onChangeRole: () -> Void

    private var selectedOrientation: ManualCaptureOrientation {
        ManualCaptureOrientation(rawValue: storedOrientation) ?? .portrait
    }

    private var selectedLayout: CaptureLayout {
        selectedOrientation.isPortrait ? .portrait : .landscape
    }

    private var isReversed: Bool { selectedOrientation.isReversed }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()

                if recorder.isRecording && dimScreenWhileRecording && !showPreviewWhileRecording {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 8) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.title2)
                        Text("省電力撮影中")
                            .font(.headline)
                        Button("プレビューを一時表示") { showPreviewWhileRecording = true }
                            .buttonStyle(.bordered)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    CameraPreview(
                        session: recorder.session,
                        orientation: selectedOrientation,
                        onTapFocus: recorder.focus(at:)
                    )
                    .ignoresSafeArea()
                }

                if landscape {
                    landscapeCameraChrome
                } else {
                    portraitCameraChrome
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            cameraSettings
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            recorder.setCaptureOrientation(selectedOrientation)
            recorder.refreshHealthState()
            server.startRecordingHandler = { completion in recorder.startRecording(completion: completion) }
            server.stopRecordingHandler = { completion in recorder.stopRecording(completion: completion) }
            server.recordingStateHandler = { recorder.isRecording }
            server.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Low Power Mode forces a short system auto-lock, so re-assert this whenever
                // the camera app returns to foreground.
                UIApplication.shared.isIdleTimerDisabled = true
                recorder.refreshHealthState()
            }
        }
        .onChange(of: recorder.isRecording) { _, recording in
            if recording {
                showPreviewWhileRecording = false
            } else {
                showPreviewWhileRecording = false
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            server.stop()
        }
    }

    private var landscapeCameraChrome: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    statusBadge
                    Spacer()
                    settingsButton
                }
                Spacer()
            }
            .padding(14)

            HStack {
                Spacer()
                VStack(spacing: 12) {
                    lensSelector(vertical: true)
                    shutterButton
                }
                .padding(.trailing, 18)
            }

            if recorder.isRecording {
                VStack {
                    recordingBadge
                        .padding(.top, 12)
                    Spacer()
                }
            }
        }
    }

    private var portraitCameraChrome: some View {
        VStack {
            HStack(alignment: .top) {
                statusBadge
                Spacer()
                settingsButton
            }
            .padding(14)

            Spacer()

            lensSelector(vertical: false)
                .padding(.bottom, 10)
            shutterButton
                .padding(.bottom, 24)
        }
    }

    private var statusBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recorder.formatLabel)
                .font(.caption.bold())
            if recorder.isRecording {
                Text("● REC")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
            } else {
                Text(server.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !recorder.lastRecordingVerification.isEmpty && !recorder.isRecording {
                Text(recorder.lastRecordingVerification)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !recorder.healthWarning.isEmpty {
                Text(recorder.healthWarning)
                    .font(.caption2.bold())
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: Circle())
        }
        .foregroundStyle(.white)
    }

    private var recordingBadge: some View {
        Text("録画中")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.red.opacity(0.9), in: Capsule())
    }

    private var shutterButton: some View {
        Button(action: recorder.toggleRecording) {
            ZStack {
                Circle().fill(.white).frame(width: 82, height: 82)
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 38, height: 38)
                } else {
                    Circle().fill(.red).frame(width: 66, height: 66)
                }
            }
            .shadow(radius: 3)
        }
        .accessibilityLabel(recorder.isRecording ? "録画停止" : "録画開始")
    }

    @ViewBuilder
    private func lensSelector(vertical: Bool) -> some View {
        if recorder.availableLenses.count > 1 {
            if vertical {
                VStack(spacing: 6) { lensButtons }
            } else {
                HStack(spacing: 6) { lensButtons }
            }
        }
    }

    @ViewBuilder
    private var lensButtons: some View {
        ForEach(recorder.availableLenses) { lens in
            Button {
                recorder.selectLens(lens)
            } label: {
                Text(lens.title)
                    .font(.caption.bold())
                    .frame(minWidth: 38, minHeight: 32)
                    .background(recorder.selectedLens == lens ? Color.yellow : Color.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(recorder.selectedLens == lens ? .black : .white)
            }
            .disabled(recorder.isRecording)
        }
    }

    private var cameraSettings: some View {
        NavigationStack {
            Form {
                Section("撮影方向") {
                    Picker("縦 / 横", selection: Binding(get: { selectedLayout }, set: { setLayout($0) })) {
                        ForEach(CaptureLayout.allCases) { layout in
                            Label(layout.title, systemImage: layout.icon).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(recorder.isRecording)

                    Toggle("180°反転", isOn: Binding(get: { isReversed }, set: { setReversed($0) }))
                        .disabled(recorder.isRecording)
                }

                Section("カメラ") {
                    HStack {
                        Text("実撮影フォーマット")
                        Spacer()
                        Text(recorder.formatLabel).foregroundStyle(.secondary)
                    }

                    if recorder.availableLenses.count > 1 {
                        Picker("レンズ", selection: Binding(get: { recorder.selectedLens }, set: { recorder.selectLens($0) })) {
                            ForEach(recorder.availableLenses) { lens in Text(lens.title).tag(lens) }
                        }
                        .disabled(recorder.isRecording)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("露出補正")
                            Spacer()
                            Text(String(format: "%+.1f EV", recorder.exposureBias)).monospacedDigit()
                        }
                        Slider(
                            value: Binding(get: { Double(recorder.exposureBias) }, set: { recorder.setExposureBias(Float($0)) }),
                            in: Double(recorder.minExposureBias)...Double(recorder.maxExposureBias),
                            step: 0.1
                        )
                    }

                    Toggle("AE/AFロック", isOn: Binding(get: { recorder.isAEAFLocked }, set: { recorder.setAEAFLocked($0) }))
                    Text("画面タップでその位置へAF/AEを合わせます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("音声") {
                    HStack {
                        Label("マイク録音", systemImage: "mic.fill")
                        Spacer()
                        Text(recorder.audioEnabled ? "48kHz AAC" : "利用不可")
                            .foregroundStyle(recorder.audioEnabled ? Color.secondary : Color.red)
                    }
                }

                Section("安定性・電力") {
                    HStack {
                        Label("低電力モード", systemImage: "battery.25")
                        Spacer()
                        Text(recorder.lowPowerMode ? "ON・撮影中スリープ防止" : "OFF")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("ストレージ", systemImage: "internaldrive")
                        Spacer()
                        Text(recorder.freeSpaceLabel).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("カメラ負荷", systemImage: "thermometer.medium")
                        Spacer()
                        Text(recorder.systemPressureLabel).foregroundStyle(.secondary)
                    }
                    Toggle("録画中は省電力表示にする", isOn: $dimScreenWhileRecording)
                    Text("録画中はカメラプレビュー描画を止めて黒い省電力画面にします。録画処理と1080p/60fpsの品質には影響しません。必要な時だけ一時的にプレビューを表示できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !recorder.healthWarning.isEmpty {
                        Label(recorder.healthWarning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Text("撮影側画面を開いている間は、低電力モードでも自動スリープを無効化します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("役割を変更", action: onChangeRole)
                        .disabled(recorder.isRecording)
                }
            }
            .navigationTitle("撮影設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showSettings = false }
                }
            }
        }
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
