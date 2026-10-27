// Safety.swift — v1.3 周边安全态势（感知 → 世界模型 → 风险评估）
//
// 与 v1.2 的区别是**产品形态**，不是算法：
//   v1.2 及以前是"事件驱动"——命中某条规则就喊一嗓子，屏幕上看不到环境。
//   v1.3 改成自动驾驶那套**状态驱动**：每帧输出一个世界快照（目标表 + 车道归属 +
//   安全距离余量），告警只是这个快照的推论。于是"周边安不安全"变成可以持续观察的量，
//   而不是等出事才响。
//
// 三层：
//   TargetState  —— 每个目标的运动学状态（横向/纵向位置、接近速度、横向速度、车道归属）
//   SafetyWorld  —— 自车状态 + 目标表 + 可行驶净空 + 占据栅格（BEV，带历史衰减）
//   RiskModel    —— TTC / THW / RSS 安全距离 / 所需减速度 → 分级
//
// 指标口径取自自动驾驶通行定义：
//   THW = z / v_ego            跟车时距（秒），城市 1.5–2s 正常，<1s 危险
//   TTC = z / v_closing        碰撞时间（秒），只在接近时有限
//   RSS = v·ρ + a·ρ²/2 + v²/2b 责任敏感安全距离（Mobileye 可形式化模型）
//   a_req = v_rel² / 2(z-z0)   避免碰撞所需减速度，>6m/s² 已超出干沥青能力
import Foundation
import CoreGraphics

enum RiskLevel: Int, Comparable {
    case clear = 0, watch = 1, warn = 2, danger = 3

    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .clear: return "安全"
        case .watch: return "留意"
        case .warn: return "预警"
        case .danger: return "危险"
        }
    }
}

/// 自车状态。有 GPS 用 GPS，没有就退化为"只报相对量"（THW/TTC 会标 N/A）
struct EgoState {
    var v: Double = 0          // 纵向速度 m/s
    var a: Double = 0          // 纵向加速度 m/s²
    var ok = false             // 速度是否可用
    var src = "none"
}

/// 单个目标的运动学状态（自车坐标系：x 右正、z 前正）
struct TargetState {
    var id: Int = 0
    var cls: String = ""
    var x: Double = 0          // 横向偏移 m
    var z: Double = 0          // 纵向距离 m
    var vz: Double = 0         // 接近速度 m/s（正 = 在靠近）
    var vx: Double = 0         // 横向速度 m/s（正 = 向右）
    var wM: Double = 1.8       // 物理宽度 m
    var lane: Int = 0          // -1 左道 / 0 本道 / 1 右道 / 9 路外
    var ttc: Double = .infinity
    var thw: Double = .infinity
    var aReq: Double = 0       // 所需减速度 m/s²
    var rssMargin: Double = .nan   // 实际距离 - RSS 安全距离（负 = 已越界）
    var predZ: [Double] = []   // 0.5 / 1.0 / 1.5 秒后的预测纵向位置
    var level: RiskLevel = .clear
    var box: [Double] = [0, 0, 0, 0]
}

/// 世界快照。每帧产出一个，UI 只读它，不再直接读 Track。
struct SafetyWorld {
    var ts: Double = 0
    var ego = EgoState()
    var laneHalfW: Double = 1.75
    var freeSpaceM: Double = 110        // 本车道前方净空（米）
    var targets: [TargetState] = []
    var nearestPed: Double = .nan
    var laneRisk: [Int: RiskLevel] = [:]  // 车道 → 最高风险
    // BEV 占据栅格：x ∈ [-10, 10]，z ∈ [0, 40]，0.5m 一格
    var grid: [UInt8] = []
    var gridCols = 40
    var gridRows = 80
    var gridCell = 0.5
    var gridX0 = -10.0
    var summary = ""

    static let empty = SafetyWorld()

    var worst: RiskLevel { targets.map { $0.level }.max() ?? .clear }

    /// 本车道最近目标
    var lead: TargetState? {
        targets.filter { $0.lane == 0 && $0.z > 1 }.min { $0.z < $1.z }
    }

    func count(_ lane: Int) -> Int {
        targets.filter { $0.lane == lane && $0.z < 45 }.count
    }
}

enum RiskModel {
    static let rhoS = 1.0             // 反应时间（秒）
    static let aAccMax = 3.0          // 自车最大加速度（RSS 用）
    static let aBrakeMin = 6.0        // 自车最小可用减速度 m/s²
    static let aLeadBrakeMax = 8.0    // 前车最大减速度 m/s²
    static let stopGapM = 4.0         // 停车静态余量

    static func ttc(_ z: Double, _ vz: Double) -> Double {
        guard z.isFinite, z > 0.5, vz > 0.3 else { return .infinity }
        return z / vz
    }

    static func thw(_ z: Double, _ vEgo: Double, egoOk: Bool) -> Double {
        guard egoOk, z.isFinite, z > 0 else { return .infinity }
        return z / max(vEgo, 1.0)
    }

    /// RSS 安全纵向距离：自车反应 ρ 秒后才开始以 aBrakeMin 制动，前车以 aLeadBrakeMax 制动
    static func rssGap(_ vEgo: Double, _ vLead: Double) -> Double {
        let v1 = max(vEgo, 0), v2 = max(vLead, 0)
        let d = v1 * rhoS + 0.5 * aAccMax * rhoS * rhoS
              + v1 * v1 / (2 * aBrakeMin) - v2 * v2 / (2 * aLeadBrakeMax)
        return max(d, stopGapM)
    }

