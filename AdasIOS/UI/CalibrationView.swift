// CalibrationView.swift — 安装几何标定页（LiDAR 一键 + 手动微调）
import SwiftUI

struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lidar = LiDARCalibrator()
    @State private var cfg = MountConfig.load()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    HStack(alignment: .top, spacing: 16) {
                        arPanel
                        VStack(alignment: .leading, spacing: 10) {
                            lidarResultPanel
                            manualPanel
                        }
                    }

                    Text("说明：LiDAR 有效量程约 5 米，测不了 30 米外的跟车距离；但测距误差绝大部分来自"
                         + "「安装高度 / 俯仰角 / 焦距」这三个猜测值，用 LiDAR 在 3–6 米内把它们标定准，"
                         + "远处距离自然就准了。标定只需做一次，之后每次启动自动生效。")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { lidar.start() }
        .onDisappear { lidar.stop() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text("距离标定").font(.title3.bold()).foregroundColor(.white)
            Spacer()
            Text(cfg.summary).font(.caption).foregroundColor(.gray)
            Button("完成") { save() }
                .font(.body.bold())
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.9))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .padding(.leading, 10)
        }
    }

    // MARK: - AR 预览

    private var arPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                ARPreviewView(session: lidar.session, delegate: lidar)
                    .frame(width: 300, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                // 取景框提示：虚线框住画面下半部（LiDAR 采样区）
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundColor(lidar.hasLiDAR ? .yellow.opacity(0.8) : .gray.opacity(0.6))
                    .frame(width: 300 * 0.56, height: 200 * 0.47)
                    .offset(y: 200 * 0.235)
                VStack {
                    Spacer()
                    Text(lidar.hasLiDAR ? "LiDAR 采样区（3–6 米路面）" : "无 LiDAR：靠地面检测")
                        .font(.system(size: 10))
                        .foregroundColor(.yellow.opacity(0.9))
                        .padding(.bottom, 6)
                }
                .frame(width: 300, height: 200)
            }
            Text(lidar.status)
                .font(.caption)
                .foregroundColor(lidar.failed ? .orange : (lidar.done ? .green : .gray))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
        }
    }

    // MARK: - 标定结果

    private var lidarResultPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("重新标定") { lidar.start() }
                    .buttonStyle(.bordered)
                Button("填入下方参数") { applyLidar() }
                    .buttonStyle(.bordered)
                    .disabled(!lidar.done)
            }
            if lidar.done {
                row("安装高度", String(format: "%.2f m", lidar.heightM))
                row("俯仰角", String(format: "%.1f°", lidar.pitchDeg))
                if lidar.fovDeg.isFinite {
                    row("内参 FOV", String(format: "%.1f°", lidar.fovDeg))
                }
                if lidar.spreadM.isFinite {
                    row("样本离散度", String(format: "±%.02f m", lidar.spreadM))
                }
            } else {
                row("采样点", "\(lidar.sampleCount)")
                if lidar.livePitch.isFinite {
                    row("实时俯仰", String(format: "%.1f°", lidar.livePitch))
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundColor(.gray)
            Spacer()
            Text(v).font(.caption.monospacedDigit()).foregroundColor(.white)
        }
        .frame(width: 260)
    }

    // MARK: - 手动参数

    private var manualPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("重力实时测俯仰（推荐）", isOn: $cfg.pitchAuto)
                .font(.caption)
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))

            slider("安装高度", value: $cfg.heightM, range: 0.7...1.9, fmt: "%.2f m")
            slider("俯仰角（下俯为正）", value: $cfg.pitchDeg, range: 0...16, fmt: "%.1f°")
            slider("距离比例修正", value: $cfg.distScale, range: 0.6...1.6, fmt: "×%.2f")

            HStack {
                Text("若仍偏大：把比例往下调到实测吻合；偏小则往上调。")
                    .font(.system(size: 10)).foregroundColor(.gray)
                Spacer()
            }
            Button("恢复默认") {
                MountConfig.reset()
                cfg = MountConfig()
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundColor(.gray)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundColor(.white)
            }
            Slider(value: value, in: range)
        }
        .frame(width: 260)
    }

    // MARK: - 动作

    private func applyLidar() {
        guard lidar.done else { return }
        cfg.heightM = lidar.heightM
        cfg.pitchDeg = lidar.pitchDeg
        cfg.pitchAuto = true          // 俯仰仍由重力实时维护，标定值只是兜底
        cfg.calibrated = true
        cfg.calibratedAt = Date().timeIntervalSince1970
        cfg.lastResidual = lidar.spreadM
    }

    private func save() {
        if lidar.done && (cfg.heightM - lidar.heightM).magnitude > 0.05 {
            // 用户没点"填入"就直接完成：视为接受 LiDAR 结果
            applyLidar()
        }
        cfg.save()
        dismiss()
    }
}
