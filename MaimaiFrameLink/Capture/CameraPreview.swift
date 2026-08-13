import AVFoundation
import SwiftUI
import UIKit

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var manualOrientation: ManualCaptureOrientation = .portrait

    override func layoutSubviews() {
        super.layoutSubviews()
        applyManualRotation()
    }

    func applyManualRotation() {
        guard let connection = previewLayer.connection else { return }
        let angle = manualOrientation.rotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let orientation: ManualCaptureOrientation
    let onTapFocus: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapFocus: onTapFocus)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.manualOrientation = orientation
        view.applyManualRotation()

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.previewView = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.manualOrientation = orientation
        uiView.applyManualRotation()
        context.coordinator.onTapFocus = onTapFocus
        context.coordinator.previewView = uiView
    }

    final class Coordinator: NSObject {
        var onTapFocus: (CGPoint) -> Void
        weak var previewView: PreviewView?

        init(onTapFocus: @escaping (CGPoint) -> Void) {
            self.onTapFocus = onTapFocus
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let layerPoint = recognizer.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            onTapFocus(devicePoint)
        }
    }
}
