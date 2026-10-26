// Engine.swift — 主循环编排：检测 → 跟踪 → 灯 → 规则 → 告警
import Foundation
import CoreVideo
import CoreML
import QuartzCore

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

    let camera = CameraManager()
    let speaker = AlertSpeaker()
    let location = LocationFeed()
    private var detector: Detector?
    private var tracker = IoUTracker()
    private var lights = LightTracker()
    private var rules: RulesEngine?
    private var calib = Calib()
    private var lastFrameTs: Double = 0
    private var fpsEma: Double = 0

    func start() throws {
        if detector == nil {
            let det = try Detector(conf: 0.35)
            detector = det
            inferMs = det.lastMs
        }
        rules = RulesEngine(calib: calib)
        rules?.tailRatioProvider = { [weak self] box in
            guard let self = self, let pb = self.camera.workspace,
                  let fb = FrameBuf(pb) else { return nil }
            let r = redRatio(fb, box)
            fb.finished(pb)
            return r
        }
        camera.onFrame = { [weak self] ws, ts in
            self?.processFrame(ws, ts: ts)
        }
        location.request()
        try camera.start()
        running = true
    }

    func stop() {
        camera.stop()
        camera.onFrame = nil
        location.stop()
        running = false
    }

    /// 相机队列上执行（非主线程）
    private func processFrame(_ ws: CVPixelBuffer, ts: Double) {
        guard let detector = detector, let rules = rules else { return }

        // fps
        if lastFrameTs > 0 {
            let f = 1.0 / max(1e-3, ts - lastFrameTs)
            fpsEma = fpsEma == 0 ? f : fpsEma + (f - fpsEma) * 0.1
        }
        lastFrameTs = ts

        let dets = (try? detector.detect(ws)) ?? []
        let tracks = tracker.update(dets)

        var fb: FrameBuf? = FrameBuf(ws)
        defer { if let f = fb { f.finished(ws) } }

        // 信号灯
        let tl = tracks.filter { $0.name == "traffic light" && $0.misses == 0 }
        var lightReports: [LightReport] = []
        if let f = fb {
            lightReports = lights.update(tl, f, calib, ts)
        }

        let ctx = SceneCtx(w: Double(CameraManager.WS_W), h: Double(CameraManager.WS_H),
                           ego: location.ego, lights: lightReports)
        let st = rules.update(tracks, ts, ctx)

        let fpsNow = fpsEma
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.scene = st
            self.fps = fpsNow
            self.inferMs = detector.lastMs
            self.gpsOk = self.location.ego.ok
            self.gpsSpeed = self.location.ego.v
            self.gpsSrc = self.location.ego.src
            if let top = st.alerts.first {
                self.speaker.speak(top, ts: ts)
            }
        }
    }
}
