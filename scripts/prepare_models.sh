#!/usr/bin/env bash
# Prepare the four production models shared by CPU and WebGPU.
set -euo pipefail
"$(dirname "$0")/download_models.sh"
"$(dirname "$0")/prepare_webgpu_models.sh" --skip-x2plus
python3 - <<'PY'
import json
p='web/models-onnx/manifest.json'; d=json.load(open(p)); keep={'realesr-general-x4v3','realesr-animevideov3-x4','realesrgan-x4plus','realesrgan-x4plus-anime'}; d['models']=[m for m in d['models'] if m['name'] in keep and m['scale']==4]; assert {m['name'] for m in d['models']} == keep; open(p,'w').write(json.dumps(d,indent=2)+'\n')
PY
# Remove stale optional models when this script is used.
find models -maxdepth 1 -type f \( -name 'realesr-animevideov3-x2.*' -o -name 'realesr-animevideov3-x3.*' -o -name 'realesrgan-x2plus.*' \) -delete
find web/models-onnx -maxdepth 1 -type f \( -name 'realesr-animevideov3-x2.onnx' -o -name 'realesr-animevideov3-x3.onnx' -o -name 'realesrgan-x2plus.onnx' \) -delete
