// ContentView.swift — 主界面：启动/停止 + 预览 + HUD
import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var engine = Engine()
    @State private var errorMsg: String? = nil
    @State private var permissionAsked = false

    var body: some View {
        ZStack {
            if engine.running {
                CameraPreview(session: engine.camera.session)
                    .ignoresSafeArea()
                HudView(scene: engine.scene, fps: engine.fps, inferMs: engine.inferMs,
                        gpsOk: engine.gpsOk, gpsSpeed: engine.gpsSpeed, gpsSrc: engine.gpsSrc)
                    .ignoresSafeArea()
                // 停止按钮（右上角小圆点，避免行车时误触）
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            engine.stop()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.white.opacity(0.75))
                        }
                        .padding(10)
                    }
                    Spacer()
                }
            } else {
                VStack(spacing: 24) {
                    Image(systemName: "car.rear.fill")
                        .font(.system(size: 56)).foregroundColor(.accentColor)
                    Text("行车视觉辅助").font(.title.bold())
                    Text("横屏使用 · 手机固定在前挡风后\n检测前车刹车 / 插队 / 行人 / 红绿灯")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        startTapped()
                    } label: {
                        Text("开始")
                            .font(.title3.bold())
                            .frame(width: 180, height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    if let e = errorMsg {
                        Text(e).font(.footnote).foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .background(Color.black)
    }

    private func startTapped() {
        errorMsg = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            doStart()
        case .notDetermined:
            permissionAsked = true
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { doStart() }
                    else { errorMsg = "未授权相机，无法运行" }
                }
            }
        default:
            errorMsg = "相机权限被拒绝，请到 设置 > 隐私与安全 > 相机 打开"
        }
    }

    private func doStart() {
        do {
            try engine.start()
        } catch {
            errorMsg = "启动失败：\(error.localizedDescription)"
        }
    }
}

#Preview { ContentView() }
