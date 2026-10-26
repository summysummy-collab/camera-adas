// Rules.swift — 告警规则引擎（移植 mobile/rules.js RulesEngine）
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
    var leadBraking = false
    var headway: Double? = nil
    var egoV: Double? = nil
    var egoOk = false
    var pedNear: Double = .nan
    var pedCount = 0
    var cutinId: Int? = nil
    var light: LightColor = .unknown
    var lightDist: Double? = nil
    var alerts: [Alert] = []
    var worst: String = "ok"
    // 供 HUD 画
    var narrowCorridor: [Vec2] = []
    var wideCorridor: [Vec2] = []
    var tracks: [SceneTrack] = []
}

final class RulesEngine {
    let calib: Calib
    let th: Thresholds
    private var cacheW: Double = 0, cacheH: Double = 0
    private var narrowCache: [Vec2] = []
    private var wideCache: [Vec2] = []
    private var brakeBase: [Int: Double] = [:]
    private var brakeStreak: [Int: Int] = [:]
    private var brakeCool: [Int: Double] = [:]
    private var lightSaid: Set<String> = []
    private var lightHold: (alert: Alert, until: Double)? = nil

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

        // ---- 1) 逐目标测距 ----
        var info: [Int: Bool] = [:]
        var scene = SceneState(ts: ts)
        var c = calib
        c.fit(w, h)
        for tr in tracks where tr.misses == 0 {
            let r = estimateDistance(tr.box.arr, tr.name, c, th)
            info[tr.tid] = r.d.isFinite
            tr.d = r.d
            if r.d.isFinite { tr.push(ts, r.d, w) }
            scene.tracks.append(SceneTrack(track: tr, dist: r.d))
        }

        // ---- 2) 前车：走廊内最近的机动车 ----
        let vehicles: Set<String> = ["car", "truck", "bus", "motorcycle"]
        var lead: Track? = nil
        var leadD = Double.infinity
        for tr in tracks where tr.misses == 0 && vehicles.contains(tr.name) {
            guard info[tr.tid] == true else { continue }
            if !pointInPolygon(tr.box.bottomCenter, narrowCache) { continue }
            if tr.d < leadD { lead = tr; leadD = tr.d }
        }

        scene.narrowCorridor = narrowCache
        scene.wideCorridor = wideCache
        scene.egoV = ego?.ok == true ? ego?.v : nil
        scene.egoOk = ego?.ok == true

        // ---- 3) 前车相关 ----
        if let lead = lead {
            var closing = lead.closingSpeed()
            if abs(closing) > th.maxRelSpeed { closing = 0 }
            let ttc = closing > 0.5 ? leadD / closing : .infinity
            let mature = lead.hits >= th.minTrackFrames
            let near = leadD <= th.ttcMaxRangeM

            // 尾灯：亮红像素占比突增（由 Engine 通过尾灯回调喂入）
            var tail = false
            if let rr = tailRatioProvider?(lead.box.arr) {
                let base = brakeBase[lead.tid] ?? rr
                brakeBase[lead.tid] = 0.9 * base + 0.1 * rr
                tail = rr > max(0.03, base * 1.6) && rr > 0.05
            }

            let relAcc = lead.accel()

            // GPS 融合：前车绝对速度 / 绝对减速度
            var leadSpeed: Double? = nil, leadDecel: Double? = nil
            if let ego = ego, ego.ok, near, mature {
                leadSpeed = ego.v - closing
                leadDecel = -(ego.a - relAcc)
            }

            var hardBrake = false
            if mature && near {
                if let ld = leadDecel, let ls = leadSpeed, ego?.v ?? 0 > 3 {
                    hardBrake = ld > th.brakeAbsDecelMs2 && (tail || closing > 1.0)
                } else {
                    hardBrake = (relAcc > th.brakeDecelMs2 && closing > 2.0) || (tail && closing > 2.0)
                }
            }
            // 持续性确认：连续 2 帧才认；报过 3 秒内不重复
            if hardBrake {
                if brakeStreak.count > 40 { brakeStreak.removeAll() }
                let st = (brakeStreak[lead.tid] ?? 0) + 1
                brakeStreak[lead.tid] = st
                hardBrake = st >= 2
            } else if !brakeStreak.isEmpty {
                brakeStreak.removeValue(forKey: lead.tid)
            }
            if hardBrake {
                let until = brakeCool[lead.tid] ?? 0
                if ts < until { hardBrake = false }
                else { brakeCool[lead.tid] = ts + 3 }
            }

            scene.leadId = lead.tid
            scene.leadDist = leadD
            scene.leadClosing = closing
            scene.leadTtc = ttc
            scene.leadSpeed = leadSpeed
            scene.leadBraking = hardBrake

            if mature && near && ttc <= th.ttcDangerS {
                alerts.append(Alert(key: "ttc", text: String(format: "前车急近 TTC %.1f秒 追尾风险", ttc), level: .danger))
            } else if mature && near && ttc <= th.ttcWarnS {
                alerts.append(Alert(key: "ttc", text: String(format: "车距收缩 TTC %.1f秒", ttc), level: .warn))
            }

            if hardBrake {
                alerts.append(Alert(key: "brake", text: "前车刹车！", level: .danger))
            } else if mature, let ego = ego, ego.ok, ego.v > 4 {
                let hw = leadD / max(ego.v, 1e-3)
                scene.headway = hw
                if hw <= th.headwayDangerS && closing > 0.5 {
                    alerts.append(Alert(key: "follow", text: String(format: "跟车过近 %.0f米 / %.1f秒", leadD, hw), level: .warn))
                } else if hw <= th.headwayWarnS && closing > 0.5 {
                    alerts.append(Alert(key: "follow", text: String(format: "注意车距 %.0f米", leadD), level: .info))
                }
            } else if mature {
                if leadD <= th.followDangerM && closing > 1.0 {
                    alerts.append(Alert(key: "follow", text: String(format: "跟车过近 %.0f米", leadD), level: .warn))
                } else if leadD <= th.followWarnM && closing > 1.0 {
                    alerts.append(Alert(key: "follow", text: String(format: "注意车距 %.0f米", leadD), level: .info))
                }
            }
        }

