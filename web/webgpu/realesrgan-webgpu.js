/**
 * Route B: Real-ESRGAN tiled inference via onnxruntime-web + WebGPU.
 * Expects global `ort` (from ort.webgpu.min.js) and models under ./models-onnx/.
 *
 * IMPORTANT: every tile must use the SAME fixed input spatial size.
 * ORT WebGPU buffer reuse breaks when run() sees changing dynamic shapes.
 */
(function (global) {
  "use strict";

  function clampByte(v) {
    v = v * 255 + 0.5;
    if (v > 255) v = 255;
    if (v < 0) v = 0;
    return v | 0;
  }

  /**
   * Extract a fixed-size (inSize x inSize) tile centered on the content region
   * [tileX, tileY, tileW, tileH] with PAD border, replicate at image edges.
   * Extra space on the right/bottom (when tileW/H < TILE) is also filled by replicate.
   */
  function extractFixedTileNCHW(rgba, w, h, tileX, tileY, tileW, tileH, PAD, inSize) {
    const data = new Float32Array(1 * 3 * inSize * inSize);
    // Content starts at (PAD, PAD) inside the fixed window.
    for (let c = 0; c < 3; c++) {
      const plane = c * inSize * inSize;
      for (let y = 0; y < inSize; y++) {
        // Map window y -> source y: content region is [PAD, PAD+tileH)
        let sy;
        if (y < PAD) {
          sy = Math.min(Math.max(tileY - (PAD - y), 0), h - 1);
        } else if (y < PAD + tileH) {
          sy = Math.min(Math.max(tileY + (y - PAD), 0), h - 1);
        } else {
          // Past content: clamp to last content row (or image edge)
          sy = Math.min(Math.max(tileY + tileH - 1, 0), h - 1);
        }
        for (let x = 0; x < inSize; x++) {
          let sx;
          if (x < PAD) {
            sx = Math.min(Math.max(tileX - (PAD - x), 0), w - 1);
          } else if (x < PAD + tileW) {
            sx = Math.min(Math.max(tileX + (x - PAD), 0), w - 1);
          } else {
            sx = Math.min(Math.max(tileX + tileW - 1, 0), w - 1);
          }
          data[plane + y * inSize + x] = rgba[(sy * w + sx) * 4 + c] / 255;
        }
      }
    }
    return data;
  }

  function writeTileFromFixedOutput(outRgba, outW, outH, scale, tileX, tileY, tileW, tileH, PAD, nchw) {
    // Support both NCHW [1,3,H,W] and NHWC [1,H,W,3] (ORT WebGPU may return either).
    const dims = nchw.dims;
    const src = nchw.data;
    let oh, ow, getPixel;

    if (dims.length === 4 && dims[1] === 3) {
      // NCHW
      oh = dims[2];
      ow = dims[3];
      getPixel = (y, x, c) => src[c * oh * ow + y * ow + x];
    } else if (dims.length === 4 && dims[3] === 3) {
      // NHWC
      oh = dims[1];
      ow = dims[2];
      getPixel = (y, x, c) => src[(y * ow + x) * 3 + c];
    } else {
      throw new Error("unexpected output dims: " + JSON.stringify(dims));
    }

    const padOut = PAD * scale;
    const outTw = tileW * scale;
    const outTh = tileH * scale;
    const dstX = tileX * scale;
    const dstY = tileY * scale;

    if (ow < padOut + outTw || oh < padOut + outTh) {
      throw new Error(
        "output too small for crop: out=" + ow + "x" + oh +
        " need>=" + (padOut + outTw) + "x" + (padOut + outTh)
      );
    }

    for (let y = 0; y < outTh; y++) {
      for (let x = 0; x < outTw; x++) {
        const sx = padOut + x;
        const sy = padOut + y;
        const di = ((dstY + y) * outW + (dstX + x)) * 4;
        outRgba[di] = clampByte(getPixel(sy, sx, 0));
        outRgba[di + 1] = clampByte(getPixel(sy, sx, 1));
        outRgba[di + 2] = clampByte(getPixel(sy, sx, 2));
        outRgba[di + 3] = 255;
      }
    }
  }

  class RealESRGANWebGPU {
    constructor() {
      this.models = [];
      this.session = null;
      this.active = null;
      this.ortConfigured = false;
    }

    async detect() {
      if (!navigator.gpu) return false;
      try {
        const adapter = await navigator.gpu.requestAdapter();
        return !!adapter;
      } catch (_) {
        return false;
      }
    }

    async loadManifest(url) {
      const res = await fetch(url);
      if (!res.ok) throw new Error("failed to fetch " + url);
      const json = await res.json();
      this.models = (json.models || []).map((m, index) => ({
        index,
        name: m.name,
        file: m.file,
        scale: m.scale,
        input: m.input || "data",
        output: m.output || "output",
        tilesize: m.tilesize || 128,
        prepadding: m.prepadding || 10,
        align: m.align || 1,
        backend: "webgpu"
      }));
      return this.models;
    }

    async ensureOrt() {
      if (typeof ort === "undefined") {
        throw new Error("onnxruntime-web not loaded (ort global missing)");
      }
      if (!this.ortConfigured) {
        // Must be an absolute URL: ORT loads its .mjs via dynamic import(),
        // and bare relative specifiers like "ort/..." fail to resolve.
        ort.env.wasm.wasmPaths = new URL("ort/", global.location.href).href;
        ort.env.wasm.numThreads = Math.min(4, navigator.hardwareConcurrency || 2);
        // Prefer dGPU when the browser honors it (currently ignored on Windows Chrome).
        ort.env.webgpu = ort.env.webgpu || {};
        ort.env.webgpu.powerPreference = "high-performance";
        this.ortConfigured = true;
      }
    }

    /** Best-effort GPU label for UI (after session create, ort may expose adapter). */
    async getAdapterLabel() {
      try {
        if (ort && ort.env && ort.env.webgpu && ort.env.webgpu.adapter) {
          const info = await ort.env.webgpu.adapter.requestAdapterInfo();
          return (info && (info.description || info.device || info.vendor)) || "WebGPU adapter";
        }
        const adapter = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
        if (!adapter) return "unknown";
        if (adapter.info) {
          return adapter.info.description || adapter.info.device || adapter.info.vendor || "WebGPU";
        }
        if (typeof adapter.requestAdapterInfo === "function") {
          const info = await adapter.requestAdapterInfo();
          return (info && (info.description || info.device || info.vendor)) || "WebGPU";
        }
        return "WebGPU";
      } catch (_) {
        return "WebGPU";
      }
    }

    async loadModel(model) {
      await this.ensureOrt();
      if (this.active && this.active.name === model.name && this.session) {
        return;
      }
      if (this.session) {
        try { await this.session.release(); } catch (_) {}
        this.session = null;
      }
      const path = "models-onnx/" + model.file;
      this.session = await ort.InferenceSession.create(path, {
        executionProviders: ["webgpu"],
        graphOptimizationLevel: "all"
      });
      this.active = model;
    }

    async process(rgba, w, h, model, onProgress) {
      await this.loadModel(model);
      const scale = model.scale;
      const TILE = model.tilesize;
      const PAD = model.prepadding;
      const align = model.align || 1;

      // Fixed input size for ALL tiles — required by ORT WebGPU buffer reuse.
      let inSize = TILE + 2 * PAD;
      if (align > 1) {
        inSize += (align - (inSize % align)) % align;
      }

      const outW = w * scale;
      const outH = h * scale;
      const out = new Uint8ClampedArray(outW * outH * 4);

      const xtiles = Math.ceil(w / TILE);
      const ytiles = Math.ceil(h / TILE);
      const total = xtiles * ytiles;
      const t0 = performance.now();

      for (let yi = 0; yi < ytiles; yi++) {
        const tileY = yi * TILE;
        const tileH = Math.min(TILE, h - tileY);
        for (let xi = 0; xi < xtiles; xi++) {
          const tileT0 = performance.now();
          const tileX = xi * TILE;
          const tileW = Math.min(TILE, w - tileX);

          const data = extractFixedTileNCHW(rgba, w, h, tileX, tileY, tileW, tileH, PAD, inSize);
          const tensor = new ort.Tensor("float32", data, [1, 3, inSize, inSize]);
          const feeds = {};
          feeds[model.input] = tensor;
          const results = await this.session.run(feeds);
          const outTensor = results[model.output];
          writeTileFromFixedOutput(out, outW, outH, scale, tileX, tileY, tileW, tileH, PAD, outTensor);

          // Release GPU output buffer if owned by ORT (helps with mem pressure).
          try {
            if (outTensor && typeof outTensor.dispose === "function") outTensor.dispose();
          } catch (_) {}

          const done = yi * xtiles + xi + 1;
          const totalCost = performance.now() - t0;
          const tileCost = performance.now() - tileT0;
          const rate = done / total;
          if (onProgress) {
            onProgress({
              progress_rate: rate,
              total_cost: totalCost,
              tile_cost: tileCost,
              remaining_time: rate > 0 ? totalCost / rate - totalCost : 0
            });
          }
        }
      }

      return { rgba: out, width: outW, height: outH, cost: performance.now() - t0 };
    }
  }

  global.RealESRGANWebGPU = RealESRGANWebGPU;
})(typeof window !== "undefined" ? window : self);
