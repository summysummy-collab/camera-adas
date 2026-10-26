// Rules.swift — 告警规则引擎（v1.1 iOS 实测修订）
//
// 相对 v1.0 的四处改动（对应实车反馈）：
//  1) 红绿灯：距离改由**已 fit 的 calib** 计算，范围放宽到 2–80m（v1.0 传的是未 fit 的
//     Calib 副本，fy=1，所有灯距离都算成 0.05m 被过滤掉 → 永不报警）。
//  2) 前车刹车：改为三路证据融合（相对接近加速度 / 尾灯突增 / GPS 绝对减速度），
//     任一条成立即触发，不再要求"必须有 GPS"或"减速度 >5 m/s²"。
//  3) 插队：改成**走廊状态迁移**判据 —— 必须是被稳定跟踪过的车、最近 2 秒内刚从
//     本车道走廊外进入、并且横向速度（m/s）朝本车轴。旁车道车辆因此不再误报。
//  4) 新增速度自适应安全车距（FCW）：所需距离 = v·1s + v²/(2·6) ，按占比分三级。
import Foundation

enum AlertLevel: Int {
    case info = 1, warn = 2, danger = 3
}

struct Alert {
    let key: String
    let text: String
    let level: AlertLevel
}

struct LightReport {
    let id: String
    let color: LightColor
    let conf: Double
    let dist: Double?     // 米，nil = 测不出
    let xm: Double?       // 横向偏移（米）
    let box: [Double]
}

struct SceneCtx {
    var w: Double
    var h: Double
    var ego: EgoSpeed?
    var lights: [LightReport] = []
}

struct SceneTrack {
    let track: Track
    let dist: Double
}

struct SceneState {
    var ts: Double = 0
    var leadId: Int? = nil
    var leadDist: Double = .nan
    var leadClosing: Double = 0
    var leadTtc: Double = .infinity
    var leadSpeed: Double? = nil
    var leadRelAcc: Double = 0
    var leadBraking = false
    var tailRatio: Double = 0
    var fcwNeedM: Double = .nan
    var fcwRatio: Double = .nan
    var headway: Double? = nil
    var egoV: Double? = nil
    var egoOk = false
    var egoA: Double = 0
    var pedNear: Double = .nan
    var pedCount = 0
    var cutinId: Int? = nil
    var light: LightColor = .unknown
    var lightDist: Double? = nil
    var nLight: Int = 0
    var nTracks: Int = 0
    var alerts: [Alert] = []
    var worst: String = "ok"
    // 供 HUD 画
    var narrowCorridor: [Vec2] = []
    var wideCorridor: [Vec2] = []
    var tracks: [SceneTrack] = []
}

final class RulesEngine {
    /// 安装几何。Engine 会在俯仰角/焦距/安装高变化时整体替换，
    /// 替换后必须让走廊多边形缓存失效（走廊是用 project() 算出来的，依赖这些参数）。
    var calib: Calib {
        didSet { cacheW = -1; cacheH = -1 }
    }
    var th: Thresholds
    private var cacheW: Double = 0, cacheH: Double = 0
    private var narrowCache: [Vec2] = []
    private var wideCache: [Vec2] = []

    // 刹车
    private var brakeBase: [Int: Double] = [:]
    private var brakeStreak: [Int: Int] = [:]
    private var brakeCool: [Int: Double] = [:]
    // 信号灯
    private var lightSaid: Set<String> = []
    private var lightHold: (alert: Alert, until: Double)? = nil
    // 插队：走廊状态迁移
    private struct CorrState { var inNarrow: Bool; var streak: Int; var lastOut: Double; var inSince: Double }
    private var corr: [Int: CorrState] = [:]
    private var cutStreak: [Int: Int] = [:]
    private var cutCool: [Int: Double] = [:]

    init(calib: Calib, th: Thresholds = .default) {
        self.calib = calib
        self.th = th
    }

    private func corridors(_ w: Double, _ h: Double) {
        if cacheW != w || cacheH != h {
            var c = calib
            c.fit(w, h)
            narrowCache = laneCorridor(c, halfW: 1.75)
            wideCache = laneCorridor(c, halfW: 2.6)
            cacheW = w; cacheH = h
        }
    }

