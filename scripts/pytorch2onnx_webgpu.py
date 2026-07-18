"""Export Real-ESRGAN models to ONNX for browser WebGPU (onnxruntime-web).

Uses dynamic H/W so the JS engine can tile with variable sizes (like ncnn Route A).
"""
from __future__ import annotations

import argparse
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.onnx


# ---- RRDBNet (x2plus / x4plus) ------------------------------------------------

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


# ---- SRVGGNetCompact (animevideov3 / general-x4v3) ---------------------------

class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=16, upscale=4, act_type="prelu"):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        if act_type == "prelu":
            self.body.append(nn.PReLU(num_parameters=num_feat))
        elif act_type == "relu":
            self.body.append(nn.ReLU(inplace=True))
        else:
            raise ValueError(act_type)
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            if act_type == "prelu":
                self.body.append(nn.PReLU(num_parameters=num_feat))
            else:
                self.body.append(nn.ReLU(inplace=True))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        # Residual to bicubic upsample of input (matches official Real-ESRGAN)
        base = F.interpolate(x, scale_factor=self.upscale, mode="nearest")
        return out + base


class AnimeVideoScaled(nn.Module):
    """4x animevideov3 + optional downsample to emulate ncnn x2/x3 packages."""

    def __init__(self, net: SRVGGNetCompact, out_scale: int):
        super().__init__()
        self.net = net
        self.out_scale = out_scale

    def forward(self, x):
        out = self.net(x)
        if self.out_scale == 4:
            return out
        factor = self.out_scale / 4.0
        return F.interpolate(out, scale_factor=factor, mode="bicubic", align_corners=False)


def load_state(model: nn.Module, path: Path) -> None:
    ckpt = torch.load(str(path), map_location="cpu")
    if isinstance(ckpt, dict):
        if "params_ema" in ckpt:
            state = ckpt["params_ema"]
        elif "params" in ckpt:
            state = ckpt["params"]
        else:
            state = ckpt
    else:
        state = ckpt
    model.load_state_dict(state, strict=True)


def export_onnx(model: nn.Module, out_path: Path, size: int = 64, dynamic: bool = False) -> None:
    model.eval()
    x = torch.randn(1, 3, size, size)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # WebGPU / ORT: NEVER reuse the same dim_param string for input and output.
    # SR outputs are scale× larger; shared "height"/"width" causes:
    #   Shape mismatch attempting to re-use buffer. {1,H,W,3} != {1,H*s,W*s,3}
    export_kw = dict(
        opset_version=17,
        input_names=["data"],
        output_names=["output"],
        do_constant_folding=True,
        dynamo=False,
    )
    if dynamic:
        export_kw["dynamic_axes"] = {
            "data": {2: "in_height", 3: "in_width"},
            "output": {2: "out_height", 3: "out_width"},
        }
    with torch.no_grad():
        torch.onnx.export(model, x, str(out_path), **export_kw)
        y = model(x)
    mode = "dynamic" if dynamic else f"fixed {size}x{size}"
    print(f"exported {out_path}  in={tuple(x.shape)} out={tuple(y.shape)}  ({mode})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", required=True, choices=["rrdb", "srvgg", "anime-scaled"])
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--scale", type=int, default=4)
    parser.add_argument("--num-conv", type=int, default=16)
    parser.add_argument("--num-block", type=int, default=23)
    parser.add_argument("--size", type=int, default=64, help="export / fixed-tile spatial size")
    parser.add_argument(
        "--dynamic",
        action="store_true",
        help="export dynamic H/W (uses distinct in_/out_ dim names). Default: fixed shape for WebGPU.",
    )
    args = parser.parse_args()

    if args.arch == "rrdb":
        model = RRDBNet(scale=args.scale, num_block=args.num_block)
        load_state(model, args.input)
        export_onnx(model, args.output, args.size, dynamic=args.dynamic)
    elif args.arch == "srvgg":
        model = SRVGGNetCompact(num_conv=args.num_conv, upscale=args.scale)
        load_state(model, args.input)
        export_onnx(model, args.output, args.size, dynamic=args.dynamic)
    else:
        base = SRVGGNetCompact(num_conv=16, upscale=4)
        load_state(base, args.input)
        model = AnimeVideoScaled(base, out_scale=args.scale)
        export_onnx(model, args.output, args.size, dynamic=args.dynamic)


if __name__ == "__main__":
    main()
