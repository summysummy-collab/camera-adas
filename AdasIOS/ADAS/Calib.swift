// Calib.swift — 单目几何与测距（v1.2 重写测距融合）
//
// v1.1 及以前的 estimateDistance 只要地面法"有效"就优先采信它，而地面法在
// 远距离是**数值病态**的：d = h / tan(pitch + atan((v-cy)/fy))，在 20m 以外
// 分母只有 1~2 度，俯仰角差 2° 就能把 30m 算成 114m（约 3.8 倍）——这正是
// 实车反馈"距离约为实际的 3 倍"的根因。
//
// v1.2 改为**三路估计 + 逆方差加权**：
//   · 地面法 ground：近距离（<15m）极准，远距离迅速失准 → σd/d ≈ (d/h)·σpitch
//   · 宽度法 width ：与俯仰/安装高度无关，只依赖焦距与真实车宽 → 远距离主力
//   · 高度法 height：同理，对行人（身高稳定）尤其好用
// 权重 = 1/σ²，于是近距离自动靠地面法、远距离自动交给尺寸法；再用"一致性闸门"
// 剔除明显背离的一路，避免单路跑飞拖累融合结果。
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

/// 安装几何。全部四个量都能被 LiDAR/重力标定自动写入（见 MountConfig / LiDARCalibrator）。
struct Calib {
    var fov: Double = 62          // 水平视场角（度）—— 运行时由 activeFormat.videoFieldOfView 覆盖
    var height: Double = 1.25     // 光心离地高度（米）
    var pitch: Double = 4         // 光轴下俯角（度）—— 运行时由 CoreMotion 重力覆盖
    var cxPx: Double = 0
    var cyPx: Double = 0
    var effW: Double = 0
    /// 俯仰角不确定度（度）。自动测量取 0.6；手工猜测取 2.0 —— 直接决定地面法的权重
    var pitchSigmaDeg: Double = 2.0
    var fx: Double = 1, fy: Double = 1, cx: Double = 0, cy: Double = 0
    var horizon: Double = 0
    var w: Double = 0, h: Double = 0

    mutating func fit(_ w: Double, _ h: Double) {
        if self.w == w && self.h == h { return }
        self.w = w; self.h = h
        let wEff = effW > 0 ? effW : w
        fx = wEff / 2 / tan(fov * Double.pi / 360)
        fy = fx                        // 工作区 640x360 内容区是 16:9 等比缩放，像元为正方形
        cx = cxPx > 0 ? cxPx : w / 2
        cy = cyPx > 0 ? cyPx : h / 2   // letterbox 上下各 12px，中轴仍在 h/2
        horizon = cy - fy * tan(pitch * Double.pi / 180)
    }

    /// 参数（fov/pitch/height）变化后必须强制重算 fx/fy
    mutating func refit(_ w: Double, _ h: Double) {
        self.w = -1; self.h = -1
        fit(w, h)
    }
}

/// 画面行 -> 地面前向距离（米）。地平线以上返回 .infinity
func rowToDistance(_ v: Double, _ c: Calib) -> Double {
    let alpha = atan((v - c.cy) / c.fy)
    let phi = c.pitch * Double.pi / 180 + alpha
    if phi <= 0.4 * Double.pi / 180 { return .infinity }
    return c.height / tan(phi)
}

/// 世界点（右 x、前 z、上 y）-> 像素
func project(_ x: Double, _ z: Double, _ yUp: Double, _ c: Calib) -> Vec2 {
    let tau = c.pitch * Double.pi / 180
    let yDown = c.height - yUp
    let yc = yDown * cos(tau) - z * sin(tau)
    let zc = yDown * sin(tau) + z * cos(tau)
    if zc <= 0.05 { return Vec2(x: 0, y: 0) }
    return Vec2(x: c.cx + c.fx * x / zc, y: c.cy + c.fy * yc / zc)
}

/// 真实横向尺寸（米）—— 宽度法用
let REAL_W: [String: Double] = [
    "car": 1.80, "truck": 2.45, "bus": 2.50, "person": 0.55,
    "motorcycle": 0.80, "bicycle": 0.65,
]
/// 真实纵向尺寸（米）—— 高度法用（行人身高最稳定，是远距离行人的主力判据）
let REAL_H: [String: Double] = [
    "car": 1.50, "truck": 3.30, "bus": 3.20, "person": 1.70,
    "motorcycle": 1.30, "bicycle": 1.45,
]

struct DistEstimate {
    let d: Double
    let src: String        // ground / width / height 的组合，便于诊断
    var ok: Bool { d.isFinite }
}

/// 单目测距：地面法 + 宽度法 + 高度法 逆方差加权
func estimateDistance(_ box: [Double], _ cls: String, _ c: Calib, _ th: Thresholds) -> DistEstimate {
    let dG = rowToDistance(box[3], c)
    let wPx = max(box[2] - box[0], 1)
    let hPx = max(box[3] - box[1], 1)
    let dW = c.fx * (REAL_W[cls] ?? 1.8) / wPx
    let dH = c.fy * (REAL_H[cls] ?? 1.5) / hPx

    var cands: [(d: Double, s: Double, tag: String)] = []

    // 地面法：σd/d ≈ (d/h)·σpitch，再叠上框底 1.5px 抖动
    if dG.isFinite && dG >= th.minValid && dG <= th.maxValid {
        let hh = max(c.height, 0.5)
        let sp = c.pitchSigmaDeg * Double.pi / 180
        let relPitch = dG / hh * sp
        let pxNoise = dG * dG / (hh * max(c.fy, 1)) * 1.5 / dG
        let rel = (relPitch * relPitch + pxNoise * pxNoise).squareRoot()
        cands.append((dG, min(max(rel, 0.03), 2.0), "G"))
    }
    // 宽度法：与安装角无关，只吃"车宽先验 + 框宽抖动"
    if dW >= th.minValid && dW <= th.maxValid && wPx > 12 {
        cands.append((dW, 0.065, "W"))
    }
    // 高度法：车型/载重差异更大，给略低的权重
    if dH >= th.minValid && dH <= th.maxValid && hPx > 14 {
        cands.append((dH, 0.085, "H"))
    }
    guard !cands.isEmpty else { return DistEstimate(d: .nan, src: "invalid") }

    // 1) 以最可信的一路为锚，剔除明显背离（>2.2 倍）的估计
    cands.sort { $0.s < $1.s }
    let anchor = cands[0]
    var keep = [anchor]
    for k in cands.dropFirst() where abs(log(k.d / anchor.d)) < log(2.2) {
        keep.append(k)
    }
    // 2) 中位数锚定，再按 1/σ² 加权（防单路跑飞）
    let sorted = keep.map { $0.d }.sorted()
    let dStar = sorted[sorted.count / 2]
    var num = 0.0, den = 0.0
    var tags: [String] = []
    for k in keep where abs(log(k.d / dStar)) < log(1.8) {
        let wgt = 1.0 / (k.s * k.s)
        num += wgt * k.d; den += wgt
        tags.append(k.tag)
    }
    guard den > 0 else { return DistEstimate(d: .nan, src: "invalid") }
    let d = num / den * th.distScale
    guard d.isFinite && d >= th.minValid * 0.8 && d <= th.maxValid else {
        return DistEstimate(d: .nan, src: "invalid")
    }
    return DistEstimate(d: d, src: tags.joined(separator: "+"))
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
    if poly.count < 3 { return false }
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