    func update(_ tracks: [Track], _ ts: Double, _ ctx: SceneCtx) -> SceneState {
        let w = ctx.w, h = ctx.h
        corridors(w, h)
        let th = self.th
        let ego = ctx.ego
        var alerts: [Alert] = []

        ego?.at(ts)

        // 定标副本（Calib 是 struct，必须本地 fit 后再用，否则 fx/fy 全是初值 1）
        var c = calib
        c.fit(w, h)

        // ---- 1) 逐目标测距 ----
        var info: [Int: Bool] = [:]
        var scene = SceneState(ts: ts)
        for tr in tracks where tr.misses == 0 {
            // 信号灯不套用车辆尺寸/地面法测距（量纲完全不同），距离由 LightTracker 单独算
            if tr.name == "traffic light" {
                scene.tracks.append(SceneTrack(track: tr, dist: .nan))
                continue
            }
            let r = estimateDistance(tr.box.arr, tr.name, c, th)
            info[tr.tid] = r.d.isFinite
            tr.d = r.d
            if r.d.isFinite { tr.push(ts, r.d, w) }
            scene.tracks.append(SceneTrack(track: tr, dist: r.d))
        }
        scene.nTracks = scene.tracks.count

        let vehicles: Set<String> = ["car", "truck", "bus", "motorcycle"]
        var live: [Track] = []
        for tr in tracks where tr.misses == 0 && info[tr.tid] == true { live.append(tr) }

        // ---- 2) 前车：本车道走廊内最近的机动车 ----
        var lead: Track? = nil
        var leadD = Double.infinity
        for tr in live where vehicles.contains(tr.name) {
            if !pointInPolygon(tr.box.bottomCenter, narrowCache) { continue }
            if tr.d < leadD { lead = tr; leadD = tr.d }
        }

        scene.narrowCorridor = narrowCache
        scene.wideCorridor = wideCache
        scene.egoV = ego?.ok == true ? ego?.v : nil
        scene.egoOk = ego?.ok == true
        scene.egoA = ego?.a ?? 0

        // ---- 3) 前车：刹车识别 + 速度自适应车距 ----
        if let lead = lead {
            var closing = lead.closingSpeed()
            if abs(closing) > th.maxRelSpeed { closing = 0 }
            let ttc = closing > 0.5 ? leadD / closing : .infinity
            let mature = lead.hits >= th.minTrackFrames
            let near = leadD <= th.ttcMaxRangeM

            // (a) 尾灯：亮红像素占比相对基线突增
            var tail = false
            var tailRatio = 0.0
            if let rr = tailRatioProvider?(lead.box.arr) {
                tailRatio = rr
                let base = brakeBase[lead.tid] ?? rr
                brakeBase[lead.tid] = base + (rr - base) * 0.15      // ~7 帧基线
                if lead.box.height >= th.brakeTailMinH {
                    tail = rr >= th.brakeTailRatio
                        || (rr > max(0.012, base * th.brakeTailBurst) && rr > 0.012)
                }
            }
            let relAcc = lead.accel()

            // (b) GPS：前车绝对速度 / 绝对减速度
            var leadSpeed: Double? = nil
            var leadDecel: Double? = nil
            if let ego = ego, ego.ok, near, mature {
                leadSpeed = ego.v - closing
                leadDecel = -(ego.a - relAcc)
            }

            // (c) 三路证据融合
            var byMotion = false, byTail = false, byGps = false
            if mature && near {
                let gpsAvail = (ego?.ok == true) && ((ego?.v ?? 0) >= th.brakeGpsMinSpeed)
                if gpsAvail, let ld = leadDecel {
                    // 有 GPS：用绝对减速度判定；自车明显在加速时不再把"接近变快"赖到前车头上
                    byGps = ld > th.brakeAbsDecelMs2
                    byMotion = (ego?.a ?? 0) < 0.8
                        && relAcc > th.brakeRelAccMs2 && closing > th.brakeClosingMps
                } else {
                    byMotion = relAcc > th.brakeRelAccMs2 && closing > th.brakeClosingMps
                }
                byTail = tail && closing > th.brakeClosingMps * 0.3
            }
            var hardBrake = byMotion || byTail || byGps

            // 连续 2 帧确认，避免单帧噪声
            if hardBrake {
                let st = (brakeStreak[lead.tid] ?? 0) + 1
                brakeStreak[lead.tid] = st
                hardBrake = st >= th.brakeConfirm
            } else {
                brakeStreak.removeValue(forKey: lead.tid)
            }
            if hardBrake {
                let until = brakeCool[lead.tid] ?? 0
                if ts < until { hardBrake = false }
                else { brakeCool[lead.tid] = ts + th.brakeCooldownS }
            }

            scene.leadId = lead.tid
            scene.leadDist = leadD
            scene.leadClosing = closing
            scene.leadTtc = ttc
            scene.leadSpeed = leadSpeed
            scene.leadRelAcc = relAcc
            scene.tailRatio = tailRatio
            scene.leadBraking = hardBrake

            if hardBrake {
                alerts.append(Alert(key: "brake", text: "前车刹车！", level: .danger))
            }

            // TTC 兜底
            if mature && near && ttc <= th.ttcDangerS {
                alerts.append(Alert(key: "ttc", text: String(format: "追尾风险 %.1f秒", ttc), level: .danger))
            } else if mature && near && ttc <= th.ttcWarnS {
                alerts.append(Alert(key: "ttc", text: String(format: "车距收缩 %.1f秒", ttc), level: .warn))
            }

            // ---- 速度自适应安全车距（FCW 核心）----
            if mature {
                if let ego = ego, ego.ok, ego.v > 3 {
                    let v = ego.v
                    // 所需距离 = 反应距离 + 制动距离 + 接近速度补偿
                    let need = v * th.fcwReactS + v * v / (2 * th.fcwDecelMs2) + max(0, closing) * 0.5
                    let ratio = leadD / max(need, 1)
                    scene.fcwNeedM = need
                    scene.fcwRatio = ratio
                    scene.headway = leadD / max(v, 1e-3)
                    if ratio < th.fcwDangerRatio {
                        alerts.append(Alert(key: "fcw",
                                            text: String(format: "车距不足 %.0f米，立即刹车", leadD),
                                            level: .danger))
                    } else if ratio < th.fcwWarnRatio {
                        alerts.append(Alert(key: "fcw",
                                            text: String(format: "车距过近 %.0f米，提前减速", leadD),
                                            level: .warn))
                    } else if ratio < th.fcwInfoRatio && closing > 0.3 {
                        alerts.append(Alert(key: "fcw",
                                            text: String(format: "注意车距 %.0f米", leadD),
                                            level: .info))
                    }
                } else {
                    // 无 GPS：退回固定距离阈值
                    if leadD <= th.followDangerM && closing > 1.0 {
                        alerts.append(Alert(key: "fcw", text: String(format: "跟车过近 %.0f米", leadD), level: .warn))
                    } else if leadD <= th.followWarnM && closing > 1.0 {
                        alerts.append(Alert(key: "fcw", text: String(format: "注意车距 %.0f米", leadD), level: .info))
                    }
                }
            }
        }

        // ---- 4) 行人 ----
        var peds: [Track] = []
        for tr in live where tr.name == "person" {
            if !pointInPolygon(tr.box.bottomCenter, wideCache) { continue }
            peds.append(tr)
        }
        if !peds.isEmpty {
            peds.sort { $0.d < $1.d }
            let nearTr = peds[0], nd = nearTr.d
            scene.pedCount = peds.count
            scene.pedNear = nd
            let lat = abs(nearTr.lateralMps(nd, c.fx, w))
            var lvl: AlertLevel? = nil
            var txt = ""
            if nd <= th.pedCriticalM { lvl = .danger; txt = String(format: "行人逼近 %.1f米 立即减速", nd) }
            else if nd <= th.pedDangerM { lvl = .danger; txt = String(format: "前方行人 %.0f米", nd) }
            else if nd <= th.pedWarnM { lvl = lat > 0.3 ? .warn : .info; txt = String(format: "注意行人 %.0f米", nd) }
            if let lvl = lvl { alerts.append(Alert(key: "ped", text: txt, level: lvl)) }
        }

        // ---- 5) 插队：走廊状态迁移 + 横向速度 ----
        updateCutIn(&scene, &alerts, live: live, c: c, w: w, ts: ts, ego: ego)

        // ---- 6) 信号灯 ----
        scene.nLight = ctx.lights.count
        if let L = ctx.lights.first, let dist = L.dist,
           dist >= th.lightMinM && dist <= th.lightMaxM {
            scene.light = L.color
            scene.lightDist = dist
            let moving = ego?.ok == true ? (ego?.v ?? 0) > 3 : true
            let dTxt = String(format: " %.0f米", dist)
            if lightSaid.count > 24 { lightSaid.removeAll() }
            let key = L.id + ":" + L.color.rawValue
            if !lightSaid.contains(key) {
                lightSaid.insert(key)
                var a: Alert? = nil
                switch L.color {
                case .red:
                    a = Alert(key: "light", text: "前方红灯" + dTxt + (moving ? "，准备停车" : ""),
                              level: moving ? .danger : .warn)
                case .yellow:
                    if moving { a = Alert(key: "light", text: "前方黄灯" + dTxt + "，注意减速", level: .warn) }
                case .green:
                    a = Alert(key: "light", text: "绿灯" + dTxt + "，通行", level: .info)
                case .unknown:
                    break
                }
                if let a = a {
                    alerts.append(a)
                    lightHold = (a, ts + 4)
                }
            } else if let hold = lightHold, ts < hold.until {
                alerts.append(hold.alert)
            }
        }

        alerts.sort { $0.level.rawValue > $1.level.rawValue }
        scene.alerts = alerts
        scene.worst = alerts.first?.level == .danger ? "danger"
            : (alerts.first?.level == .warn ? "warn" : (alerts.isEmpty ? "ok" : "info"))
        return scene
    }

