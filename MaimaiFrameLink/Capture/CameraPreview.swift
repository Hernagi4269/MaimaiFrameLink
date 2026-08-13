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

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.manualOrientation = orientation
        view.applyManualRotation()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.manualOrientation = orientation
        uiView.applyManualRotation()
    }
}
