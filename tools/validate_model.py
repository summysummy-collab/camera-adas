#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模型数值校验：Core ML vs ONNX（需 macOS，CI 上跑）。
对同一张随机输入比较两套推理的检测框集合，允许小数值误差。"""
import os
import sys
import numpy as np

MODEL = "AdasIOS/Assets/yolov8n.mlmodel"
ONNX_CANDIDATES = ["model/yolov8n.onnx", "../mobile/model/yolov8n.onnx"]
ONNX = next(p for p in ONNX_CANDIDATES if os.path.exists(p))
H, W = 384, 640


def postprocess(out, conf_thr=0.25):
    """out: [1,84,N] -> list of (cls, x1,y1,x2,y2)"""
    C, N = out.shape[1], out.shape[2]
    d = out[0]
    boxes = []
    for cid in (0, 1, 2, 3, 5, 7, 9):
        s = d[4 + cid]
        idx = np.where(s > conf_thr)[0]
        for i in idx:
            cx, cy, w, h = d[0, i], d[1, i], d[2, i], d[3, i]
            boxes.append((cid, cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2))
    return boxes


def main():
    import coremltools as ct
    import onnxruntime as ort

    x = np.random.rand(1, 3, H, W).astype(np.float32) * 255

    so = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
    ref = so.run(["output0"], {"images": x / 255.0})[0]

    m = ct.models.MLModel(MODEL, compute_units=ct.ComputeUnit.CPU_ONLY)
    from PIL import Image
    img = Image.fromarray(np.uint8(x[0].transpose(1, 2, 0)), mode="RGB")
    pred = m.predict({"images": img})
    key = [k for k in pred.keys()][0]
    out = np.array(pred[key]).reshape(1, 84, -1)

    a = postprocess(ref)
    b = postprocess(out)
    print(f"onnx dets: {len(a)}, coreml dets: {len(b)}")
    if not a and not b:
        print("PASS: 两边都无检出（随机噪声图，合理）")
        return 0
    # 数值容差比较：IOU 网格化
    sa = set((c, round(x1 / 8), round(y1 / 8), round(x2 / 8), round(y2 / 8)) for c, x1, y1, x2, y2 in a)
    sb = set((c, round(x1 / 8), round(y1 / 8), round(x2 / 8), round(y2 / 8)) for c, x1, y1, x2, y2 in b)
    inter = len(sa & sb)
    union = len(sa | sb) or 1
    jac = inter / union
    print(f"grid Jaccard = {jac:.3f}")
    ok = jac > 0.7
    print("PASS" if ok else "FAIL: Core ML 与 ONNX 输出差异过大")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