    /// 插队判定：
    /// 旁车道车辆的 bottom-center 本来就在走廊外，永远不满足"状态迁移"，因此不会误报。
    /// 真插入的车：曾稳定跟踪(hits≥8) → 最近 2 秒内从走廊外进入 → 连续 2 帧在内 → 横向速度朝本车轴。
    private func updateCutIn(_ scene: inout SceneState, _ alerts: inout [Alert],
                             live: [Track], c: Calib, w: Double, ts: Double, ego: EgoSpeed?) {
        let th = self.th
        // 低速（走走停停/等灯）不判插队
        if ego?.ok == true && (ego?.v ?? 0) < th.lowSpeedMps { return }

        // 场景整体横移（转弯时所有车横向同步漂移）→ 扣掉
        var flows: [Double] = []
        for tr in live where tr.d <= th.cutinMaxM {
            let lm = tr.lateralMps(tr.d, c.fx, w)
            if lm.isFinite { flows.append(lm) }
        }
        let flow = flows.count >= 3 ? median(flows) : 0

        var best: (Track, Double)? = nil
        var seen = Set<Int>()
        for tr in live {
            seen.insert(tr.tid)
            let inNarrow = pointInPolygon(tr.box.bottomCenter, narrowCache)
            let prev = corr[tr.tid]
            var st = prev ?? CorrState(inNarrow: inNarrow, streak: inNarrow ? 1 : 0,
                                       lastOut: inNarrow ? -999 : ts, inSince: inNarrow ? ts : -999)
            if inNarrow {
                st.streak += 1
                if !st.inNarrow { st.inSince = ts }
            } else {
                st.streak = 0
                st.lastOut = ts
            }
            st.inNarrow = inNarrow
            corr[tr.tid] = st

            guard inNarrow, st.streak >= 1 else { continue }
            guard tr.hits >= th.cutinMinHits else { continue }                    // 新型检测不算插入
            guard ts - st.lastOut <= th.cutinEnterWindowS else { continue }        // 必须"刚进来"
            guard tr.d <= th.cutinMaxM else { continue }

            let lat = tr.lateralMps(tr.d, c.fx, w) - flow
            let off = tr.box.bottomCenter.x - c.cx
            guard abs(lat) > th.cutinLateralMps else { continue }                  // 横向速度不够
            guard off * lat < 0 else { continue }                                  // 必须朝本车轴移动

            if best == nil || tr.d < best!.0.d { best = (tr, lat) }
        }
        // 清理过期状态
        if corr.count > 60 {
            corr = corr.filter { ts - $0.value.lastOut < 30 || $0.value.inNarrow }
        }

        guard let picked = best else {
            cutStreak.removeAll()
            return
        }
        let cut = picked.0
        let n = (cutStreak[cut.tid] ?? 0) + 1
        cutStreak[cut.tid] = n
        guard n >= th.cutinConfirm else { return }
        let until = cutCool[cut.tid] ?? 0
        guard ts >= until else { return }
        cutCool[cut.tid] = ts + th.cutinCooldownS

        var closing = cut.closingSpeed()
        if abs(closing) > th.maxRelSpeed { closing = 0 }
        let ttc = closing > 0.5 ? cut.d / closing : .infinity
        scene.cutinId = cut.tid
        let lvl: AlertLevel = (cut.d < 15 || ttc < 2.5) ? .danger : .warn
        var txt = String(format: "有车插入 %.0f米", cut.d)
        if ttc < 9 { txt += String(format: " TTC %.1f秒", ttc) }
        alerts.append(Alert(key: "cutin", text: txt, level: lvl))
    }

    /// 尾灯红像素占比由 Engine 注入（避免 RulesEngine 直接依赖像素缓冲）
    var tailRatioProvider: (([Double]) -> Double?)? = nil
}
