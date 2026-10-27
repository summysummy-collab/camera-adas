// SafetyNarrator.swift — 把"风险评分"翻译成能听见的提醒，并与规则告警统一仲裁
//
// 为什么需要这一层：
//   v1.3 的 Safety.swift 只负责"看清 + 打分"，结果只喂给左下角面板（变色），
//   真正发声的仍然只有 Rules.swift 的几条硬规则。也就是说：
//   面板红了，但车里是安静的 —— 危险时没有提醒。
//   本层把世界模型的风险等级接进语音 + 触觉通道。
//
// 三个设计约束：
//   1. 旁车道目标一律降级：只在"确实正压向本车道"时才提示，避免重演
//      "左右有车就一直报插队"的旧毛病。
//   2. 与 Rules 告警合并后只播一条：同级以 Rules 为准，因为规则文案更具体
//      （"前车刹车" 优于 "前方危险"）。
//   3. 同一语义组抑制重复（见 AlertSpeaker），否则距离每变一米就打断一次。

import Foundation

enum SafetyNarrator {

    // —— 可调门限 ——
    /// 行人提示距离（米）
    static let pedWarnM = 18.0
    /// 行人进入此距离且自车在动 → 危险级
    static let pedDangerM = 10.0
    /// 本道无目标但净空小于此值 → 提示（弯道 / 归属判错 / 遮挡兜底）
    static let freeWarnM = 14.0
    /// 旁道目标"正在压向本道"的横向速度门限（m/s）
    static let sideTowardMps = 0.35
    /// 旁道目标距离本车道边界小于此值（米）视为压线
    static let sideStraddleM = 1.2
    /// 旁道只在近处提示
    static let sideMaxM = 25.0

    /// 由世界快照生成告警候选（不含 Rules 的告警）
    static func alerts(_ w: SafetyWorld) -> [Alert] {
        var out: [Alert] = []
        guard w.ts > 0 else { return out }

        let vEgo = w.ego.ok ? w.ego.v : 0
        let moving = vEgo > 1.5

        // ---------- 1. 本车道最近目标：这是最该说的一句 ----------
        if let ld = w.lead {
            switch ld.level {
            case .danger:
                out.append(Alert(key: "s_lead_danger", text: dangerText(ld), level: .danger))
            case .warn:
                out.append(Alert(key: "s_lead_warn",
                                 text: String(format: "前方%.0f米，%@", ld.z, advice(ld)),
                                 level: .warn))
            default:
                break
            }
        }

        // ---------- 2. 本道没有目标但净空被吃掉 ----------
        if moving, w.lead == nil, w.freeSpaceM < freeWarnM {
            out.append(Alert(key: "s_free",
                             text: String(format: "前方净空%.0f米", w.freeSpaceM),
                             level: w.freeSpaceM < 7 ? .danger : .warn))
        }

        // ---------- 3. 行人 ----------
        if w.nearestPed.isFinite, w.nearestPed < pedWarnM {
            let inLane = w.targets.contains {
                $0.cls == "person" && $0.lane == 0 && $0.z < pedWarnM
            }
            let lv: AlertLevel = (inLane && w.nearestPed < pedDangerM && moving) ? .danger : .warn
            out.append(Alert(key: "s_ped",
                             text: String(format: "行人%.0f米", w.nearestPed),
                             level: lv))
        }

        // ---------- 4. 旁车道：只在正在压向本道时报一句 ----------
        for lane in [-1, 1] {
            let cand = w.targets
                .filter { $0.lane == lane && $0.z > 1 && $0.z < sideMaxM }
                .min { $0.z < $1.z }
            guard let t = cand else { continue }
            // 旁道目标在评估时已被降两级，level 还能到 warn 说明原始判为 danger
            guard t.level >= .warn else { continue }
            let toward = lane < 0 ? t.vx > sideTowardMps : t.vx < -sideTowardMps
            let straddle = abs(t.x) < 3.5 * 0.5 + sideStraddleM
            guard toward || straddle else { continue }
            let side = lane < 0 ? "左侧" : "右侧"
            out.append(Alert(key: "s_side",
                             text: String(format: "%@车辆贴近%.0f米", side, t.z),
                             level: .warn))
        }

        return out
    }

    private static func dangerText(_ t: TargetState) -> String {
        if t.ttc.isFinite && t.ttc < 1.8 {
            return String(format: "危险，%.1f秒后碰撞", t.ttc)
        }
        if t.aReq > 5.0 {
            return String(format: "危险，前方%.0f米，立即减速", t.z)
        }
        return String(format: "危险，前方%.0f米", t.z)
    }

    private static func advice(_ t: TargetState) -> String {
        if t.aReq > 3.0 { return "准备刹车" }
        if t.thw.isFinite && t.thw < 2.0 { return "跟车过近" }
        return "注意车距"
    }
}

/// 告警仲裁：规则告警 + 安全告警 → 只留一条要播的
enum AlertArbiter {
    /// 同级取"规则"那条（文案更具体）；Safety 的 info 级不参与（不上屏不发声）
    static func pick(rules: [Alert], safety: [Alert]) -> Alert? {
        var all = rules
        for a in safety where a.level.rawValue >= AlertLevel.warn.rawValue {
            all.append(a)
        }
        guard let first = all.first else { return nil }
        var best = first
        for a in all.dropFirst() where a.level.rawValue > best.level.rawValue {
            best = a
        }
        return best
    }
}
