#!/usr/bin/env bash
set -euo pipefail

# Prefetch the model weights used by Witzper. These go into the HF hub cache
# (~/.cache/huggingface/hub) so MLX can load them without a network trip.
#
# Default set ~= 7 GB:
#   Parakeet v3                                  ~1 GB
#   Qwen3-8B cleanup model                       ~5 GB
# Optional heavier models can be selected later from the dashboard.

# Auto-activate venv if present
if [[ -f "$(dirname "$0")/../.venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/../.venv/bin/activate"
fi
python -m pip install -q "huggingface_hub[cli]" 2>/dev/null || true

echo "→ Parakeet TDT v3 (speed mode ASR)"
hf download mlx-community/parakeet-tdt-0.6b-v3

echo "→ Qwen3-8B 4-bit (default cleanup LLM)"
hf download mlx-community/Qwen3-8B-4bit

echo "→ pyannote segmentation 3.1 (VAD, optional — requires HF auth + license accept)"
hf download pyannote/segmentation-3.1 2>/dev/null || \
  echo "  skipped (not authenticated; Silero will be used instead)"

echo
echo "→ Qwen3-ASR MLX (accuracy mode ASR) — manual step"
echo "  The community MLX port is published as a GitHub repo. Clone it and"
echo "  install it into the venv:"
echo
echo "    git clone https://github.com/<community>/qwen3-asr-mlx"
echo "    pip install -e ./qwen3-asr-mlx"
echo
echo "  Then set asr.mode = 'accuracy' or 'auto' in your config."
echo "  Until then, Witzper will run with Parakeet only (speed mode)."
echo
echo "✔ downloads complete"
