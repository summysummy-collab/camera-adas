// MountConfig.swift — 手机安装几何的持久化配置
//
// 单目测距的精度几乎完全由这四个量决定，必须实测而不是猜：
//   fovDeg    水平视场角 → 焦距 fx（尺寸法全部依赖它）
//   pitchDeg  光轴下俯角 → 地面法的必要条件（差 2° 在 30m 处能差 3 倍）
//   heightM   光心离地高度 → 地面法直接成正比
//   distScale 残余系统偏差的手动缩放（标定后一般保持 1.0）
import Foundation

struct MountConfig: Codable, Equatable {
    var fovDeg: Double = 0          // 0 = 自动读 activeFormat.videoFieldOfView
    var pitchDeg: Double = 4.0      // 手工/标定得到的下俯角
    var heightM: Double = 1.25      // 光心离地高度
    var distScale: Double = 1.0     // 手动比例校正
    var pitchAuto = true            // true = 用 CoreMotion 重力实时测俯仰
    var calibrated = false          // 是否做过 LiDAR/ARKit 标定
    var calibratedAt: Double = 0    // unix 时间戳，便于确认用的是哪次标定
    var lastResidual: Double = 0    // 标定时的高度样本离散度（米），0 = 未知。不能存 NaN，JSON 编码会失败

    static let key = "MountConfig.v1"

    static func load() -> MountConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode(MountConfig.self, from: data) else {
            return MountConfig()
        }
        return m
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: MountConfig.key)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: MountConfig.key)
    }

    /// 给人看的一行摘要
    var summary: String {
        let f = fovDeg > 1 ? String(format: "fov %.1f°(固定)", fovDeg) : "fov 自动"
        let p = pitchAuto ? String(format: "俯仰 %.1f°(重力实时)", pitchDeg) : String(format: "俯仰 %.1f°(固定)", pitchDeg)
        return String(format: "装高 %.2fm · %@ · %@ · 比例 %.2f", heightM, p, f, distScale)
    }
}
