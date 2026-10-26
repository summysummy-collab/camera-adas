// Thresholds.swift — 告警阈值（v1.1：修正 iOS 实测反馈）
import Foundation

struct Thresholds {
    // ---- 跟车 / 距离 ----
    var followWarnM = 25.0
    var followDangerM = 12.0
    var ttcWarnS = 3.0
    var ttcDangerS = 1.8
    var ttcMaxRangeM = 45.0
    var maxRelSpeed = 25.0
    var minTrackFrames = 4
    var minValid = 2.5
    var maxValid = 120.0
    var conf = 0.35
    var lowSpeedMps = 1.5

    // ---- 前车刹车（三路证据融合，任一成立即可）----
    var brakeClosingMps = 1.0       // 相对接近速度下限（m/s）
    var brakeRelAccMs2 = 2.2        // 相对接近加速度门限（m/s²）
    var brakeAbsDecelMs2 = 2.8      // 有 GPS 时：前车绝对减速度门限
    var brakeTailRatio = 0.020      // 尾灯亮红像素占比绝对门限
    var brakeTailBurst = 1.7        // 相对基线的突增倍数
    var brakeTailMinH = 14.0        // 框高至少这么多像素才判尾灯（更远不可靠）
    var brakeConfirm = 2            // 连续 N 帧确认
    var brakeCooldownS = 2.5        // 播报后静默期
    var brakeGpsMinSpeed = 3.0      // 自车速度低于此不做绝对减速度判断

    // ---- 速度自适应安全车距（FCW）----
    var fcwReactS = 1.0             // 反应时间
    var fcwDecelMs2 = 6.0           // 假定可用制动减速度
    var fcwDangerRatio = 0.60       // 实际距离/所需距离 < 0.60 → 立即刹车
    var fcwWarnRatio = 0.85         // < 0.85 → 提前减速
    var fcwInfoRatio = 1.10         // < 1.10 → 保持车距

    // ---- 行人 ----
    var pedWarnM = 30.0
    var pedDangerM = 18.0
    var pedCriticalM = 8.0

    // ---- 插队（改为"进入走廊的状态迁移"判据）----
    var cutinMaxM = 30.0
    var cutinMinHits = 8            // 必须是被稳定跟踪过的车，才可能"插入"
    var cutinEnterWindowS = 2.0     // 最近 N 秒内刚从走廊外进入
    var cutinLateralMps = 0.7       // 横向速度（m/s）朝本车道
    var cutinConfirm = 2            // 连续 N 帧确认
    var cutinCooldownS = 3.0

    // ---- 信号灯 ----
    var lightMinM = 2.0
    var lightMaxM = 80.0

    var headwayWarnS = 1.2
    var headwayDangerS = 0.7

    static let `default` = Thresholds()
}
