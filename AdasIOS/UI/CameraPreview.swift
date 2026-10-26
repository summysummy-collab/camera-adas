// CameraPreview.swift — AVCaptureVideoPreviewLayer 包装
import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// 预览旋转角（iOS 17+ 的 videoRotationAngle 语义）：0 = 原生横屏，90 = 竖屏。
    /// App 锁定横屏，相机输出也不旋转，所以这里固定 0。
    var rotationAngle: CGFloat = 0

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        // videoOrientation 在新 SDK 已废弃/移除，改用 videoRotationAngle（iOS 17+）。
        // 旧系统上保持系统默认（预览可能旋转 90°，不影响推理链路）。
        if #available(iOS 17.0, *), let conn = v.previewLayer.connection,
           conn.isVideoRotationAngleSupported(rotationAngle) {
            conn.videoRotationAngle = rotationAngle
        }
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if #available(iOS 17.0, *), let conn = uiView.previewLayer.connection,
           conn.isVideoRotationAngleSupported(rotationAngle) {
            conn.videoRotationAngle = rotationAngle
        }
    }
}
