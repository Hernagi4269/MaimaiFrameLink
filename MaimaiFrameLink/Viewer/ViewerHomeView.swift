import SwiftUI

struct ViewerHomeView: View {
    @StateObject private var discovery = CameraDiscovery()
    @StateObject private var vm = RemoteVideoViewModel()
    @State private var sliderValue: Double = 0
    @State private var dragging = false
    let onChangeRole: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(discovery.status).font(.headline)
                    Text(vm.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("役割変更", action: onChangeRole).buttonStyle(.bordered)
            }
            .padding(.horizontal)

            PlayerContainer(player: vm.player)
                .background(.black)
                .aspectRatio(9/16, contentMode: .fit)
                .frame(maxHeight: .infinity)

            VStack(spacing: 10) {
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
                }.font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    control("-10F") { vm.step(-10) }
                    control("-1F") { vm.step(-1) }
                    Button(action: vm.togglePlay) {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2).frame(width: 54, height: 42)
                    }.buttonStyle(.borderedProminent)
                    control("+1F") { vm.step(1) }
                    control("+10F") { vm.step(10) }
                }
            }
            .padding([.horizontal, .bottom])
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: discovery.baseURL) { _, newValue in vm.connect(baseURL: newValue) }
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
