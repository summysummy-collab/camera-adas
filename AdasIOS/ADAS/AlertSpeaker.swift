// AlertSpeaker.swift — 中文语音播报（对应网页版 speechSynthesis）
import Foundation
import AVFoundation

final class AlertSpeaker {
    private let synth = AVSpeechSynthesizer()
    private var lastKey = ""
    private var lastAt: Double = -100
    /// 同一 key 在此间隔内不重复播报（秒）
    var repeatInterval: Double = 8

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// 播报最高级告警。正在播报时排队会让新告警延迟，直接打断旧播报更符合安全场景。
    func speak(_ alert: Alert, ts: Double) {
        if alert.key == lastKey && ts - lastAt < repeatInterval { return }
        lastKey = alert.key
        lastAt = ts
        let u = AVSpeechUtterance(string: alert.text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceMaximumSpeechRate * 0.52
        u.volume = 1.0
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }
}
