#!/usr/bin/env bash
set -euo pipefail

# Prefetch the model weights used by Witzper. These go into the HF hub cache
# (~/.cache/huggingface/hub) so MLX can load them without a network trip.
#
# Default set ~= 40 GB:
#   Parakeet v3                                  ~1 GB
#   Qwen3-30B-A3B-Instruct-2507 8-bit            ~32 GB
#   pyannote segmentation 3.1                    ~200 MB
#   MiniLM-L6 sentence embedder                  ~100 MB
#
# Optional (Command Mode, requires ≥128 GB unified memory):
#   Qwen3-235B-A22B-Instruct-2507 4-bit          ~120 GB

# Auto-activate venv if present
if [[ -f "$(dirname "$0")/../.venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/../.venv/bin/activate"
fi
python -m pip install -q "huggingface_hub[cli]" 2>/dev/null || true

echo "→ Parakeet TDT v3 (speed mode ASR)"
hf download mlx-community/parakeet-tdt-0.6b-v3

echo "→ Qwen3-30B-A3B-Instruct-2507 8-bit (cleanup LLM)"
hf download mlx-community/Qwen3-30B-A3B-Instruct-2507-8bit

echo "→ pyannote segmentation 3.1 (VAD, optional — requires HF auth + license accept)"
hf download pyannote/segmentation-3.1 2>/dev/null || \
  echo "  skipped (not authenticated; Silero will be used instead)"

echo "→ MiniLM-L6-v2 (few-shot embedder)"
hf download sentence-transformers/all-MiniLM-L6-v2

if [[ "${FLOW_DOWNLOAD_COMMAND_MODEL:-0}" == "1" ]]; then
  echo "→ Qwen3-235B-A22B-Instruct-2507 4-bit (command mode, ~120 GB)"
  hf download mlx-community/Qwen3-235B-A22B-Instruct-2507-4bit
fi

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
