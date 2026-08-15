import SwiftUI

struct ViewerHomeView: View {
    @StateObject private var discovery = CameraDiscovery()
    @StateObject private var vm = RemoteVideoViewModel()
    @State private var sliderValue: Double = 0
    @State private var dragging = false
    @State private var showDeleteConfirmation = false
    @State private var showTrimEditor = false
    @Environment(\.scenePhase) private var scenePhase
    let onChangeRole: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height

            Group {
                if landscape {
                    VStack(spacing: 5) {
                        header
                        playerArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        landscapeControls
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                } else {
                    VStack(spacing: 8) {
                        header
                        playerArea
                            .frame(maxHeight: .infinity)
                        compactControls
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .onAppear { discovery.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // The viewer may have been locked during play. Recreate discovery and
                // restore the camera-side recording state every time it comes back.
                discovery.start()
                vm.resumeAfterForeground()
            }
        }
        .onDisappear {
            discovery.stop()
            vm.connect(baseURL: nil, controlHost: nil, controlPort: nil)
        }
        .onChange(of: discovery.baseURL) { _, newValue in
            vm.connect(baseURL: newValue, controlHost: discovery.controlHost, controlPort: discovery.controlPort)
        }
        .confirmationDialog("この動画を撮影側iPhoneから削除しますか？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                Task { await vm.deleteCurrent() }
            }
            Button("キャンセル", role: .cancel) {}
        }
        .sheet(isPresented: $showTrimEditor) {
            trimEditor
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(discovery.status)
                    .font(.headline)
                    .lineLimit(1)
                Text(vm.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                discovery.forceReconnect()
                vm.reloadConnection()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("再読込")

            Button("役割変更", action: onChangeRole)
                .buttonStyle(.bordered)
                .lineLimit(1)
        }
    }

    private var playerArea: some View {
        VStack(spacing: 5) {
            PlayerContainer(player: vm.player)
                .background(.black)
                .aspectRatio(vm.videoAspectRatio, contentMode: .fit)

            HStack {
                Text(vm.positionText)
                Spacer()
                Text(vm.framePositionText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var landscapeControls: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(time(vm.currentSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 54, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { dragging ? sliderValue : vm.currentSeconds },
                        set: { sliderValue = $0 }
                    ),
                    in: 0...max(0.01, vm.durationSeconds),
                    onEditingChanged: { editing in
                        dragging = editing
                        if !editing { vm.seek(seconds: sliderValue) }
                    }
                )
                Text(time(vm.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 54, alignment: .trailing)
            }

            HStack(spacing: 7) {
                Button { vm.goOlder() } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(.bordered)
                    .disabled(!vm.canGoOlder || vm.isBusy)
                    .accessibilityLabel("前の動画")

                frameButton("−10F") { vm.step(-10) }
                frameButton("−1F") { vm.step(-1) }

                Button(action: vm.togglePlay) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 42, height: 30)
                }
                .buttonStyle(.borderedProminent)

                frameButton("+1F") { vm.step(1) }
                frameButton("+10F") { vm.step(10) }

                Button { vm.goNewer() } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(.bordered)
                    .disabled(!vm.canGoNewer || vm.isBusy)
                    .accessibilityLabel("次の動画")

                Spacer(minLength: 6)

                Button {
                    Task { await vm.setRemoteRecording(!vm.isRemoteRecording) }
                } label: {
                    Label(vm.isRemoteRecording ? "停止" : "録画", systemImage: vm.isRemoteRecording ? "stop.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.isRemoteRecording ? .red : nil)
                .disabled(discovery.baseURL == nil || vm.isBusy)

                Menu {
                    Button { showTrimEditor = true } label: { Label("切り抜き", systemImage: "scissors") }
                    Button { Task { await vm.saveCurrentToPhotos() } } label: { Label("写真に保存", systemImage: "square.and.arrow.down") }
                    Button(role: .destructive) { showDeleteConfirmation = true } label: { Label("削除", systemImage: "trash") }
                    Divider()
                    Button { discovery.forgetPreferredCamera() } label: { Label("接続先を再選択", systemImage: "arrow.triangle.2.circlepath") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .disabled(vm.isBusy)
            }

            if vm.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var compactControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await vm.setRemoteRecording(!vm.isRemoteRecording) }
                } label: {
                    Label(vm.isRemoteRecording ? "停止" : "録画", systemImage: vm.isRemoteRecording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.isRemoteRecording ? .red : nil)
                .disabled(discovery.baseURL == nil || vm.isBusy)

                Button {
                    vm.goOlder()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(!vm.canGoOlder || vm.isBusy)
                .accessibilityLabel("前の動画")

                Button {
                    vm.goNewer()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(!vm.canGoNewer || vm.isBusy)
                .accessibilityLabel("次の動画")
            }

            Slider(
                value: Binding(
                    get: { dragging ? sliderValue : vm.currentSeconds },
                    set: { sliderValue = $0 }
                ),
                in: 0...max(0.01, vm.durationSeconds),
                onEditingChanged: { editing in
                    dragging = editing
                    if !editing { vm.seek(seconds: sliderValue) }
                }
            )

            HStack {
                Text(time(vm.currentSeconds))
                Spacer()
                Text(time(vm.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                frameButton("−10F") { vm.step(-10) }
                frameButton("−1F") { vm.step(-1) }

                Button(action: vm.togglePlay) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.borderedProminent)

                frameButton("+1F") { vm.step(1) }
                frameButton("+10F") { vm.step(10) }
            }

            HStack(spacing: 8) {
                Button {
                    showTrimEditor = true
                } label: {
                    Label("切り抜き", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.current == nil || vm.isBusy)

                Button {
                    Task { await vm.saveCurrentToPhotos() }
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.current == nil || vm.isBusy)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(vm.current == nil || vm.isBusy)
                .accessibilityLabel("削除")
            }

            if vm.isBusy {
                ProgressView()
            }
        }
    }

    private var trimEditor: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("現在位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(time(vm.currentSeconds))  •  \(vm.currentFrameText)")
                        .font(.title3.monospacedDigit().weight(.semibold))
                }

                HStack(spacing: 7) {
                    frameButton("−10F") { vm.step(-10) }
                    frameButton("−1F") { vm.step(-1) }
                    Button(action: vm.togglePlay) {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 44, height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    frameButton("+1F") { vm.step(1) }
                    frameButton("+10F") { vm.step(10) }
                }

                HStack(spacing: 12) {
                    trimPointCard(
                        title: "開始",
                        value: vm.trimStartDisplayText,
                        systemImage: "insertion.point.left",
                        action: vm.markTrimStart
                    )

                    trimPointCard(
                        title: "終了",
                        value: vm.trimEndDisplayText,
                        systemImage: "insertion.point.right",
                        action: vm.markTrimEnd
                    )
                }

                HStack {
                    Text("範囲")
                    Spacer()
                    Text(vm.trimRangeDisplayText)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button {
                    Task { await vm.exportTrimToPhotos() }
                } label: {
                    Label("この範囲を新規保存", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.current == nil || vm.isBusy || !vm.hasValidTrimRange)

                if vm.isBusy {
                    ProgressView()
                }

                Spacer()
            }
            .padding()
            .navigationTitle("切り抜き")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showTrimEditor = false }
                }
            }
        }
    }

    private func trimPointCard(title: String, value: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
    }

    private func frameButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 42, minHeight: 34)
        }
        .buttonStyle(.bordered)
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}
