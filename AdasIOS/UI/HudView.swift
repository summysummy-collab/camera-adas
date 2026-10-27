// HudView.swift — HUD 覆盖层：走廊、检测框、信号灯、告警条、状态栏
import SwiftUI

struct HudView: View {
    let scene: SceneState
    let fps: Double
    let inferMs: Double
    let gpsOk: Bool
    let gpsSpeed: Double
    let gpsSrc: String
    var debugLine: String = ""
    /// v1.4：规则 + 安全层仲裁后的当前告警（nil 时退回 scene.alerts.first）
    var liveAlert: Alert? = nil

    var body: some View {
        GeometryReader { geo in
            // 工作区 640x384，内容区 640x360（letterbox 12px），映射到预览内容矩形
            let m = Mapping(geo: geo.size)
            ZStack {
                // 走廊
                Path { p in
                    p.move(to: m.pt(scene.wideCorridor.first ?? .zero))
                    for v in scene.wideCorridor.dropFirst() { p.addLine(to: m.pt(v)) }
                    p.closeSubpath()
                }.stroke(Color.orange.opacity(0.35), lineWidth: 1.5)
                Path { p in
                    p.move(to: m.pt(scene.narrowCorridor.first ?? .zero))
                    for v in scene.narrowCorridor.dropFirst() { p.addLine(to: m.pt(v)) }
                    p.closeSubpath()
                }.stroke(Color.yellow.opacity(0.8), lineWidth: 2)

                // 检测框
                ForEach(scene.tracks, id: \.track.tid) { pair in
                    let tr = pair.track
                    let r = m.rect(tr.box)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(color(for: tr), lineWidth: tr.tid == scene.leadId ? 2.5 : 1.2)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    Text(label(tr, pair.dist))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(color(for: tr).opacity(0.75))
                        .position(x: r.midX, y: max(r.minY - 8, 12))
                }

                // 信号灯
                if scene.light != .unknown, let d = scene.lightDist {
                    Text(lightText(d))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(lightColor))
                        .position(x: geo.size.width / 2, y: geo.size.height - 86)
                }

                // 告警条（v1.4：优先用仲裁结果，规则与安全层不会各说一句）
                if let a = (liveAlert ?? scene.alerts.first) {
                    Text(a.text)
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(alertColor(a.level)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(a.level == .danger ? 0.9 : 0),
                                        lineWidth: 2)
                        )
                        .position(x: geo.size.width / 2, y: 46)
                        .transition(.move(edge: .top))
                }

                // 危险级：画面四周加红边，余光也能看见（不用盯着中间）
                if let a = liveAlert, a.level == .danger {
                    Rectangle()
                        .strokeBorder(Color.red.opacity(0.75), lineWidth: 6)
                        .ignoresSafeArea()
                }

                // 状态栏
                HStack(spacing: 12) {
                    Text(String(format: "%.0ffps %.0fms", fps, inferMs))
                    Text(gpsOk
                         ? String(format: "GPS %.0fkm/h (%@)", gpsSpeed * 3.6, gpsSrc)
                         : "GPS 无")
                }
                .font(.system(size: 10))
                .foregroundColor(gpsOk ? Color.green.opacity(0.9) : Color.red.opacity(0.9))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(8)

                // 诊断行（右下角小字）：用来定位"为什么没报"
                if !debugLine.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(debugLine)
                        if scene.fcwRatio.isFinite {
                            Text(String(format: "FCW 实际%.0fm / 所需%.0fm = %.2f",
                                        scene.leadDist, scene.fcwNeedM, scene.fcwRatio))
                        }
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.42)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
                }
            }
        }
        .allowsHitTesting(false)
    }

    struct Mapping {
        let scale: Double
        let ox: Double
        let oy: Double

        init(geo: CGSize) {
            let cw = 640.0, ch = 360.0
            let s = min(geo.width / cw, geo.height / ch)
            scale = s
            ox = (Double(geo.width) - cw * s) / 2
            oy = (Double(geo.height) - ch * s) / 2
        }

        func pt(_ v: Vec2) -> CGPoint {
            CGPoint(x: ox + v.x * scale, y: oy + (v.y - 12) * scale)   // -12: 去掉上 letterbox
        }
        func rect(_ b: Box) -> CGRect {
            let p1 = pt(Vec2(x: b.x1, y: b.y1))
            let p2 = pt(Vec2(x: b.x2, y: b.y2))
            return CGRect(x: p1.x, y: p1.y, width: p2.x - p1.x, height: p2.y - p1.y)
        }
    }

    private func color(for tr: Track) -> Color {
        if tr.tid == scene.leadId { return .yellow }
        switch tr.name {
        case "person": return .cyan
        case "traffic light": return .purple
        default: return Color.green.opacity(0.85)
        }
    }

    private func label(_ tr: Track, _ d: Double) -> String {
        let cn: [String: String] = [
            "person": "行人", "car": "汽车", "truck": "卡车", "bus": "公交",
            "motorcycle": "摩托", "bicycle": "自行车", "traffic light": "信号灯",
        ]
        var s = cn[tr.name] ?? tr.name
        if d.isFinite { s += String(format: " %.0fm", d) }
        return s
    }

    private func lightText(_ d: Double) -> String {
        let n: [LightColor: String] = [.red: "红灯", .yellow: "黄灯", .green: "绿灯", .unknown: ""]
        return (n[scene.light] ?? "") + String(format: " %.0f米", d)
    }

    private var lightColor: Color {
        switch scene.light {
        case .red: return .red
        case .yellow: return .orange
        case .green: return .green
        case .unknown: return .gray
        }
    }

    private func alertColor(_ l: AlertLevel) -> Color {
        switch l {
        case .danger: return .red
        case .warn: return .orange
        case .info: return .blue
        }
    }
}
