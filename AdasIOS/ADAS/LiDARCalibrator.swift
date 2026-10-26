// LiDARCalibrator.swift — 用 ARKit(+LiDAR) 实测安装几何
//
// 回答"能不能用 LiDAR 把距离校准好"：
//   · LiDAR 量程只有约 5m（iPhone Pro 实际 5–6m 内可靠），**不能直接测 30m 的跟车距离**；
//   · 但测距误差 90% 来自"相装角度/高度/焦距"这三个猜测值，而这三个量在 1–5m 范围内
//     用 LiDAR 可以测得非常准 —— 把参数标定准，30m 处的单目测距自然就准了。
//
// 做法：
//   1) 俯仰角：ARWorldTrackingConfiguration 的世界 Y 轴与重力对齐，直接读相机姿态；
//   2) 安装高度：取画面下半部（前方 2–6m 路面）的 LiDAR 深度，按
//        h = R·√(1+xn²+yn²)·sin(pitch + atan(yn))
//      逐点反算，取中位数（抗个别点打到前车/井盖）；无 LiDAR 时退化为水平面检测；
//   3) 焦距：顺带读出 ARKit 内参，作为 videoFieldOfView 的交叉校验。
import Foundation
import SwiftUI
import ARKit
import SceneKit
import UIKit
import QuartzCore
import simd
import CoreVideo

final class LiDARCalibrator: NSObject, ObservableObject, ARSessionDelegate {
    @Published var status = "准备中…"
    @Published var hasLiDAR = false
    @Published var sampleCount = 0
    @Published var done = false
    @Published var failed = false
    @Published var livePitch: Double = .nan

    // 标定结果
    @Published var heightM: Double = .nan
    @Published var pitchDeg: Double = .nan
    @Published var fovDeg: Double = .nan
    @Published var spreadM: Double = .nan    // 高度样本离散度（越小越可信）