        // ---- 4) 行人 ----
        var peds: [Track] = []
        for tr in tracks where tr.misses == 0 && tr.name == "person" {
            guard info[tr.tid] == true else { continue }
            if !pointInPolygon(tr.box.bottomCenter, wideCache) { continue }
            peds.append(tr)
        }
        if !peds.isEmpty {
            peds.sort { $0.d < $1.d }
            let nearTr = peds[0], nd = nearTr.d
            scene.pedCount = peds.count
            scene.pedNear = nd
            let lat = abs(nearTr.lateralSpeed())
            var lvl: AlertLevel? = nil
            var txt = ""
            if nd <= th.pedCriticalM { lvl = .danger; txt = String(format: "行人逼近 %.1f米 立即减速", nd) }
            else if nd <= th.pedDangerM { lvl = .danger; txt = String(format: "前方行人 %.0f米", nd) }
            else if nd <= th.pedWarnM { lvl = lat > 0.05 ? .warn : .info; txt = String(format: "注意行人 %.0f米", nd) }
            if let lvl = lvl { alerts.append(Alert(key: "ped", text: txt, level: lvl)) }
        }

        // ---- 5) 插队 ----
        if !(ego?.ok == true && (ego?.v ?? 0) < th.lowSpeedMps) {
            var lats: [Double] = []
            for tr in tracks where tr.misses == 0 && vehicles.contains(tr.name) && info[tr.tid] == true {
                lats.append(tr.lateralSpeed())
            }
            lats.sort()
            let latFlow = lats.count >= 3 ? lats[(lats.count - 1) / 2] : 0

            var cut: Track? = nil
            for tr in tracks where tr.misses == 0 && vehicles.contains(tr.name) {
                guard info[tr.tid] == true else { continue }
                if tr.d > th.cutinMaxM { continue }
                if !pointInPolygon(tr.box.bottomCenter, narrowCache) { continue }
                let lat = tr.lateralSpeed() - latFlow
                if abs(lat) < 0.01 { continue }
                let off = tr.box.bottomCenter.x - c.cx
                if off * lat >= -1e-4 { continue }
                let isNew = tr.hits <= th.cutinAgeFrames
                let toward = abs(lat) > th.cutinLateralSpeed
                if isNew || toward { cut = tr; break }
            }
            if let cut = cut {
                let d = cut.d
                var closing = cut.closingSpeed()
                if abs(closing) > th.maxRelSpeed { closing = 0 }
                let ttc = closing > 0.5 ? d / closing : .infinity
                scene.cutinId = cut.tid
                let lvl: AlertLevel = d < 15 || ttc < 2.5 ? .danger : .warn
                var txt = String(format: "有车插入 %.0f米", d)
                if ttc < 9 { txt += String(format: " TTC %.1f秒", ttc) }
                alerts.append(Alert(key: "cutin", text: txt, level: lvl))
            }
        }

        // ---- 6) 信号灯 ----
        if let L = ctx.lights.first {
            if let dist = L.dist, dist > 2 && dist <= 60 {
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
                        lightHold = (a, ts + 4)   // 告警条保持 4 秒
                    }
                } else if let hold = lightHold, ts < hold.until {
                    alerts.append(hold.alert)
                }
            }
        }

        alerts.sort { $0.level.rawValue > $1.level.rawValue }
        scene.alerts = alerts
        scene.worst = alerts.first?.level == .danger ? "danger" : (alerts.first?.level == .warn ? "warn" : (alerts.isEmpty ? "ok" : "info"))
        return scene
    }

    /// 尾灯红像素占比由 Engine 注入（避免 RulesEngine 直接依赖像素缓冲）
    var tailRatioProvider: (([Double]) -> Double?)? = nil
}
