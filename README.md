# adas-ios — 行车视觉辅助 iOS 版

单目 ADAS 的原生 iOS APP。与网页版（`mobile/`）同一套算法与同一个模型，
推理从 onnxruntime-web (WebGL) 迁移到 **Core ML（自动调度到 Apple 神经网络引擎 ANE）**，
预期单帧推理 10–25ms（网页版 WebGL 60–100ms），功耗显著下降。

## 工程结构

```
adas-ios/
├── AdasIOS.xcodeproj/           Xcode 工程（直接双击打开）
├── AdasIOS/
│   ├── ADAS/                    算法层（从 mobile/*.js 逐条移植）
│   │   ├── Detector.swift       Core ML 推理 + YOLO 后处理 + NMS（detect.js）
│   │   ├── Tracker.swift        IoU 跟踪、EMA 距离、加速度（adas.js Track）
│   │   ├── Calib.swift          单目标定/测距/走廊（adas.js Calib）
│   │   ├── Rules.swift          告警规则引擎：刹车/插队/跟车/行人/红绿灯（rules.js）
│   │   ├── Lights.swift         信号灯：YOLO 框 + 颜色投票 + 连续 2 帧确认（lights.js v8）
│   │   ├── PixelOps.swift       尾灯红占比 / 灯箱颜色投票（rules.js 像素函数）
│   │   ├── EgoSpeed.swift       GPS 车速融合（adas.js EgoSpeed）
│   │   ├── LocationFeed.swift   CLLocation → EgoSpeed
│   │   ├── CameraManager.swift  1280x720 → 640x384 工作区（vImage 缩放 + letterbox）
│   │   └── Engine.swift         主循环编排
│   ├── App/                     SwiftUI 入口 + 主界面
│   ├── UI/                      HUD 覆盖层 + 相机预览
│   ├── Assets/yolov8n.mlmodel   已转换好的 Core ML 模型（12.7MB）
│   └── Info.plist               相机/GPS 权限、横屏锁定
├── tools/
│   ├── convert_model.py         ONNX → Core ML 转换（重新生成模型用）
│   └── validate_model.py        Core ML vs ONNX 数值校验（macOS 跑）
└── .github/workflows/build.yml  云端构建（macOS runner）
```

## 模型

- 来源：`mobile/model/yolov8n.onnx`（与网页版完全同一份，识别能力一致）
- 输入 640x384 图像（网页版是 384x640 竖排张量，这里按横排图像输入等价处理）
- 输出 `[1,84,5040]`，解码在设备端完成（COCO 80 类取 7 类，
  traffic light 第 9 类单独阈值 0.22 —— 与网页版 v8 相同）

重新转换（Windows/Mac 均可）：

```bash
pip install coremltools onnx onnx2torch onnxruntime torch
python tools/convert_model.py
```

## 构建（需要 Mac + Xcode 15+）

1. `git clone` 本目录后双击 `AdasIOS.xcodeproj`
2. 真机：Xcode 顶部选你的 iPhone → Signing & Capabilities 里选自己的
   Apple ID 团队（免费账号即可，7 天有效）→ ⌘R 运行
3. 模拟器：⌘R 即可（模拟器无摄像头，只能看 UI）

云端无签名构建验证：推到 GitHub 后 Actions 会自动跑
`xcodebuild build`（模拟器），并做 Core ML vs ONNX 数值校验。

## 与网页版的差异

- 横屏锁定（网页版支持竖屏），模型输入与预览共用一个 640x384 工作区，
  上下 12px letterbox，几何标定与网页版 effW 方案一致
- 语音用 AVSpeechSynthesizer（zh-CN），播报去重逻辑与网页版一致
- GPS 时钟与视觉帧统一为 host uptime 秒，规避网页版踩过的时钟基线坑
- 距离 EMA α=0.3、加速度双窗中位差分、刹车连续 2 帧确认 + 3 秒冷却、
  插队方向判据（偏移×横向速度<0 + 场景横移流扣除）——全部照搬 v8 修订版

## 局限

- 免费 Apple ID 签名 7 天过期，需重新构建安装；正式分发需开发者账号（$99/年）
- 首次启动需授权相机与定位；HUD 坐标映射假设横屏（左横屏/右横屏都支持）

## 生成 IPA 并装到 iPhone（无需 Mac）

IPA 的二进制必须在 macOS 上编译。两条路：

### 路线 A：GitHub Actions 云端出包（无需 Mac，推荐）

1. 把本目录推到 GitHub 仓库（public 免费，Actions 无限额）
2. Actions 会自动跑 `build-ios`：macOS runner 编译真机版（无签名）
   → 打成 `AdasIOS-unsigned.ipa` → 在 Run 页面 Artifacts 下载
3. Windows 上用 **Sideloadly**（sideloadly.io）签名并安装：
   - 装好 Sideloadly + iTunes（苹果官网版，不是商店版）+ iCloud
   - 手机 USB 连电脑，Sideloadly 拖入 ipa，填你的 Apple ID
   - Start → 自动用免费证书重签并安装（7 天有效，过期重签一次即可）
   - 手机上：设置 > 通用 > VPN 与设备管理 > 信任你的开发者证书

### 路线 B：有 Mac / 有付费开发者账号

```
xcodebuild -project AdasIOS.xcodeproj -scheme AdasIOS -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates archive \
  -archivePath AdasIOS.xcarchive
xcodebuild -exportArchive -archivePath AdasIOS.xcarchive -exportPath . \
  -allowProvisioningUpdates
```

付费账号（$99/年）签名有效期 1 年，可 TestFlight 分发。

## 已验证：云端出包成功（2026-10-26）

GitHub Actions（macos-14 / Xcode 15.4）已完整跑通：

- `xcodebuild -destination 'generic/platform=iOS'` 无签名真机构建 **通过**
- Core ML 模型数值校验 **通过**（与 ONNX 检测框 Jaccard 一致）
- 产物：`AdasIOS-unsigned.ipa`（11.2MB，arm64，含 `yolov8n.mlmodelc`，espresso 后端）

构建过程中修掉的编译问题（供后续参考）：

| 问题 | 修正 |
|---|---|
| `@MainActor` 类里 `nonisolated func` 访问隔离属性 | Engine 去掉 `@MainActor`，状态发布用 `DispatchQueue.main.async` |
| `MLImageConstraint.pixelWidth/pixelHeight` 不存在 | 改用 `pixelsWide/pixelsHigh` |
| `.pi` 在 Double 上下文歧义 | 写 `Double.pi` |
| `UnsafeMutablePointer<UInt8>` 赋给 `UnsafeMutableRawPointer` | 显式 `UnsafeMutableRawPointer(...)` |
| `AVCaptureVideoPreviewLayer.videoOrientation` 在新 SDK 移除 | 改用 `videoRotationAngle`（iOS 17+，带 `#available` 守卫） |
| `isVideoRotationAngleSupported` 是方法不是属性 | `conn.isVideoRotationAngleSupported(angle)` |
| macOS runner `pip install` 被 PEP 668 挡住 | 用 `actions/setup-python@v5`（3.11） |

> 相机方向策略：App 锁定横屏，`videoRotationAngle = 0` 即传感器原生横屏（1280×720），
> vImageScale 把它缩进 640×384 工作区中间 360 行（上下各 12px letterbox），与网页版标定一致。
