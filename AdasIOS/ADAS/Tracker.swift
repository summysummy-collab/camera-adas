// Tracker.swift — IoU 跟踪器（移植 mobile/adas.js Track / IoUTracker）
import Foundation

struct Box {
    var x1: Double, y1: Double, x2: Double, y2: Double
    var arr: [Double] { [x1, y1, x2, y2] }
    var width: Double { x2 - x1 }
    var height: Double { y2 - y1 }
    var bottomCenter: Vec2 { Vec2(x: (x1 + x2) / 2, y: y2) }
    var center: Vec2 { Vec2(x: (x1 + x2) / 2, y: (y1 + y2) / 2) }
}

struct Detection {
    let clsId: Int
    let name: String
    let conf: Double
    let box: Box
}

func iou(_ a: Box, _ b: Box) -> Double {
    let ix1 = max(a.x1, b.x1), iy1 = max(a.y1, b.y1)
    let ix2 = min(a.x2, b.x2), iy2 = min(a.y2, b.y2)
    let iw = max(0, ix2 - ix1), ih = max(0, iy2 - iy1)
    let inter = iw * ih
    if inter <= 0 { return 0 }
    let aa = max(1e-6, (a.x2 - a.x1) * (a.y2 - a.y1))
    let bb = max(1e-6, (b.x2 - b.x1) * (b.y2 - b.y1))
    return inter / (aa + bb - inter)
}

let HIST = 40

final class Track {
    let tid: Int
    let clsId: Int
    let name: String
    var box: Box
    var hits = 1
    var misses = 0
    private(set) var ts: [Double] = []
    private(set) var ds: [Double] = []
    private(set) var cxs: [Double] = []
    var dS: Double? = nil            // 距离 EMA（量化噪声先压再进导数管线）
    var d: Double = .nan             // 本帧测距结果（RulesEngine 写入，等价 JS 的 tr._d）

    init(tid: Int, clsId: Int, name: String, box: Box) {
        self.tid = tid; self.clsId = clsId; self.name = name; self.box = box
    }

    func push(_ t: Double, _ d: Double, _ frameW: Double) {
        // 30m 处框底 1px 抖动 ≈ 1.3m 距离误差；减速度是二阶导，先 EMA（α=0.3）再存
        dS = dS == nil ? d : dS! + (d - dS!) * 0.3
        ts.append(t); ds.append(dS!); cxs.append(box.center.x / frameW)
        if ts.count > HIST { ts.removeFirst(); ds.removeFirst(); cxs.removeFirst() }
    }

    /// 相对接近速度（正 = 在靠近）。窗口内逐对差分取中位数，抗 ID 跳变
    func closingSpeed(_ windowS: Double = 0.7) -> Double {
        let n = ts.count
        if n < 3 { return 0 }
        let tEnd = ts[n - 1]
        var vs: [Double] = []
        for i in 1..<n {
            let dt = ts[i] - ts[i - 1]
            if dt <= 1e-3 || ts[i] < tEnd - windowS { continue }
            let d0 = ds[i - 1], d1 = ds[i]
            if !d0.isFinite || !d1.isFinite { continue }
            vs.append((d0 - d1) / dt)
        }
        return vs.isEmpty ? 0 : median(vs)
    }

    /// 接近加速度（m/s²）：近窗 [t-0.6, t] 与远窗 [t-1.7, t-1.1] 的中位接近速度差分
    func accel() -> Double {
        let n = ts.count
        if n < 6 { return 0 }
        let tEnd = ts[n - 1]
        func medV(_ t0: Double, _ t1: Double) -> Double? {
            var vs: [Double] = []
            for i in 1..<n {
                if ts[i] < t0 || ts[i] > t1 { continue }
                let dt = ts[i] - ts[i - 1]
                if dt <= 1e-3 { continue }
                let d0 = ds[i - 1], d1 = ds[i]
                if !d0.isFinite || !d1.isFinite { continue }
                vs.append((d0 - d1) / dt)
            }
            return vs.count >= 2 ? median(vs) : nil
        }
        guard let vLate = medV(tEnd - 0.6, tEnd + 1e-6),
              let vEarly = medV(tEnd - 1.7, tEnd - 1.1) else { return 0 }
        return (vLate - vEarly) / 1.0
    }

    /// 归一化横向速度（正 = 向右）
    func lateralSpeed(_ windowS: Double = 0.5) -> Double {
        let n = ts.count
        if n < 3 { return 0 }
        let tEnd = ts[n - 1]
        var i0 = -1
        let i1 = n - 1
        for i in 0..<n where ts[i] >= tEnd - windowS { i0 = i; break }
        if i0 < 0 || i1 <= i0 { return 0 }
        let dt = ts[i1] - ts[i0]
        return dt <= 1e-3 ? 0 : (cxs[i1] - cxs[i0]) / dt
    }

    /// 横向速度（**米/秒**，正 = 向右）。归一化像素速度 × 距离 / 焦距 = 物理横向速度，
    /// 比归一化量纲可解释得多：插队车典型 0.5–2 m/s，旁车道车辆≈0。
    func lateralMps(_ dist: Double, _ fx: Double, _ frameW: Double, windowS: Double = 0.6) -> Double {
        guard dist.isFinite, dist > 0, fx > 1, frameW > 1 else { return 0 }
        let n = ts.count
        if n < 3 { return 0 }
        let tEnd = ts[n - 1]
        let i1 = n - 1
        var i0 = -1
        for i in 0..<n where ts[i] >= tEnd - windowS { i0 = i; break }
        if i0 < 0 || i1 <= i0 { return 0 }
        let dt = ts[i1] - ts[i0]
        if dt <= 1e-3 { return 0 }
        let dPx = (cxs[i1] - cxs[i0]) * frameW      // cxs 已按帧宽归一化
        return dPx / dt * dist / fx
    }

    /// 轨迹第一帧的时间（用于判断"是不是刚出现"）
    var firstTs: Double { ts.first ?? 0 }
    /// 已跟踪时长（秒）
    func ageS(_ now: Double) -> Double { ts.isEmpty ? 0 : now - ts[0] }
}

final class IoUTracker {
    let iouThr: Double
    let maxMiss: Int
    private(set) var tracks: [Track] = []
    private var nextId = 1

    init(iouThr: Double = 0.3, maxMiss: Int = 8) {
        self.iouThr = iouThr; self.maxMiss = maxMiss
    }

    func update(_ dets: [Detection]) -> [Track] {
        struct Pair { let v: Double; let ti: Int; let di: Int }
        var pairs: [Pair] = []
        for ti in tracks.indices {
            let tr = tracks[ti]
            for di in dets.indices {
                if dets[di].clsId != tr.clsId { continue }
                let v = iou(tr.box, dets[di].box)
                if v >= iouThr { pairs.append(Pair(v: v, ti: ti, di: di)) }
            }
        }
        pairs.sort { $0.v > $1.v }
        var usedT = Set<Int>(), usedD = Set<Int>()
        for p in pairs {
            if usedT.contains(p.ti) || usedD.contains(p.di) { continue }
            usedT.insert(p.ti); usedD.insert(p.di)
            let tr = tracks[p.ti]
            tr.box = dets[p.di].box
            tr.hits += 1
            tr.misses = 0
        }
        for ti in tracks.indices where !usedT.contains(ti) { tracks[ti].misses += 1 }
        for di in dets.indices where !usedD.contains(di) {
            let d = dets[di]
            tracks.append(Track(tid: nextId, clsId: d.clsId, name: d.name, box: d.box))
            nextId += 1
        }
        tracks.removeAll { $0.misses > maxMiss }
        return tracks
    }
}
