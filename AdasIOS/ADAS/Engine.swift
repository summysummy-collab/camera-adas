// Engine.swift — 主循环编排：检测 → 跟踪 → 灯 → 规则 → 告警
import Foundation
import CoreVideo
import CoreML
import QuartzCore
import UIKit

/// 主循环编排。注意：本类**不加 @MainActor** —— processFrame 跑在相机队列上，
/// 只有对外发布状态时才切回主线程（见 processFrame 末尾的 DispatchQueue.main.async）。
final class Engine: ObservableObject {
    @Published var scene = SceneState()
    @Published var fps: Double = 0
    @Published var inferMs: Double = 0
    @Published var gpsOk = false
    @Published var gpsSpeed: Double = 0
    @Published var gpsSrc = "none"
    @Published var running = false
    @Published var debugLine = ""
    /// 当前生效的安装几何（标高/俯仰/焦距/比例），用于界面确认
    @Published var geomLine = ""
    /// v1.3 周边安全态势快照（每帧更新，态势面板只读这个）
    @Published var world = SafetyWorld.empty
    /// v1.4 当前该说的那一句（规则 + 安全层仲裁后的结果），HUD 与语音共用
    @Published var liveAlert: Alert? = nil
    /// 触觉节流状态（只在主线程读写）
    private var lastHapticAt: Double = -100
    private var lastHapticLevel: AlertLevel = .info

    let camera = CameraManager()
    let speaker = AlertSpeaker()
    let location = LocationFeed()
    private let motion = MotionPitch()
    private var mount = MountConfig.load()
    private var detector: Detector?
    private var tracker = IoUTracker()
    private var lights = LightTracker()
    private var rules: RulesEngine?
    private let assessor = SafetyAssessor()
    private var calib = Calib()
    private var lastFrameTs: Double = 0
    private var fpsEma: Double = 0
    /// 重力实时俯仰（由 MotionPitch 在后台队列写入，processFrame 读取）
    private var livePitch: Double = .nan
    private let pitchLock = NSLock()
    private var lastAppliedPitch: Double = .nan
    /// 当前帧的像素视图（尾灯判据复用，避免同一缓冲重复加锁）
    private var curFrame: FrameBuf? = nil

    func start() throws {
        if detector == nil {
            let det = try Detector(conf: 0.35)
            detector = det
            inferMs = det.lastMs
        }
        // 先启动相机：只有 activeFormat 定了，videoFieldOfView 才是真实视场角
        try camera.start()
        // 再用"真实 FOV + 标定安装角"组装 calib
        applyMount()
        rules = RulesEngine(calib: calib)
        rules?.th.distScale = mount.distScale
        rules?.tailRatioProvider = { [weak self] box in
            guard let self = self, let fb = self.curFrame else { return nil }
            return redRatio(fb, box)
        }
        camera.onFrame = { [weak self] ws, ts in
            self?.processFrame(ws, ts: ts)
        }
        location.request()
        if mount.pitchAuto {
            motion.start()
            motion.onUpdate = { [weak self] p in
                guard let self = self else { return }
                self.pitchLock.lock(); self.livePitch = p; self.pitchLock.unlock()
            }
        }
        running = true
    }

    /// 用持久化的标定值 + 相机真实 FOV 组装几何参数。
    /// 关键：Calib 是 struct，不 fit 的话 fx/fy 还是初值 1，所有基于焦距的计算都会得出垃圾值。
    private func applyMount() {
        mount = MountConfig.load()
        let fov = mount.fovDeg > 1 ? mount.fovDeg : camera.horizontalFOVDeg
        calib.fov = fov
        calib.height = mount.heightM
        let p = motion.value.isFinite ? motion.value : mount.pitchDeg
        calib.pitch = mount.pitchAuto ? p : mount.pitchDeg
        // 俯仰是自动测的 → 置信度高，地面法权重可以给足；纯手工猜 → 大幅降权
        calib.pitchSigmaDeg = mount.pitchAuto ? 0.6 : 2.0
        calib.refit(Double(CameraManager.WS_W), Double(CameraManager.WS_H))
        rules?.calib = calib
        rules?.th.distScale = mount.distScale
        assessor.th.distScale = mount.distScale
    }

