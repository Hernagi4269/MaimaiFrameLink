import SwiftUI

struct ViewerHomeView: View {
    @StateObject private var discovery = CameraDiscovery()
    @StateObject private var vm = RemoteVideoViewModel()
    @State private var sliderValue: Double = 0
    @State private var dragging = false
    @State private var showDeleteConfirmation = false
    let onChangeRole: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            Group {
                if landscape {
                    HStack(spacing: 12) {
                        playerArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        controls
                            .frame(width: min(360, geometry.size.width * 0.38))
                    }
                    .padding(12)
                } else {
                    VStack(spacing: 12) {
                        header
                        playerArea
                            .frame(maxHeight: .infinity)
                        controls
                    }
                }
            }
        }
        .onAppear { discovery.start() }
        .onDisappear {
            discovery.stop()
            vm.connect(baseURL: nil)
        }
        .onChange(of: discovery.baseURL) { _, newValue in vm.connect(baseURL: newValue) }
        .confirmationDialog("この動画を撮影側iPhoneから削除しますか？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                Task { await vm.deleteCurrent() }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(discovery.status).font(.headline)
                Text(vm.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("役割変更", action: onChangeRole).buttonStyle(.bordered)
        }
        .padding(.horizontal)
    }

    private var playerArea: some View {
        VStack(spacing: 6) {
            PlayerContainer(player: vm.player)
                .background(.black)
                .aspectRatio(vm.videoAspectRatio, contentMode: .fit)
            Text(vm.positionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    vm.goOlder()
                } label: {
                    Label("前の動画", systemImage: "chevron.left")
                }
                .disabled(!vm.canGoOlder || vm.isBusy)

                Button {
                    vm.goNewer()
                } label: {
                    Label("次の動画", systemImage: "chevron.right")
                }
                .disabled(!vm.canGoNewer || vm.isBusy)
            }
            .buttonStyle(.bordered)

            Slider(value: Binding(get: { dragging ? sliderValue : vm.currentSeconds }, set: { sliderValue = $0 }),
                   in: 0...max(0.01, vm.durationSeconds),
                   onEditingChanged: { editing in
                       dragging = editing
                       if !editing { vm.seek(seconds: sliderValue) }
                   })
            HStack {
                Text(time(vm.currentSeconds)).monospacedDigit()
                Spacer()
                Text(time(vm.durationSeconds)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                control("-10F") { vm.step(-10) }
                control("-1F") { vm.step(-1) }
                Button(action: vm.togglePlay) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 54, height: 42)
                }
                .buttonStyle(.borderedProminent)
                control("+1F") { vm.step(1) }
                control("+10F") { vm.step(10) }
            }

            HStack(spacing: 12) {
                Button {
                    Task { await vm.saveCurrentToPhotos() }
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.current == nil || vm.isBusy)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(vm.current == nil || vm.isBusy)
            }

            if vm.isBusy {
                ProgressView()
            }

            header
        }
        .padding([.horizontal, .bottom])
    }

    private func control(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).font(.headline.monospacedDigit())
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}
