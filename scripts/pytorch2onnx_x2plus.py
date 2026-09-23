"""Convert RealESRGAN_x2plus.pth to clean ncnn model (official-style pipeline).

RRDBNet scale=2 uses pixel_unshuffle; we rely on torch.nn.functional.pixel_unshuffle
so ONNX export stays free of dynamic Shape ops when possible.
"""
from __future__ import annotations

import argparse
import inspect
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.onnx


def make_layer(block, n_layers, **kw):
    return nn.Sequential(*[block(**kw) for _ in range(n_layers)])


class ResidualDenseBlock(nn.Module):
    def __init__(self, num_feat=64, num_grow_ch=32):
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, num_feat, num_grow_ch=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        out = self.rdb1(x)
        out = self.rdb2(out)
        out = self.rdb3(out)
        return out * 0.2 + x


class RRDBNet(nn.Module):
    """ESRGAN / Real-ESRGAN generator. scale=2 uses pixel_unshuffle first."""

    def __init__(self, num_in_ch=3, num_out_ch=3, scale=4, num_feat=64, num_block=23, num_grow_ch=32):
        super().__init__()
        self.scale = scale
        in_ch = num_in_ch
        if scale == 2:
            in_ch = num_in_ch * 4
        elif scale == 1:
            in_ch = num_in_ch * 16
        self.conv_first = nn.Conv2d(in_ch, num_feat, 3, 1, 1)
        self.body = make_layer(RRDB, num_block, num_feat=num_feat, num_grow_ch=num_grow_ch)
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        if self.scale == 2:
            feat = F.pixel_unshuffle(x, 2)
        elif self.scale == 1:
            feat = F.pixel_unshuffle(x, 4)
        else:
            feat = x
        feat = self.conv_first(feat)
        body_feat = self.conv_body(self.body(feat))
        feat = feat + body_feat
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="RealESRGAN_x2plus.pth")
    parser.add_argument("--output", required=True, help="output .onnx path")
    parser.add_argument("--scale", type=int, default=2)
    parser.add_argument("--size", type=int, default=64, help="dummy input spatial size (must be divisible by scale unshuffle)")
    args = parser.parse_args()

    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=args.scale)
    ckpt = torch.load(args.input, map_location="cpu")
    key = "params_ema" if "params_ema" in ckpt else "params"
    model.load_state_dict(ckpt[key], strict=True)
    model.eval()

    # spatial size must be divisible by pixel_unshuffle factor
    unshuffle = 2 if args.scale == 2 else (4 if args.scale == 1 else 1)
    size = args.size
    if unshuffle > 1 and size % unshuffle != 0:
        raise SystemExit(f"--size must be divisible by {unshuffle}")

    x = torch.randn(1, 3, size, size)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    export_kw = dict(
        opset_version=11,
        input_names=["data"],
        output_names=["output"],
        dynamic_axes=None,  # fixed shapes -> fewer Shape nodes
        do_constant_folding=True,
    )
    # torch < 2.5 has no "dynamo" argument (legacy exporter is already the default there)
    if "dynamo" in inspect.signature(torch.onnx.export).parameters:
        export_kw["dynamo"] = False  # classic exporter, friendlier to onnx2ncnn

    with torch.no_grad():
        torch.onnx.export(model, x, str(out_path), **export_kw)
        y = model(x)
    print(f"exported {out_path}  input={tuple(x.shape)} output={tuple(y.shape)}")


if __name__ == "__main__":
    main()
