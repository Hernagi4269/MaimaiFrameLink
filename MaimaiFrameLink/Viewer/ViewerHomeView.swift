import SwiftUI

struct ViewerHomeView: View {
    @StateObject private var discovery = CameraDiscovery()
    @StateObject private var vm = RemoteVideoViewModel()
    @State private var showDeleteConfirmation = false
    @State private var showTrimEditor = false
    @State private var showFullscreenViewer = false
    @Environment(\.scenePhase) private var scenePhase
    let onChangeRole: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: landscape ? 5 : 8) {
                header
                playerArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls(compact: landscape)
            }
            .padding(.horizontal, landscape ? 10 : 12)
            .padding(.bottom, 8)
        }
        .onAppear { discovery.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
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
            Button("削除", role: .destructive) { Task { await vm.deleteCurrent() } }
            Button("キャンセル", role: .cancel) {}
        }
        .sheet(isPresented: $showTrimEditor) {
            trimEditor.presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showFullscreenViewer) {
            FullScreenVideoView(vm: vm, isPresented: $showFullscreenViewer)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(discovery.status).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if vm.isBuffering { ProgressView().controlSize(.mini) }
                    Text(vm.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                discovery.forceReconnect(); vm.reloadConnection()
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .accessibilityLabel("再読込")
            Button("役割変更", action: onChangeRole)
                .buttonStyle(.bordered)
                .lineLimit(1)
        }
    }

    private var playerArea: some View {
        ZStack(alignment: .topTrailing) {
            PlayerContainer(player: vm.player)
                .background(.black)
                .aspectRatio(vm.videoAspectRatio, contentMode: .fit)
                .contentShape(Rectangle())
                .gesture(videoSwipeGesture)

            Button { showFullscreenViewer = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.headline)
                    .padding(10)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .disabled(vm.current == nil)
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text(vm.positionText)
                Spacer()
                Text(vm.framePositionText)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55))
        }
    }

    private var videoSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                if value.translation.width < -70 { vm.goOlder() }
                if value.translation.width > 70 { vm.goNewer() }
            }
    }

    private func controls(compact: Bool) -> some View {
        VStack(spacing: compact ? 5 : 8) {
            PrecisionScrubber(
                position: vm.currentSeconds,
                duration: vm.durationSeconds,
                onSeek: vm.seek(seconds:)
            )

            HStack {
                Text(time(vm.currentSeconds))
                Spacer()
                Text(time(vm.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                transportButton(systemImage: "gobackward.5", accessibility: "5秒戻る") { vm.skip(seconds: -5) }
                frameButton("−1F") { vm.step(-1) }
                Button(action: vm.togglePlay) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 34)
                }
                .buttonStyle(.borderedProminent)
                frameButton("+1F") { vm.step(1) }
                transportButton(systemImage: "goforward.5", accessibility: "5秒進む") { vm.skip(seconds: 5) }
            }

            HStack(spacing: 8) {
                Button {
                    vm.goNewer()
                } label: {
                    Label("新しい", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(!vm.canGoNewer || vm.isBusy)

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
                    Label("古い", systemImage: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(!vm.canGoOlder || vm.isBusy)

                Menu {
                    Button { showTrimEditor = true } label: { Label("切り抜き", systemImage: "scissors") }
                    Button { Task { await vm.saveCurrentToPhotos() } } label: { Label("写真に保存", systemImage: "square.and.arrow.down") }
                    Button(role: .destructive) { showDeleteConfirmation = true } label: { Label("削除", systemImage: "trash") }
                    Divider()
                    Button { discovery.forceReconnect(); vm.reloadConnection() } label: { Label("再接続・再読込", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .buttonStyle(.bordered)
                .disabled(vm.isBusy)
            }
            if vm.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var trimEditor: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("現在位置").font(.caption).foregroundStyle(.secondary)
                    Text("\(time(vm.currentSeconds))  •  \(vm.currentFrameText)")
                        .font(.title3.monospacedDigit().weight(.semibold))
                }

                HStack(spacing: 7) {
                    transportButton(systemImage: "gobackward.5", accessibility: "5秒戻る") { vm.skip(seconds: -5) }
                    frameButton("−1F") { vm.step(-1) }
                    Button(action: vm.togglePlay) {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    frameButton("+1F") { vm.step(1) }
                    transportButton(systemImage: "goforward.5", accessibility: "5秒進む") { vm.skip(seconds: 5) }
                }

                HStack(spacing: 12) {
                    trimPointCard(title: "開始", value: vm.trimStartDisplayText, systemImage: "insertion.point.left", action: vm.markTrimStart)
                    trimPointCard(title: "終了", value: vm.trimEndDisplayText, systemImage: "insertion.point.right", action: vm.markTrimEnd)
                }

                HStack {
                    Text("範囲"); Spacer(); Text(vm.trimRangeDisplayText).monospacedDigit()
                }
                .font(.subheadline).foregroundStyle(.secondary)

                Button { Task { await vm.exportTrimToPhotos() } } label: {
                    Label("この範囲を新規保存", systemImage: "scissors").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.current == nil || vm.isBusy || !vm.hasValidTrimRange)

                if vm.isBusy { ProgressView() }
                Spacer()
            }
            .padding()
            .navigationTitle("切り抜き")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { showTrimEditor = false } } }
        }
    }

    private func trimPointCard(title: String, value: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Label(title, systemImage: systemImage).font(.headline)
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
    }

    private func frameButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.monospacedDigit().weight(.semibold)).frame(minWidth: 42, minHeight: 34)
        }
        .buttonStyle(.bordered)
    }

    private func transportButton(systemImage: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemImage).frame(minWidth: 42, minHeight: 34) }
            .buttonStyle(.bordered)
            .accessibilityLabel(accessibility)
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}

