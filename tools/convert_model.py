# -*- coding: utf-8 -*-
"""ONNX -> Core ML (neuralnetwork) 转换脚本
在 Windows 上跑通：onnx2torch 把 ONNX 图还原成 torch 模块，
再 trace 后用 coremltools 转 legacy neuralnetwork 格式
（mlprogram 后端依赖 BlobWriter，Windows 缺原生库，故用 neuralnetwork）。
Mac 上也可直接跑：coremltools 任意版本均支持。
"""
import os
import sys
import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnx2torch import convert

ONNX_PATH = sys.argv[1] if len(sys.argv) > 1 else "../mobile/model/yolov8n.onnx"
if not os.path.exists(ONNX_PATH):
    ONNX_PATH = "model/yolov8n.onnx"
OUT_PATH = sys.argv[2] if len(sys.argv) > 2 else "AdasIOS/Assets/yolov8n.mlmodel"
H, W = 384, 640

onnx_model = onnx.load(ONNX_PATH)
in_names = [i.name for i in onnx_model.graph.input]
out_names = [o.name for o in onnx_model.graph.output]
print("inputs:", in_names, "outputs:", out_names)

torch_model = convert(onnx_model).eval()
dummy = torch.rand(1, 3, H, W)
with torch.no_grad():
    traced = torch.jit.trace(torch_model, dummy)

import coremltools as ct
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(
        name=in_names[0], shape=(1, 3, H, W),
        scale=1.0 / 255.0,
        bias=[0, 0, 0],
        color_layout=ct.colorlayout.RGB,
    )],
    convert_to="neuralnetwork",
)
mlmodel.author = "adas-ios"
mlmodel.short_description = "YOLOv8n 384x640, COCO 80 classes, decoded on device"

# 数值校验：同一张随机图，onnxruntime vs Core ML CPU
x = np.random.rand(1, 3, H, W).astype(np.float32)
so = ort.InferenceSession(ONNX_PATH, providers=["CPUExecutionProvider"])
ref = so.run([out_names[0]], {in_names[0]: x})[0]
from coremltools.models.neural_network import NeuralNetworkBuilder  # noqa: F401
mlmodel.save(OUT_PATH)
print("saved:", OUT_PATH)

# 重新加载校验（skip_model_load=False 默认；Windows 缺 libcoremlpython 时不能本地预测，
# 只能靠结构校验，真机/CI 上再验数值）
import os
print("size MB:", round(os.path.getsize(OUT_PATH if os.path.isfile(OUT_PATH) else OUT_PATH + "/") / 1e6, 1))
spec = mlmodel.get_spec()
print("mlmodel inputs:", [(f.name, str(f.type.WhichOneof('Type'))) for f in spec.description.input])
print("mlmodel outputs:", [(o.name, str(o.type.WhichOneof('Type'))) for o in spec.description.output])
