// EgoSpeed.swift — GPS 自车速度（移植 mobile/adas.js EgoSpeed）
import Foundation

/// 手机 GPS 车速。采样 1Hz、误差 ±0.5 m/s，用来做时距、前车绝对速度/减速度、低速抑制。
/// 输入优先用系统融合速度（CLLocation.speed）；拿不到就用两次定位的距离差分。
final class EgoSpeed {
    struct Sample { let t: Double; let v: Double }
    struct Fix { let t: Double; let lat: Double; let lon: Double }

    private(set) var samples: [Sample] = []
    private var lastFix: Fix? = nil
    private(set) var v = 0.0        // 当前速度 m/s
    private(set) var a = 0.0        // 自车加速度 m/s²
    private(set) var ok = false
    private(set) var src = "none"   // gps / diff / none
    private(set) var accM = 0.0
    private(set) var fixes = 0
    private(set) var tLast = 0.0

    /// 记一次定位。t 必须与主循环同一个时钟（秒，ProcessInfo.systemUptime）。
    @discardableResult
    func push(_ t: Double, lat: Double, lon: Double, speed: Double?, accuracy: Double?) -> Bool {
        guard lat.isFinite, lon.isFinite else { return false }
        fixes += 1
        accM = accuracy ?? 0

        let prev = lastFix
        lastFix = Fix(t: t, lat: lat, lon: lon)

        var vel: Double? = nil
        if let s = speed, s.isFinite, s >= 0 {
            vel = s; src = "gps"
        } else if let prev = prev {
            let dt = t - prev.t
            if dt > 0.3 && dt < 15 {
                let d = haversine(prev.lat, prev.lon, lat, lon)
                let vd = d / dt
                // 差分受定位噪声影响，超过 70m/s 一律当跳变丢掉
                if vd >= 0 && vd < 70 { vel = vd; src = "diff" }
            }
        }
        guard let vv = vel else { return false }

        samples.append(Sample(t: t, v: vv))
        if samples.count > 15 { samples.removeFirst() }
        return true
    }

    /// 在当前视觉帧时刻取速度（线性插值到帧时间）
    func at(_ t: Double) -> Double {
        if samples.isEmpty { ok = false; return 0 }
        let last = samples[samples.count - 1]
        let age = t - last.t
        // age<0 说明时钟不一致，样本不可信；>4s GPS 掉线（隧道/地下）→ 降级纯视觉
        if age > 4.0 || age < -1.0 { ok = false; return v }

        var vel = last.v
        if samples.count >= 2 {
            let a0 = samples[samples.count - 2], b = last
            let dt = b.t - a0.t
            if dt > 1e-3 && t > a0.t && t <= b.t {
                let k = clamp((t - a0.t) / dt, 0, 1)
                vel = a0.v + (b.v - a0.v) * k
            }
        }
        // 速度平滑
        v = (v == 0 && age < 2) ? vel : v + (vel - v) * 0.5
        ok = true

        // 加速度：用 ~3 秒基线，压住 1Hz 采样的量化噪声
        if samples.count >= 3 {
            var prev = samples[0]
            for smp in samples where smp.t <= t - 2.5 { prev = smp }
            let dt = last.t - prev.t
            if dt >= 1.5 {
                let aRaw = (last.v - prev.v) / dt
                a = a + (aRaw - a) * 0.4
            }
        }
        tLast = t
        return v
    }

    func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p = .pi / 180
        let dLat = (lat2 - lat1) * p, dLon = (lon2 - lon1) * p
        let h = pow(sin(dLat / 2), 2) + cos(lat1 * p) * cos(lat2 * p) * pow(sin(dLon / 2), 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
