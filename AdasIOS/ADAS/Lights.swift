// Lights.swift — 交通信号灯跟踪（v1.1）
// YOLO 检出灯箱 → 框内颜色投票 → 连续 2 帧同色确认 → 物理尺寸法测距
import Foundation

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
    static let MAX_DIST_M = 80.0     // 超出直接不报
    static let MIN_DIST_M = 2.0

    private var map: [Int: Entry] = [:]
    /// 诊断：本帧投过票但仍未确认的灯数量
    private(set) var pendingCount = 0

    func reset() { map.removeAll() }

    /// tlTracks: tracker 里 name=="traffic light" 且 misses==0 的轨迹（工作区坐标）
    func update(_ tlTracks: [Track], _ img: FrameBuf, _ calib: Calib, _ ts: Double) -> [LightReport] {
        var out: [LightReport] = []
        // ★ 定标必须按实际画面尺寸 fit 过才有意义（Calib 是 struct，外面传进来的可能是未 fit 的）
        var c = calib
        c.fit(Double(img.width), Double(img.height))

        pendingCount = 0
        for tr in tlTracks {
            // ★ Entry 是 struct（值类型）：必须"取出 → 改本地副本 → 写回字典"，
            //   只改副本不写回的话，连续帧计数永远停在 1，CONFIRM_SAME 永远达不到，
            //   红绿灯就永远不会触发告警（v1.1 的隐性 bug，从 JS 对象语义移植时漏掉的）。
            var entry = map[tr.tid] ?? Entry(id: "L\(tr.tid)")
            entry.last = ts
            entry.box = tr.box.arr

            // 框内颜色投票（同色连续计数，异色重计）
            let (color, conf) = classifyLight(img, tr.box.arr)
            if color != .unknown {
                if color == entry.color { entry.hits += 1 }
                else { entry.color = color; entry.hits = 1 }
                entry.conf = conf
            }

            // 距离：灯箱物理尺寸法 d = fy·H / 像素高（不依赖俯仰标定，地平线附近也稳）
            let bh = max(3, tr.box.height)
            let d = c.fy * Self.HOUSING_H_M / bh
            entry.dist = (d >= Self.MIN_DIST_M && d <= Self.MAX_DIST_M) ? d : nil
            let xc = (tr.box.x1 + tr.box.x2) / 2
            if let dd = entry.dist, c.fx > 1 {
                entry.xm = (xc - c.cx) * dd / c.fx
            } else {
                entry.xm = nil
            }

            map[tr.tid] = entry          // 写回，状态才能跨帧累积

            if entry.hits >= Self.CONFIRM_SAME && entry.color != .unknown {
                out.append(LightReport(id: entry.id, color: entry.color, conf: entry.conf,
                                       dist: entry.dist, xm: entry.xm, box: tr.box.arr))
            } else {
                pendingCount += 1
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
