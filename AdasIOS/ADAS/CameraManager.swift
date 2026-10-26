// CameraManager.swift — 相机采集与工作区缓冲（1280x720 → 640x384 竖向 letterbox）
import Foundation
import AVFoundation
import CoreVideo
import Accelerate

/// 相机帧回调 + 工作区像素缓冲管理。
/// 布局：1280x720 缩放到 640x360，垂直 letterbox 上下各 12px 填进 640x384 工作区，
/// 与网页版 effW/letterbox 逻辑一致（fy 按内容宽度算，cx/cy 居中不受影响）。
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let WS_W = 640
    static let WS_H = 384
    static let CONTENT_H = 360   // 640x360 = 16:9 内容区
    static let PAD = (WS_H - CONTENT_H) / 2   // 12

    let session = AVCaptureSession()
    private let dataOutput = AVCaptureVideoDataOutput()
    private let outQueue = DispatchQueue(label: "adas.camera", qos: .userInteractive)

    /// 工作区缓冲（复用，单写单读：相机队列写 → 推理同队列用）
    private(set) var workspace: CVPixelBuffer! = nil
    /// 缩放目标：指向 workspace 第 PAD 行，高 360 —— vImageScale 只写内容区
    private var scaleDst: vImage_Buffer = vImage_Buffer()
    private var srcBuf: vImage_Buffer = vImage_Buffer()
    private var srcPixelBuffer: CVPixelBuffer? = nil

    var onFrame: ((CVPixelBuffer, Double) -> Void)?   // (workspace, ts 秒)

    func start() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            throw NSError(domain: "Camera", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法访问后置摄像头"])
        }
        session.addInput(input)
        dataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.setSampleBufferDelegate(self, queue: outQueue)
        guard session.canAddOutput(dataOutput) else {
            throw NSError(domain: "Camera", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法添加视频输出"])
        }
        session.addOutput(dataOutput)
        session.commitConfiguration()

        // 输出方向：不做旋转，直接取传感器原生横屏画面（1280x720），与网页版标定一致。
        // videoOrientation 在新 SDK 已废弃/移除，统一用 videoRotationAngle（iOS 17+）：
        // 0° 对应 landscapeRight（原生横屏），90° 才是竖屏。
        // 注意要在 commitConfiguration 之后设置，连接对象在那之后才稳定。
        if #available(iOS 17.0, *), let conn = dataOutput.connection(with: .video),
           conn.isVideoRotationAngleSupported {
            conn.videoRotationAngle = 0
        }

        allocateWorkspace()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    private func allocateWorkspace() {
        var pb: CVPixelBuffer? = nil
        CVPixelBufferCreate(nil, Self.WS_W, Self.WS_H, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &pb)
        workspace = pb!
        CVPixelBufferLockBaseAddress(workspace, [])
        let base = CVPixelBufferGetBaseAddress(workspace)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(workspace)
        // 上下 letterbox 填黑（一次即可，vImageScale 永远不碰这两条带）
        memset(base, 0, stride * Self.PAD)
        memset(base + stride * (Self.PAD + Self.CONTENT_H), 0, stride * Self.PAD)
        scaleDst.width = vImagePixelCount(Self.WS_W)
        scaleDst.height = vImagePixelCount(Self.CONTENT_H)
        scaleDst.rowBytes = stride
        scaleDst.data = UnsafeMutableRawPointer(base + stride * Self.PAD)
        CVPixelBufferUnlockBaseAddress(workspace, [])
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let src = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CACurrentMediaTime()
        // 源 → 640x360（写进工作区中间条带）
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        srcBuf.width = vImagePixelCount(CVPixelBufferGetWidth(src))
        srcBuf.height = vImagePixelCount(CVPixelBufferGetHeight(src))
        srcBuf.rowBytes = CVPixelBufferGetBytesPerRow(src)
        srcBuf.data = CVPixelBufferGetBaseAddress(src)!
        vImageScale_ARGB8888(&srcBuf, &scaleDst, nil, vImage_Flags(kvImageHighQualityResampling))
        onFrame?(workspace, ts)
    }
}
