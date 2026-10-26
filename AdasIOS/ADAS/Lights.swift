// Lights.swift — 交通信号灯跟踪（移植 mobile/lights.js LightTracker v8）
import Foundation

/// YOLO 检出灯箱 → 框内颜色投票 → 连续 2 帧同色确认 → 物理尺寸法测距
final class LightTracker {
    struct Entry {
        let id: String
        var color: LightColor = .unknown
        var hits = 0
        var conf = 0.0
        var last = 0.0
        var box: [Double] = []
        var dist: Double? = nil
        var xm: Double? = nil
    }

    static let HOUSING_H_M = 1.0     // 灯箱（竖排三灯）典型物理高度，测距用
    static let CONFIRM_SAME = 2      // 连续同色多少帧才确认
    static let MAX_AGE_S = 1.0       // 轨迹消失多久后丢弃状态
    static let MAX_DIST_M = 70.0     // 超出直接不报

    private var map: [Int: Entry] = [:]

    func reset() { map.removeAll() }

    /// tlTracks: tracker 里 name=="traffic light" 且 misses==0 的轨迹（工作区坐标）
    func update(_ tlTracks: [Track], _ img: FrameBuf, _ calib: Calib, _ ts: Double) -> [LightReport] {
        var out: [LightReport] = []
        for tr in tlTracks {
            var e = map[tr.tid]
            if e == nil {
                e = Entry(id: "L\(tr.tid)")
                map[tr.tid] = e
            }
            e!.last = ts
            e!.box = tr.box.arr

            // 框内颜色投票（同色连续计数，异色重计）
            let (color, conf) = classifyLight(img, tr.box.arr)
            if color != .unknown {
                if color == e!.color { e!.hits += 1 }
                else { e!.color = color; e!.hits = 1 }
                e!.conf = conf
            }

            // 距离：灯箱物理尺寸法 d = fy·H / 像素高（有界、不依赖俯仰标定）
            let bh = max(4, tr.box.height)
            let d = calib.fy * Self.HOUSING_H_M / bh
            e!.dist = (d >= 3 && d <= Self.MAX_DIST_M) ? d : nil
            let xc = (tr.box.x1 + tr.box.x2) / 2
            e!.xm = (e!.dist?.isFinite == true && e!.dist != nil)
                ? ((xc - calib.cx) * e!.dist!) / calib.fx : nil

            if e!.hits >= Self.CONFIRM_SAME && e!.color != .unknown {
                out.append(LightReport(id: e!.id, color: e!.color, conf: e!.conf,
                                       dist: e!.dist, xm: e!.xm, box: tr.box.arr))
            }
        }
        map = map.filter { ts - $0.value.last <= Self.MAX_AGE_S }
        // 本车道优先、距离近优先
        out.sort { p, q in
            let ax = abs(p.xm ?? 0), bx = abs(q.xm ?? 0)
            if abs(ax - bx) > 1.5 { return ax < bx }
            return (p.dist ?? 999) < (q.dist ?? 999)
        }
        return out
    }
}
