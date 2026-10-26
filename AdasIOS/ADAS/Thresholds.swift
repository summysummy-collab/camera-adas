// Thresholds.swift — 告警阈值（与 mobile/adas.js DEFAULT_TH 完全一致）
import Foundation

struct Thresholds {
    var followWarnM = 25.0
    var followDangerM = 12.0
    var ttcWarnS = 3.0
    var ttcDangerS = 1.8
    var ttcMaxRangeM = 40.0
    var brakeDecelMs2 = 5.0        // 无 GPS：相对减速度门限
    var brakeAbsDecelMs2 = 3.5     // 前车绝对减速度门限（有 GPS 时）
    var maxRelSpeed = 25.0
    var minTrackFrames = 4
    var pedWarnM = 30.0
    var pedDangerM = 18.0
    var pedCriticalM = 8.0
    var cutinMaxM = 30.0
    var cutinLateralSpeed = 0.05
    var cutinAgeFrames = 20
    var minValid = 2.5
    var maxValid = 120.0
    var conf = 0.35
    var headwayWarnS = 1.2
    var headwayDangerS = 0.7
    var lowSpeedMps = 1.5

    static let `default` = Thresholds()
}