    /// 避免碰撞所需减速度（留 stopGapM 余量后）
    static func aRequired(_ z: Double, _ vz: Double) -> Double {
        guard vz > 0 else { return 0 }
        let s = max(z - stopGapM, 1.0)
        return vz * vz / (2 * s)
    }

    /// 分级。本车道目标看 TTC / 所需减速度 / RSS 余量；旁车道降两级（切进来才算账）
    static func grade(ttc t: Double, thw h: Double, aReq: Double,
                      margin: Double, lane: Int, closing: Double) -> RiskLevel {
        var lv = RiskLevel.clear
        if t < 1.8 || aReq > 5.0 || (margin.isFinite && margin < 0) {
            lv = .danger
        } else if t < 3.0 || aReq > 3.0 || (margin.isFinite && margin < 3) {
            lv = .warn
        } else if (t < 6.0 && closing > 0.5) || h < 2.0 || (margin.isFinite && margin < 8) {
            lv = .watch
        }
        if lane != 0 {
            lv = RiskLevel(rawValue: max(0, lv.rawValue - 2)) ?? .clear
        }
        return lv
    }
}

final class SafetyAssessor {
    var th = Thresholds.default
    private var grid: [UInt8]
    private let cols = 40, rows = 80
    private let cellM = 0.5
    private let x0 = -10.0

    init() {
        grid = [UInt8](repeating: 0, count: 40 * 80)
    }

    func update(_ tracks: [Track], _ calib: Calib, ego: EgoSpeed?, ts: Double) -> SafetyWorld {
        var w = SafetyWorld()
        w.ts = ts
        w.laneHalfW = 1.75
        if let e = ego {
            w.ego = EgoState(v: e.v, a: e.a, ok: e.ok, src: e.src)
        }
        if calib.fx < 1 { return w }   // 几何未就绪，这帧不出世界模型

        let frameW = Double(calib.w)
        let fx = calib.fx
        var out: [TargetState] = []
        out.reserveCapacity(tracks.count)

        for tr in tracks {
            if tr.name == "traffic light" { continue }
            let est = estimateDistance(tr.box.arr, tr.name, calib, th)
            guard est.d.isFinite, est.d >= 2.0, est.d <= 110 else { continue }

            let z = est.d
            var t = TargetState()
            t.id = tr.tid
            t.cls = tr.name
            t.z = z
            t.box = tr.box.arr
            t.wM = REAL_W[tr.name] ?? 1.8
            t.x = (Double(tr.box.center.x) - calib.cx) * z / fx
            t.vz = tr.closingSpeed()
            t.vx = tr.lateralMps(z, fx, frameW)

            let vEgo = w.ego.ok ? w.ego.v : 0
            let vLead = max(vEgo - t.vz, 0)
            t.ttc = RiskModel.ttc(z, t.vz)
            t.thw = RiskModel.thw(z, vEgo, egoOk: w.ego.ok)
            t.aReq = RiskModel.aRequired(z, t.vz)
            let gap = RiskModel.rssGap(vEgo, vLead)
            t.rssMargin = w.ego.ok ? (z - gap) : .nan
            t.predZ = [0.5, 1.0, 1.5].map { max(0, z - t.vz * $0) }

            // 车道归属：按车道中心距（车道宽 3.5m）就近取整
            let k = Int((t.x / 3.5).rounded())
            t.lane = abs(k) >= 2 ? 9 : k

            t.level = RiskModel.grade(ttc: t.ttc, thw: t.thw, aReq: t.aReq,
                                      margin: t.rssMargin, lane: t.lane, closing: t.vz)
            if t.lane != 0 {
                let prev = w.laneRisk[t.lane] ?? .clear
                w.laneRisk[t.lane] = max(prev, t.level)
            }
            if tr.name == "person" && t.z < 40 {
                let p = w.nearestPed.isNaN ? t.z : min(w.nearestPed, t.z)
                w.nearestPed = p
            }
            out.append(t)
        }

        w.targets = out
        // 本车道净空 = 本道最近目标的距离；看不到车就是"传感器视距"
        let leadZ = out.filter { $0.lane == 0 && $0.z > 1 }.map { $0.z }.min()
        w.freeSpaceM = leadZ ?? 110

        // ---- BEV 占据栅格：整体衰减一格，再把本帧目标写真值 ----
        for i in grid.indices where grid[i] > 0 { grid[i] -= 1 }
        for t in out where t.lane != 9 && t.z < 40 {
            let zc0 = Int(((t.z - 2.2) / cellM).rounded(.down))
            let zc1 = Int(((t.z + 2.2) / cellM).rounded(.down))
            let xc0 = Int(((t.x - t.wM / 2 - x0) / cellM).rounded(.down))
            let xc1 = Int(((t.x + t.wM / 2 - x0) / cellM).rounded(.down))
            for r in max(0, zc0)...min(rows - 1, zc1) {
                for c in max(0, xc0)...min(cols - 1, xc1) {
                    grid[r * cols + c] = 12
                }
            }
        }
        w.grid = grid

        // ---- 一句话状态（HUD 顶部显示）----
        let leadDesc: String
        if let l = w.lead {
            let thwS = l.thw.isFinite ? String(format: "时距%.1fs", l.thw) : "时距N/A"
            let ttcS = l.ttc.isFinite ? String(format: "TTC%.1fs", l.ttc) : "TTC∞"
            leadDesc = String(format: "本道前车 %.0fm %@ %@", l.z, thwS, ttcS)
        } else {
            leadDesc = "本道无目标"
        }
        w.summary = String(format: "%@ · 净空%.0fm · 左%d 右%d",
                           leadDesc, w.freeSpaceM, w.count(-1), w.count(1))
        return w
    }
}
