// MotionPitch.swift — 用重力方向实时测"光轴下俯角"
//
// 后置摄像头光轴 = 设备坐标系的 -Z 方向。俯角（向下为正）：
//     pitch = asin( -gravity.z )
// 手机竖直立起（背面朝前、光轴水平）时 gravity=(0,-1,0) → pitch=0；
// 屏幕朝上放平（光轴朝地）时 gravity=(0,0,-1) → pitch=90°。与 UI 横竖屏无关。
//
// 这比硬编码 4° 强得多：地面法对俯仰角的敏感度是 d²/h 量级，
// 差 2° 在 30m 处就能算出 3 倍以上的距离误差。
import Foundation
import CoreMotion

final class MotionPitch {
    private let mgr = CMMotionManager()
    private let queue = OperationQueue()
    private var ema: Double = .nan
    private let lock = NSLock()
    private(set) var running = false
    /// 更新回调（在后台队列上调用）
    var onUpdate: ((Double) -> Void)?

    init() {
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
    }

    func start() {
        guard mgr.isDeviceMotionAvailable, !running else { return }
        running = true
        mgr.deviceMotionUpdateInterval = 1.0 / 25.0
        mgr.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            let g = motion.gravity
            let c = max(-1.0, min(1.0, -g.z))
            let deg = asin(c) * 180.0 / Double.pi
            self.lock.lock()
            // α=0.06 @25Hz ≈ 0.6s 时间常数：抖动 ±0.2° 被压到 ±0.05°，不影响真实安装角变化
            self.ema = self.ema.isNaN ? deg : self.ema + (deg - self.ema) * 0.06
            let out = self.ema
            self.lock.unlock()
            self.onUpdate?(out)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        mgr.stopDeviceMotionUpdates()
    }

    /// 平滑后的俯角（度）；未就绪时为 .nan
    var value: Double {
        lock.lock(); defer { lock.unlock() }
        return ema
    }
}
