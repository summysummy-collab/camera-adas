// SituationPanel.swift — v1.3 周边安全态势面板（俯视 BEV）
//
// 这是 v1.3 的产品核心：一块持续更新的"环境快照"，而不是等出事才弹的那句话。
// 自车在底部中央，向上是前方 0–40m；左右各画到 ±9m（约两条车道）。
// 目标按风险评估着色，虚线是 1.5 秒后的外推位置——看得见它"会去哪"。
import SwiftUI

struct SituationPanel: View {
    let world: SafetyWorld

    private let zMax = 40.0
    private let xMax = 9.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint(world.worst)).frame(width: 8, height: 8)
                Text(world.worst.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint(world.worst))
                Text(world.summary)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Canvas { ctx, size in
                draw(&ctx, size)
            }
            .frame(height: 148)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack(spacing: 12) {
                metric("时距", thwText, headwayTint)
                metric("碰撞", ttcText, ttcTint)
                metric("净空", String(format: "%.0fm", world.freeSpaceM), .white)
            }
        }
        .padding(9)
        .frame(width: 292)
        .background(Color.black.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - 数值

    private var lead: TargetState? { world.lead }

    private var thwText: String {
        guard let l = lead, l.thw.isFinite else { return "—" }
        return String(format: "%.1fs", l.thw)
    }
    private var ttcText: String {
        guard let l = lead else { return "—" }
        return l.ttc.isFinite ? String(format: "%.1fs", l.ttc) : "∞"
    }
    private var headwayTint: Color {
        guard let l = lead, l.thw.isFinite else { return .white.opacity(0.5) }
        if l.thw < 0.7 { return Color(red: 0.95, green: 0.30, blue: 0.28) }
        if l.thw < 1.2 { return Color(red: 0.98, green: 0.62, blue: 0.15) }
        return Color(red: 0.40, green: 0.85, blue: 0.60)
    }
    private var ttcTint: Color {
        guard let l = lead else { return .white.opacity(0.5) }
        if !l.ttc.isFinite { return .white.opacity(0.5) }
        if l.ttc < 1.8 { return Color(red: 0.95, green: 0.30, blue: 0.28) }
        if l.ttc < 3.0 { return Color(red: 0.98, green: 0.62, blue: 0.15) }
        return Color(red: 0.40, green: 0.85, blue: 0.60)
    }

    // MARK: - 绘制

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let sx = Double(size.width) / (2 * xMax)
        let sz = Double(size.height) / zMax
        func P(_ x: Double, _ z: Double) -> CGPoint {
            CGPoint(x: size.width / 2 + CGFloat(x * sx),
                    y: size.height - CGFloat(max(0, min(zMax, z)) * sz))
        }

        // 车道线：本车道实线、相邻车道分界虚线
        for (lx, dash) in [(-5.25, true), (-1.75, false), (1.75, false), (5.25, true)] {
            var p = Path()
            p.move(to: P(lx, 0))
            p.addLine(to: P(lx, zMax))
            ctx.stroke(p,
                       with: .color(.white.opacity(dash ? 0.22 : 0.55)),
                       style: StrokeStyle(lineWidth: dash ? 1 : 1.5,
                                          dash: dash ? [4, 5] : []))
        }
        // 本车道填充
        var lane = Path()
        lane.move(to: P(-1.75, 0))
        lane.addLine(to: P(1.75, 0))
        lane.addLine(to: P(1.75, zMax))
        lane.addLine(to: P(-1.75, zMax))
        lane.closeSubpath()
        ctx.fill(lane, with: .color(.white.opacity(0.05)))

        // 距离刻度
        for d in stride(from: 10.0, through: 30.0, by: 10.0) {
            var p = Path()
            p.move(to: P(-xMax, d))
            p.addLine(to: P(xMax, d))
            ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
            ctx.draw(Text("\(Int(d))m")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundColor(.white.opacity(0.35)),
                     at: CGPoint(x: 12, y: P(0, d).y))
        }

        // 目标
        for t in world.targets where t.z > 0.5 && t.z < zMax && abs(t.x) < xMax {
            let c = tint(t.level)
            let wPx = CGFloat(max(6, t.wM * sx))
            let hPx = CGFloat(max(7, min(14, 4.5 * sz)))
            let ctr = P(t.x, t.z)
            let rect = CGRect(x: ctr.x - wPx / 2, y: ctr.y - hPx / 2, width: wPx, height: hPx)
            let r = Path(roundedRect: rect, cornerRadius: 2)
            ctx.fill(r, with: .color(c.opacity(t.lane == 0 ? 0.75 : 0.35)))
            ctx.stroke(r, with: .color(c), lineWidth: t.lane == 0 ? 1.2 : 0.7)
            if t.lane == 0 {
                ctx.draw(Text(String(format: "%.0f", t.z))
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundColor(.white.opacity(0.85)),
                         at: CGPoint(x: ctr.x, y: ctr.y - hPx / 2 - 6))
            }
            // 1.5 秒外推
            if t.level >= .watch || t.lane == 0 {
                let end = P(t.x + t.vx * 1.5, max(0, t.z - t.vz * 1.5))
                var p = Path()
                p.move(to: ctr)
                p.addLine(to: end)
                ctx.stroke(p, with: .color(c.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }

        // 自车
        let base = P(0, 0.2)
        var ego = Path()
        ego.move(to: CGPoint(x: base.x, y: base.y - 11))
        ego.addLine(to: CGPoint(x: base.x - 7, y: base.y + 3))
        ego.addLine(to: CGPoint(x: base.x + 7, y: base.y + 3))
        ego.closeSubpath()
        ctx.fill(ego, with: .color(.white.opacity(0.9)))
    }

    private func tint(_ lv: RiskLevel) -> Color {
        switch lv {
        case .clear:  return Color(red: 0.40, green: 0.85, blue: 0.60)
        case .watch:  return Color(red: 0.95, green: 0.85, blue: 0.35)
        case .warn:   return Color(red: 0.98, green: 0.62, blue: 0.15)
        case .danger: return Color(red: 0.95, green: 0.30, blue: 0.28)
        }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
