// Calib.swift — 单目标定与几何（移植 mobile/adas.js）
import Foundation
import CoreGraphics

typealias Vec2 = CGPoint

func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double {
    return v < a ? a : (v > b ? b : v)
}

func median(_ arr: [Double]) -> Double {
    if arr.isEmpty { return 0 }
    let b = arr.sorted()
    let n = b.count
    return n % 2 == 1 ? b[(n - 1) / 2] : 0.5 * (b[n / 2 - 1] + b[n / 2])
}

struct Calib {
    var fov: Double = 62          // 水平视场角（度）
    var height: Double = 1.30     // 光心离地高度（米）
    var pitch: Double = 4         // 光轴下俯角（度）
    var cxPx: Double = 0
    var cyPx: Double = 0
    var effW: Double = 0
    var fx: Double = 1, fy: Double = 1, cx: Double = 0, cy: Double = 0
    var horizon: Double = 0
    var w: Double = 0, h: Double = 0

    mutating func fit(_ w: Double, _ h: Double) {
        if self.w == w && self.h == h { return }
        self.w = w; self.h = h
        let wEff = effW > 0 ? effW : w
        fx = wEff / 2 / tan(fov * .pi / 360)
        fy = fx
        cx = cxPx > 0 ? cxPx : w / 2
        cy = cyPx > 0 ? cyPx : h / 2
        horizon = cy - fy * tan(pitch * .pi / 180)
    }
}

/// 画面行 -> 地面前向距离（米）。地平线以上返回 .infinity
func rowToDistance(_ v: Double, _ c: Calib) -> Double {
    let alpha = atan((v - c.cy) / c.fy)
    let phi = c.pitch * .pi / 180 + alpha
    if phi <= 0.4 * .pi / 180 { return .infinity }
    return c.height / tan(phi)
}

/// 世界点（右 x、前 z、上 y）-> 像素
func project(_ x: Double, _ z: Double, _ yUp: Double, _ c: Calib) -> Vec2 {
    let tau = c.pitch * .pi / 180
    let yDown = c.height - yUp
    let yc = yDown * cos(tau) - z * sin(tau)
    let zc = yDown * sin(tau) + z * cos(tau)
    if zc <= 0.05 { return Vec2(x: 0, y: 0) }
    return Vec2(x: c.cx + c.fx * x / zc, y: c.cy + c.fy * yc / zc)
}

let REAL_W: [String: Double] = [
    "car": 1.8, "truck": 2.45, "bus": 2.5, "person": 0.55,
    "motorcycle": 0.8, "bicycle": 0.65,
]

struct DistEstimate {
    let d: Double
    let src: String
}

/// 单目测距：地面法 + 宽度法融合
func estimateDistance(_ box: [Double], _ cls: String, _ c: Calib, _ th: Thresholds) -> DistEstimate {
    let dG = rowToDistance(box[3], c)
    let wPx = max(box[2] - box[0], 1)
    let dW = c.fx * (REAL_W[cls] ?? 1.8) / wPx

    let gOk = dG.isFinite && dG >= th.minValid && dG <= th.maxValid
    let wOk = dW >= th.minValid && dW <= th.maxValid && wPx > 12

    if gOk && wOk {
        if abs(dG - dW) <= 0.4 * dG { return DistEstimate(d: 0.7 * dG + 0.3 * dW, src: "fused") }
        return DistEstimate(d: dG, src: "ground")
    }
    if gOk { return DistEstimate(d: dG, src: "ground") }
    if wOk { return DistEstimate(d: dW, src: "width") }
    return DistEstimate(d: .nan, src: "invalid")
}

/// 自车道走廊多边形
func laneCorridor(_ c: Calib, halfW: Double = 1.75, zNear: Double = 3, zFar: Double = 90, n: Int = 12) -> [Vec2] {
    var left: [Vec2] = [], right: [Vec2] = []
    var zs: [Double] = []
    for i in 0..<n { zs.append(zNear * pow(zFar / zNear, Double(i) / Double(n - 1))) }
    for z in zs {
        left.append(project(-halfW, z, 0, c))
        right.append(project(halfW, z, 0, c))
    }
    return left + right.reversed()
}

/// 射线法：点在多边形内
func pointInPolygon(_ pt: Vec2, _ poly: [Vec2]) -> Bool {
    let x = Double(pt.x), y = Double(pt.y)
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let xi = Double(poly[i].x), yi = Double(poly[i].y)
        let xj = Double(poly[j].x), yj = Double(poly[j].y)
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
        j = i
    }
    return inside
}
