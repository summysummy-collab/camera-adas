// PixelOps.swift — 工作区像素采样：尾灯红占比 / 信号灯颜色投票
// （移植 mobile/rules.js rgb2hsv / redRatio / classifyLight）
import Foundation
import CoreVideo

/// 工作区 BGRA 像素缓冲只读视图（与检测框同一坐标系）
struct FrameBuf {
    let base: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    init?(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?
            .assumingMemoryBound(to: UInt8.self) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return nil
        }
        self.base = base
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
        self.bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // 不在 init 里解锁：调用方用完需调用 unlock()。
        // 改为 defer 模式由调用方保证更稳，这里提供 finished() 钩子。
    }

    func finished(_ pb: CVPixelBuffer) {
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    }

    /// BGRA 第 4 字节序（iOS 小端 BGRA：b=0,g=1,r=2）
    @inline(__always) func bgra(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = y * bytesPerRow + x * 4
        return (base[i], base[i + 1], base[i + 2])   // (b, g, r)
    }
}

func rgb2hsv(_ rIn: Double, _ gIn: Double, _ bIn: Double) -> (Double, Double, Double) {
    let r = rIn / 255, g = gIn / 255, b = bIn / 255
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var hh = 0.0
    if d > 1e-6 {
        if mx == r { hh = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { hh = (b - r) / d + 2 }
        else { hh = (r - g) / d + 4 }
        hh *= 60
        if hh < 0 { hh += 360 }
    }
    return (hh, mx <= 0 ? 0 : d / mx, mx)
}

/// 框内下部"亮红"像素占比：尾灯点亮判据
/// （注意 BGRA：第 3 个字节才是 R）
func redRatio(_ img: FrameBuf, _ box: [Double], yFrom: Double = 0.55) -> Double {
    let x1 = max(0, Int(box[0].rounded()))
    let x2 = min(img.width, Int(box[2].rounded()))
    let ya = max(0, Int((box[1] + (box[3] - box[1]) * yFrom).rounded()))
    let yb = min(img.height, Int(box[3].rounded()))
    if x2 - x1 < 6 || yb - ya < 4 { return 0 }
    var hit = 0, tot = 0
    let step = max(1, (x2 - x1) / 64)
    var y = ya
    while y < yb {
        var x = x1
        while x < x2 {
            let (b, g, r) = img.bgra(x, y)
            let (hh, s, v) = rgb2hsv(Double(r), Double(g), Double(b))
            if (hh < 12 || hh > 165) && s > 0.47 && v > 0.35 { hit += 1 }
            tot += 1
            x += step
        }
        y += step
    }
    return tot > 0 ? Double(hit) / Double(tot) : 0
}

enum LightColor: String {
    case red, yellow, green, unknown
}

/// 灯箱颜色投票（YOLO traffic light 框内数红/黄/绿像素）
/// 色相窗：红 <15°/>345°、黄 15-55°、绿 90-170°（绿 LED 实测 ~110-150°）
func classifyLight(_ img: FrameBuf, _ box: [Double]) -> (LightColor, Double) {
    let x1 = max(0, Int(box[0].rounded()))
    let x2 = min(img.width, Int(box[2].rounded()))
    let y1 = max(0, Int(box[1].rounded()))
    let y2 = min(img.height, Int(box[3].rounded()))
    if x2 - x1 < 4 || y2 - y1 < 4 { return (.unknown, 0) }
    var cnt: [LightColor: Int] = [.red: 0, .yellow: 0, .green: 0]
    var n = 0
    for y in y1..<y2 {
        for x in x1..<x2 {
            let (b, g, r) = img.bgra(x, y)
            let (hh, s, v) = rgb2hsv(Double(r), Double(g), Double(b))
            // v/s 门限比网页版略放松：白天红灯亮度只有 0.5 上下，太严会一直判不出颜色
            if v > 0.45 && s > 0.25 {
                n += 1
                if hh < 15 || hh > 345 { cnt[.red]! += 1 }
                else if hh >= 15 && hh < 55 { cnt[.yellow]! += 1 }
                else if hh >= 90 && hh < 170 { cnt[.green]! += 1 }
            }
        }
    }
    if n < max(6, Int(0.015 * Double((x2 - x1) * (y2 - y1)))) { return (.unknown, 0) }
    var best = LightColor.unknown
    var bc = 0
    for (k, c) in cnt where c > bc { best = k; bc = c }
    let conf = Double(bc) / Double(n)
    return conf < 0.40 ? (.unknown, conf) : (best, conf)
}
