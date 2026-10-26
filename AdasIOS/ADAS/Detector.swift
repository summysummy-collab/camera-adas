// Detector.swift — Core ML 推理与 YOLOv8 输出后处理（移植 mobile/detect.js）
import Foundation
import CoreML
import CoreVideo
import QuartzCore

struct DetStats {
    var max = 0.0        // 关注类最高分（分清"模型跑坏"和"画面里真没目标"）
    var nan = false
    var n = 0
}

final class Detector {
    static let WANTED: [Int: String] = [
        0: "person", 1: "bicycle", 2: "car", 3: "motorcycle",
        5: "bus", 7: "truck", 9: "traffic light",
    ]
    // 信号灯是小目标，置信度分布偏低，单独更宽阈值
    static let CONF_BY_CLS: [Int: Double] = [9: 0.22]

    let model: MLModel
    let W: Int
    let H: Int
    let conf: Double
    private(set) var lastMs: Double = 0
    private(set) var stats = DetStats()

    init(conf: Double = 0.35, computeUnits: MLComputeUnits = .all) throws {
        guard let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") else {
            throw NSError(domain: "Detector", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "yolov8n.mlmodelc 不在 bundle 中"])
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits      // .all → 优先 ANE 神经网络引擎
        self.model = try MLModel(contentsOf: url, configuration: cfg)
        let inputDesc = model.modelDescription.inputDescriptionsByName["images"]!
        let constraint = inputDesc.imageConstraint!
        self.W = constraint.pixelsWide
        self.H = constraint.pixelsHigh
        self.conf = conf
    }

    /// 输入：工作区 CVPixelBuffer（BGRA，W×H，与模型输入一致）
    func detect(_ pb: CVPixelBuffer) throws -> [Detection] {
        let t0 = CACurrentMediaTime()
        let input = try MLDictionaryFeatureProvider(
            dictionary: ["images": MLFeatureValue(pixelBuffer: pb)])
        let out = try model.prediction(from: input)
        guard let name = out.featureNames.first,
              let arr = out.featureValue(for: name)?.multiArrayValue else {
            throw NSError(domain: "Detector", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "输出不是 multiArray"])
        }
        let dets = Self.postprocess(arr, confThr: conf)
        lastMs = (CACurrentMediaTime() - t0) * 1000
        return dets
    }

    /// YOLOv8 输出 [1,84,N]（cx,cy,w,h + 80 类分数，已 sigmoid）
    static func postprocess(_ arr: MLMultiArray, confThr: Double) -> [Detection] {
        let dims = arr.shape.map { $0.intValue }
        guard dims.count == 3 else { return [] }
        let C = dims[1], N = dims[2]
        let f = arr.dataPointer.assumingMemoryBound(to: Float.self)

        var stats = DetStats()
        var scores = [Float](repeating: 0, count: N)
        var bestCls = [Int](repeating: -1, count: N)

        for cid in WANTED.keys {
            let base = (4 + cid) * N
            for i in 0..<N {
                let s = f[base + i]
                if s.isNaN { stats.nan = true; continue }
                if Double(s) > stats.max { stats.max = Double(s) }
                if s > scores[i] { scores[i] = s; bestCls[i] = cid }
            }
        }
        stats.n = N

        var cands: [Detection] = []
        cands.reserveCapacity(64)
        for i in 0..<N {
            let cid = bestCls[i]
            guard cid >= 0 else { continue }
            let thr = CONF_BY_CLS[cid] ?? confThr
            let s = Double(scores[i])
            if s < thr { continue }
            let cx = Double(f[i]), cy = Double(f[N + i])
            let w = Double(f[2 * N + i]), h = Double(f[3 * N + i])
            if w < 3 || h < 3 { continue }
            cands.append(Detection(
                clsId: cid, name: WANTED[cid]!, conf: s,
                box: Box(x1: cx - w / 2, y1: cy - h / 2, x2: cx + w / 2, y2: cy + h / 2)))
        }
        return nms(cands, 0.45)
    }

    static func nms(_ list: [Detection], _ thr: Double) -> [Detection] {
        let sorted = list.sorted { $0.conf > $1.conf }
        var keep: [Detection] = []
        for c in sorted {
            var ok = true
            for k in keep {
                if k.clsId != c.clsId { continue }
                if iouBoxes(k.box, c.box) > thr { ok = false; break }
            }
            if ok { keep.append(c) }
        }
        return keep
    }

    static func iouBoxes(_ a: Box, _ b: Box) -> Double {
        let ix1 = max(a.x1, b.x1), iy1 = max(a.y1, b.y1)
        let ix2 = min(a.x2, b.x2), iy2 = min(a.y2, b.y2)
        let iw = max(0, ix2 - ix1), ih = max(0, iy2 - iy1)
        let inter = iw * ih
        if inter <= 0 { return 0 }
        let aa = (a.x2 - a.x1) * (a.y2 - a.y1)
        let bb = (b.x2 - b.x1) * (b.y2 - b.y1)
        return inter / (aa + bb - inter)
    }
}