private struct PrecisionScrubber: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var preview: Double = 0
    @State private var startPosition: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let shown = isDragging ? preview : position
            let progress = duration > 0 ? min(max(shown / duration, 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.25)).frame(height: 5)
                Capsule().fill(.primary).frame(width: width * progress, height: 5)
                Circle().fill(.primary).frame(width: 15, height: 15).offset(x: max(0, min(width - 15, width * progress - 7.5)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if isDragging {
                    Text(format(preview))
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .offset(y: -22)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            startPosition = position
                            preview = position
                        }
                        let vertical = abs(value.location.y - geo.size.height / 2)
                        let sensitivity: Double = vertical > 42 ? 0.12 : (vertical > 24 ? 0.35 : 1.0)
                        if abs(value.translation.width) < 3 {
                            preview = min(max(0, Double(value.location.x / width) * duration), duration)
                        } else {
                            let delta = Double(value.translation.width / width) * duration * sensitivity
                            preview = min(max(0, startPosition + delta), duration)
                        }
                    }
                    .onEnded { _ in
                        let target = preview
                        isDragging = false
                        onSeek(target)
                    }
            )
        }
        .frame(height: 28)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}

private struct FullScreenVideoView: View {
    @ObservedObject var vm: RemoteVideoViewModel
    @Binding var isPresented: Bool
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerContainer(player: vm.player)
                .aspectRatio(vm.videoAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .gesture(
                    DragGesture(minimumDistance: 55).onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                        if value.translation.width < -80 { vm.goOlder() }
                        if value.translation.width > 80 { vm.goNewer() }
                        showControlsTemporarily()
                    }
                )

            if controlsVisible {
                VStack {
                    HStack {
                        Button { isPresented = false } label: {
                            Image(systemName: "xmark").font(.headline).padding(10).background(.black.opacity(0.6), in: Circle())
                        }
                        Spacer()
                        Text("\(vm.positionText)   \(vm.framePositionText)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                    Spacer()
                    VStack(spacing: 10) {
                        PrecisionScrubber(position: vm.currentSeconds, duration: vm.durationSeconds, onSeek: vm.seek(seconds:))
                        HStack(spacing: 16) {
                            overlayButton("gobackward.5", label: "5秒戻る") { vm.skip(seconds: -5) }
                            textOverlayButton("−1F") { vm.step(-1) }
                            Button(action: vm.togglePlay) {
                                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2).frame(width: 54, height: 44)
                            }.buttonStyle(.borderedProminent)
                            textOverlayButton("+1F") { vm.step(1) }
                            overlayButton("goforward.5", label: "5秒進む") { vm.skip(seconds: 5) }
                        }
                    }
                    .padding(12)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
                .transition(.opacity)
            }

            if vm.isBuffering {
                ProgressView("読み込み中…")
                    .padding(12)
                    .background(.black.opacity(0.65), in: Capsule())
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear { showControlsTemporarily() }
        .onDisappear { hideTask?.cancel() }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.15)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func showControlsTemporarily() {
        withAnimation(.easeInOut(duration: 0.15)) { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
            }
        }
    }

    private func overlayButton(_ image: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); showControlsTemporarily() }) { Image(systemName: image).frame(width: 44, height: 40) }
            .buttonStyle(.bordered)
            .accessibilityLabel(label)
    }

    private func textOverlayButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); showControlsTemporarily() }) {
            Text(title).font(.subheadline.monospacedDigit().bold()).frame(width: 44, height: 40)
        }
        .buttonStyle(.bordered)
    }
}