    let session = ARSession()
    private var heights: [Double] = []
    private var planes: [Double] = []
    private var frameCount = 0
    private var finished = false
    private let startAt = CACurrentMediaTime()

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        reset()
        guard ARWorldTrackingConfiguration.isSupported else {
            failed = true; status = "此机型不支持 ARKit 世界跟踪，请手动设置安装高度"
            return
        }
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravity          // 世界 Y 轴 = 重力反方向，姿态即安装角
        cfg.planeDetection = [.horizontal]
        hasLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if hasLiDAR { cfg.frameSemantics.insert(.sceneDepth) }
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        status = hasLiDAR
            ? "保持手机固定，对准前方 3–6 米路面（约 2 秒）"
            : "本机无 LiDAR，正在检测地面（需 2–5 秒，请对准前方路面）"
    }

    func stop() {
        session.pause()
    }

    func reset() {
        heights.removeAll(); planes.removeAll()
        frameCount = 0; finished = false
        done = false; failed = false
        sampleCount = 0
        heightM = .nan; pitchDeg = .nan; fovDeg = .nan; spreadM = .nan
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if finished { return }
        frameCount += 1

        // 必须是正常跟踪状态（刚启动的几帧姿态不可信）
        guard case .normal = frame.camera.trackingState else { return }
        let t = frame.camera.transform
        let depression = asin(max(-1.0, min(1.0, Double(t.columns.2.y)))) * 180.0 / Double.pi
        let pitchRad = depression * Double.pi / 180

        DispatchQueue.main.async { self.livePitch = depression }

        var gotDepth = 0
        if let depthMap = frame.sceneDepth?.depthMap {
            gotDepth = collectDepth(depthMap, frame: frame, pitchRad: pitchRad)
        }

        // 水平面兜底（无 LiDAR 或路面深度打不到时）
        for a in frame.anchors {
            guard let p = a as? ARPlaneAnchor, p.alignment == .horizontal else { continue }
            let h = Double(t.columns.3.y - p.transform.columns.3.y)
            if h > 0.4 && h < 2.5 { planes.append(h) }
        }

        // 内参 → 水平 FOV（交叉校验用）
        let intr = frame.camera.intrinsics
        let iw = Double(frame.camera.imageResolution.width)
        let fxArk = Double(intr.columns.0.x)
        let fov = fxArk > 1 && iw > 1 ? 2 * atan(iw / 2 / fxArk) * 180 / Double.pi : .nan

        let depthCount = heights.count
        DispatchQueue.main.async { self.sampleCount = depthCount }

        let elapsed = CACurrentMediaTime() - startAt
        let enough = heights.count >= 120 || (!planes.isEmpty && heights.count < 25 && planes.count >= 40)
        if (enough && gotDepth > 0) || elapsed > 7.0 {
            if !heights.isEmpty || !planes.isEmpty {
                finalize(pitch: depression, fov: fov)
            } else if elapsed > 7.0 {
                finished = true
                DispatchQueue.main.async {
                    self.failed = true
                    self.status = "没采到有效地面点：把手机略向下压一点，让前方 3–6 米路面进入画面下半部分，再试一次"
                }
            }
        }
    }

    /// 采样画面下半部的 LiDAR 深度，逐点反算"相机离地高度"。返回有效点数。
    private func collectDepth(_ depth: CVPixelBuffer, frame: ARFrame, pitchRad: Double) -> Int {
        guard heights.count < 400 else { return 0 }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return 0 }
        let dw = CVPixelBufferGetWidth(depth)
        let dh = CVPixelBufferGetHeight(depth)
        let bpr = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        let intr = frame.camera.intrinsics
        let imgW = Double(frame.camera.imageResolution.width)
        let imgH = Double(frame.camera.imageResolution.height)
        guard imgW > 1, imgH > 1, dw > 1, dh > 1 else { return 0 }
        // 深度图是相机图像的低分辨率副本 → 内参按比例缩放
        let sx = Double(dw) / imgW, sy = Double(dh) / imgH
        let fx = Double(intr.columns.0.x) * sx
        let fy = Double(intr.columns.1.y) * sy
        let cx = Double(intr.columns.2.x) * sx
        let cy = Double(intr.columns.2.y) * sy
        guard fx > 1, fy > 1 else { return 0 }

        let p = base.assumingMemoryBound(to: Float32.self)
        var got = 0
        var vs = Double(dh) * 0.50
        while vs < Double(dh) * 0.97 {
            var us = cx - Double(dw) * 0.28
            while us < cx + Double(dw) * 0.28 {
                let u = Int(us), v = Int(vs)
                if u >= 0 && u < dw && v >= 0 && v < dh {
                    let r = Double(p[v * bpr + u])
                    if r > 0.5 && r < 10.0 {
                        let xn = (Double(u) - cx) / fx
                        let yn = (Double(v) - cy) / fy
                        let ray = pitchRad + atan(yn)          // 该射线低于水平面的角度
                        if ray > 0.05 {
                            let h = r * (1 + xn * xn + yn * yn).squareRoot() * sin(ray)
                            if h > 0.45 && h < 2.2 { heights.append(h); got += 1 }
                        }
                    }
                }
                us += 6
            }
            vs += 6
        }
        return got
    }

    private func finalize(pitch: Double, fov: Double) {
        if finished { return }
        finished = true
        var h: Double = .nan
        var spread: Double = .nan
        if heights.count >= 25 {
            h = median(heights)
            let dev = heights.map { abs($0 - h) }
            spread = median(dev)
        } else if !planes.isEmpty {
            h = median(planes)
            let dev = planes.map { abs($0 - h) }
            spread = median(dev)
        }
        session.pause()
        DispatchQueue.main.async {
            guard h.isFinite, h > 0.45 else {
                self.failed = true
                self.status = "地面点不足，标定失败：请把手机略向下压，让 3–6 米路面进入画面下半部分"
                return
            }
            self.heightM = h
            self.pitchDeg = pitch
            self.fovDeg = fov
            self.spreadM = spread
            self.done = true
            self.status = String(format: "标定完成：装高 %.2fm · 俯仰 %.1f°", h, pitch)
        }
    }
}

// MARK: - AR 预览（用于对准路面）

struct ARPreviewView: UIViewRepresentable {
    let session: ARSession
    /// 必须显式持有：ARSCNView 在 setSession 时会把自己设成 session.delegate，
    /// 那样我们的 didUpdate 回调就永远收不到（标定会一直卡在"采样中"）。
    let delegate: ARSessionDelegate

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.automaticallyUpdatesLighting = false
        // 不要覆盖 scene.background —— ARSCNView 默认就渲染摄像头画面，覆盖成纯色会看不到路
        session.delegate = delegate
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        session.delegate = delegate
    }
}
