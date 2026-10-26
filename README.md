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

## v1.1 修订（2026-10-26，实车反馈后）

实车测试反馈四项问题，逐条定位与修复：

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | 红绿灯完全不提醒 | `Calib` 是 **struct**，Engine 里那份从未 `fit()`，传给 LightTracker 的 `fy` 还是初值 `1` → 所有灯距离算成 `1×1.0/框高 ≈ 0.05m`，被 `dist>=3` 全部过滤 → 永远不产生告警 | Engine 启动即 `calib.fit(640,384)`；LightTracker 内部再按画面尺寸 fit 一次兜底；灯距范围放宽到 2–80m；灯类别置信度阈值 0.22→0.15（后面还有颜色投票+2帧确认把关） |
| 2 | 前车刹车基本不提醒 | 旧逻辑要求「GPS 可用 + 绝对减速度 > 3.5」或「相对减速度 > 5 m/s²」，太严；尾灯判据要求红像素占比 > 5%，白天根本达不到 | 三路证据融合：相对接近加速度 >2.2 m/s²、尾灯红占比 ≥2%（或相对基线 1.7 倍突增）、GPS 绝对减速度 >2.8 m/s²，**任一成立即触发**；接近速度门槛 1.0 m/s；连续 2 帧确认 + 2.5s 冷却 |
| 3 | 旁边车道有车就报"插入" | 旧判据 `isNew = hits <= 20` 会短路掉方向判断：任何新出现的检测框只要在走廊内就直接算插入；且横向速度用归一化像素，阈值 0.05 几乎等于没门槛 | 改成**走廊状态迁移**：必须已被稳定跟踪（hits≥8）→ 最近 2s 内刚从走廊外进入（连续 2 帧）→ 横向速度（**m/s**，扣除场景整体横移）> 0.7 且朝本车轴。旁车道车辆不满足迁移条件，天然不报 |
| 4 | 希望按车速提前提示刹车 | 原逻辑是固定距离阈值（25m/12m），不随速度变化 | 新增速度自适应 FCW：`所需距离 = v×1s + v²/(2×6 m/s²) + 接近速度×0.5`，实际/所需 < 0.60 报"立即刹车"、< 0.85 报"提前减速"、< 1.10 报"注意车距" |

另加**诊断行**（右下角小字），实时显示：
`det N · tl N · 灯报 N · GPS ok/无 v a · 前车距离 接近速度 接近加速度 尾灯红占比 · 车N` + `FCW 实际/所需=比值`。
下次路测如果还有不报/误报，把这一行发我即可定位。

顺带：信号灯不再套用车辆尺寸的地面法测距（量纲不同），HUD 上不再显示错误的灯距。

## v1.2 修订（2026-10-26，测距 3 倍偏差）

实车反馈：显示距离约为实际的 **3 倍**（人和车都偏）。定位结果：不是噪声，是**几何参数未标定 + 融合策略病态**。

### 根因（按贡献排序）

| # | 问题 | 量化 |
|---|---|---|
| 1 | **地面法在远距离数值病态**：`d = h/tan(pitch + α)`，30m 处分母只有 2.4°，俯仰角差 2° 就能把 30m 算成 114m | **3.8 倍** ← 主因 |
| 2 | `pitch = 4°` 是硬编码猜测值，从未测量（手机装在支架上的真实俯角常在 0–10° 之间） | 每差 1°，30m 处差约 50% |
| 3 | `fov = 62°` 硬编码，iPhone 主摄 16:9 视频实际 hfov 常在 65–70° | 8%~13% 系统性偏大 |
| 4 | 融合逻辑只要"地面法有效"就采信它，宽度法明明算对了也被丢弃 | 直接放大 1 的问题 |
| 5 | `LightTracker.Entry` 是 struct，只改局部副本没写回字典 → 连续帧计数永远=1 → **红绿灯其实一直不可能触发** | 功能性 bug |

### 修复

1. **测距改为三路逆方差加权**（`Calib.estimateDistance`）
   - 地面法 σd/d ≈ (d/h)·σpitch（近距离准、远距离崩）
   - 宽度法 `d = fx·W/w_px`（与俯仰/安装高度无关，远距离主力）
   - 高度法 `d = fy·H/h_px`（行人身高 1.7m 最稳）
   - 权重 = 1/σ²，天然做到"近靠地面、远靠尺寸"；再加一致性闸门剔除背离 >2.2 倍的一路
   - 蒙特卡洛验证（俯仰误差 ±0.6°、装高 ±4%、框宽 ±6%）：**3–60m 中位误差 2.6%~4.3%，P90 < 11%**
2. **焦距改用真实值**：运行时读 `AVCaptureDevice.activeFormat.videoFieldOfView`
3. **俯仰角改用重力实测**：`CoreMotion` 的 `gravity` → `asin(-g.z)`，25Hz 平滑（τ≈0.6s），随支架角度变化自动跟随
4. **安装高度**：新增标定页，LiDAR/ARKit 一键实测（见下）
5. **修复红绿灯状态机**：Entry 改为"取出→改→写回"
6. 新增**距离比例修正**滑块（×0.6–1.6）作为最后兜底

### LiDAR 标定页（回答"能不能用 LiDAR 校准"）

**能，但用法不是"用 LiDAR 直接测跟车距离"** —— LiDAR 有效量程约 5m，测不到 30m 外的车。它的正确用法是**标定几何参数**：

- 俯仰角：`ARWorldTrackingConfiguration` 的世界 Y 轴与重力对齐 → 直接读相机姿态（±0.3°）
- 安装高度：取画面下半部（前方 3–6m 路面）的 `sceneDepth`，逐像素按
  `h = R·√(1+xn²+yn²)·sin(pitch + atan(yn))` 反算，取中位数（抗井盖/前车干扰）
- 焦距：读 `frame.camera.intrinsics` 做交叉校验
- 无 LiDAR 机型：退化为 `ARPlaneAnchor` 水平面检测

由于地面法的误差 ≈ (d/h)·σpitch，把 h 和 pitch 标到 1cm / 0.3° 之后，30m 处的误差从 200% 降到 <10%。这就是"用 LiDAR 校准好距离"的正解。

### 诊断行新增字段

```
… · 车4 · 装1.25m 俯6.2° fov66
```
`装` 安装高度、`俯` 当前俯仰（重力实时）、`fov` 当前使用的视场角。路测时把这行发我即可判断是参数问题还是检测问题。