    /// 每帧把重力测得的俯仰角同步进来（变化大于 0.05° 才重算，避免无谓抖动）
    private func syncPitch() {
        guard mount.pitchAuto else { return }
        pitchLock.lock()
        let p = livePitch
        pitchLock.unlock()
        guard p.isFinite else { return }
        if lastAppliedPitch.isFinite && abs(p - lastAppliedPitch) < 0.05 { return }
        lastAppliedPitch = p
        calib.pitch = p
        calib.refit(Double(CameraManager.WS_W), Double(CameraManager.WS_H))
        rules?.calib = calib
    }

    func stop() {
        camera.stop()
        camera.onFrame = nil
        motion.stop()
        location.stop()
        running = false
    }

    /// 相机队列上执行（非主线程）
    private func processFrame(_ ws: CVPixelBuffer, ts: Double) {
        guard let detector = detector, let rules = rules else { return }

        // 重力俯仰 → 几何参数（安装姿态变化时自动跟随）
        syncPitch()

        // fps
        if lastFrameTs > 0 {
            let f = 1.0 / max(1e-3, ts - lastFrameTs)
            fpsEma = fpsEma == 0 ? f : fpsEma + (f - fpsEma) * 0.1
        }
        lastFrameTs = ts

        let dets = (try? detector.detect(ws)) ?? []
        let tracks = tracker.update(dets)

        var fb: FrameBuf? = FrameBuf(ws)
        defer {
            if let f = fb { f.finished(ws) }
            curFrame = nil
        }
        curFrame = fb

        // 信号灯
        let tl = tracks.filter { $0.name == "traffic light" && $0.misses == 0 }
        var lightReports: [LightReport] = []
        if let f = fb {
            lightReports = lights.update(tl, f, calib, ts)
        }

        let ctx = SceneCtx(w: Double(CameraManager.WS_W), h: Double(CameraManager.WS_H),
                           ego: location.ego, lights: lightReports)
        let st = rules.update(tracks, ts, ctx)
        // v1.3：同一批跟踪结果再走一遍"世界模型 + 风险评估"（与告警规则并行，互不影响）
        let wd = assessor.update(tracks, calib, ego: location.ego, ts: ts)

        let fpsNow = fpsEma
        let dbg = String(
            format: "det %d · tl %d · 灯报 %d · GPS %@ %.1f a%+.1f · 前车 %@ 近%+.1f 加%+.1f 尾%.3f · 车%d · 装%.2fm 俯%.1f° fov%.0f",
            dets.count, tl.count, lightReports.count,
            location.ego.ok ? "ok" : "无",
            location.ego.v, location.ego.a,
            st.leadId == nil ? "无" : String(format: "%.0fm", st.leadDist),
            st.leadClosing, st.leadRelAcc, st.tailRatio,
            st.nTracks,
            calib.height, calib.pitch, calib.fov)
        let geom = String(format: "装高%.2fm 俯仰%.1f° 焦距%.0fpx 比例×%.2f",
                          calib.height, calib.pitch, calib.fx, mount.distScale)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.scene = st
            self.fps = fpsNow
            self.inferMs = detector.lastMs
            self.gpsOk = self.location.ego.ok
            self.gpsSpeed = self.location.ego.v
            self.gpsSrc = self.location.ego.src
            self.debugLine = dbg
            self.geomLine = geom
            self.world = wd
            // v1.4：规则告警 + 安全层告警合并仲裁，只播一条（同级规则优先）
            let top = AlertArbiter.pick(rules: st.alerts,
                                        safety: SafetyNarrator.alerts(wd))
            self.liveAlert = top
            if let a = top {
                self.speaker.speak(a, ts: ts)
                self.fireHaptic(a.level, ts: ts)
            }
        }
    }

    // MARK: - 触觉反馈（危险时车厢噪音大，震动比语音更即时）
    // 必须在主线程调用；同等级在窗口期内不重复震，避免连续几百帧把手机震到没电。
    private func fireHaptic(_ level: AlertLevel, _ ts: Double) {
        guard level.rawValue >= AlertLevel.warn.rawValue else { return }
        let isDanger = (level == .danger)
        let window = isDanger ? 1.5 : 4.0
        if ts - lastHapticAt < window && lastHapticLevel.rawValue >= level.rawValue { return }
        lastHapticAt = ts
        lastHapticLevel = level
        if isDanger {
            let g = UINotificationFeedbackGenerator()
            g.prepare()
            g.notificationOccurred(.error)
        } else {
            let g = UIImpactFeedbackGenerator(style: .light)
            g.prepare()
            g.impactOccurred()
        }
    }
}
