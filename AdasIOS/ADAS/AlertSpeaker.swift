// AlertSpeaker.swift — 中文语音播报（对应网页版 speechSynthesis）
import Foundation
import AVFoundation

final class AlertSpeaker {
    private let synth = AVSpeechSynthesizer()
    private var lastKey = ""
    private var lastAt: Double = -100
    private var lastAnyAt: Double = -100
    /// 语义组 → 上次播报时间（组内共享抑制窗口，防止规则层与安全层说同一件事时交替打断）
    private var lastGroup: [String: Double] = [:]

    /// 同一 key 在此间隔内不重复播报（秒）
    var repeatInterval: Double = 8
    /// 危险级允许更密集地重复（否则真危险时只喊一次就沉默）
    var dangerRepeat: Double = 3.0
    /// 任意两条播报之间的最小间隔，防止连环打断
    var minGap: Double = 1.2
    /// 危险级可以抢话（正在播的普通提示直接截断）
    var dangerGap: Double = 0.7

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// 语义分组：同一件事的不同措辞（规则层 "fcw" 与安全层 "s_lead_warn"）归到一组
    static func group(_ key: String) -> String {
        if key == "fcw" || key == "ttc" || key.hasPrefix("s_lead") || key == "s_free" {
            return "front"
        }
        if key == "cutin" || key.hasPrefix("s_side") { return "side" }
        if key == "brake" { return "brake" }
        if key == "ped" || key.hasPrefix("s_ped") { return "ped" }
        if key == "light" { return "light" }
        return key
    }

    /// 播报。正在播时报新告警会打断旧播报——安全场景宁可截断也不要延迟。
    func speak(_ alert: Alert, ts: Double) {
        let isDanger = alert.level == .danger
        let gap = isDanger ? dangerGap : minGap
        if ts - lastAnyAt < gap { return }
        if alert.key == lastKey && ts - lastAt < (isDanger ? dangerRepeat : repeatInterval) { return }

        let g = Self.group(alert.key)
        let window = isDanger ? dangerRepeat : repeatInterval * 0.7
        if let gAt = lastGroup[g], ts - gAt < window { return }

        lastKey = alert.key
        lastAt = ts
        lastAnyAt = ts
        lastGroup[g] = ts

        let u = AVSpeechUtterance(string: alert.text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceMaximumSpeechRate * 0.52
        u.volume = 1.0
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }
}
