# Witzper

A fully local, open-source dictation system for macOS Apple Silicon. Built to match or exceed Wispr Flow on latency and quality, with zero cloud dependency.

## System requirements

This is a **heavy** local-AI app — it runs a 30B-parameter MoE language model and a 0.6B ASR model in unified memory. Plan accordingly.

### Minimum (works but tight)
- **Mac**: Apple Silicon (M1 or newer). Intel Macs are not supported.
- **macOS**: 14.0 (Sonoma) or later — required for the SwiftUI dashboard and modern AVCaptureDevice APIs.
- **RAM**: **32 GB unified memory**. The default cleanup model (Qwen3-30B-A3B-Instruct, 8-bit) needs ~32 GB resident. With 32 GB total you'll be near the swap line; close other heavy apps.
- **Disk**: **40 GB free** for model weights in `~/.cache/huggingface/hub/`:
  - Parakeet TDT v3: ~1.2 GB
  - Qwen3-30B-A3B 8-bit: ~32 GB
  - pyannote/Silero VAD + MiniLM embedder: ~400 MB
  - working set / SQLite / audio cache: a few hundred MB

### Recommended (the "no compromise" target)
- **Mac**: M3 Max / M4 Max / **M5 Max** (this is what Witzper is tuned for) or M-series Ultra.
- **RAM**: **64 GB**. Comfortable headroom for the cleanup LLM, the ASR model, the Swift dashboard, plus everything else you have open. End-to-end latency lands at ~300–600 ms p50.
- **Disk**: **80 GB free** if you also want the optional Command Mode model (Qwen3-235B-A22B 4-bit, ~120 GB on disk; loaded only on demand).

### Maxed out (Command Mode + future ASR LoRA training)
- **Mac**: M-series Max with **128 GB** unified memory (e.g. M5 Max 128 GB — the dev target).
- **RAM**: **128 GB**. Lets you keep the 30B cleanup model warm AND load Qwen3-235B-A22B for "rewrite as email / restructure / translate" command mode without unloading.
- **Disk**: **200 GB free** for both base models + accumulated correction store + nightly LoRA checkpoints + audio cache.

### Runtime resident memory (steady state)
| Component                                | RAM    |
|------------------------------------------|--------|
| Qwen3-30B-A3B-Instruct-2507 (8-bit)      | ~32 GB |
| Parakeet TDT 0.6B v3                     | ~1 GB  |
| MiniLM few-shot embedder                 | ~150 MB |
| Silero VAD                               | ~50 MB |
| Witzper.app (Swift menu-bar + dashboard) | ~80 MB |
| Python daemon overhead + activations     | ~3 GB  |
| **Total hot path**                       | **~36 GB** |
| + Command Mode (Qwen3-235B-A22B 4-bit, lazy-loaded) | +100 GB |

### Other things you'll need
- **Xcode Command Line Tools** (for building the Swift menu-bar helper): `xcode-select --install`
- **Python 3.11+** (Witzper uses 3.13 by default; 3.11 and 3.12 also work). Install via `brew install python@3.13`.
- **Homebrew** for installing dependencies. Install from <https://brew.sh>.
- **ffmpeg** (`brew install ffmpeg`) — `parakeet-mlx` shells out to ffmpeg to decode audio.
- **A microphone**. Built-in MacBook mic works fine; external mics improve accuracy noticeably.
- **macOS permissions** that you must grant Witzper.app on first run:
  - **Accessibility** (for global hotkey + reading the focused text field for context)
  - **Input Monitoring** (for `CGEventTap`)
  - **Microphone** (auto-prompted on first audio capture)

### Network
- **First run only**: ~40 GB download from Hugging Face Hub for model weights.
- **After that**: zero network. Witzper does not call any cloud API, ever. Your audio, transcripts, dictionary, and snippets never leave your machine.

## Stack

- **ASR (accuracy mode)**: Qwen3-ASR (MLX port) — context-conditioned, multilingual, code-switching
- **ASR (speed mode)**: NVIDIA Parakeet TDT 0.6B v3 via `parakeet-mlx` — 10× faster than Whisper Large v3
- **VAD**: pyannote segmentation 3.1
- **LLM cleanup (hot path)**: `mlx-community/Qwen3-30B-A3B-Instruct-2507-8bit` — 30B MoE, ~3B active, sub-250 ms on M5 Max
- **LLM command mode (heavy)**: `mlx-community/Qwen3-235B-A22B-Instruct-2507-4bit` — for rewrite-as-email, restructure, translate
- **Personalization**: nightly LoRA fine-tune of cleanup model, biweekly LoRA of ASR, DSPy prompt optimization, auto-learning dictionary
- **Hotkey + input**: Swift `CGEventTap` helper over XPC + Python inference daemon

## Target performance (M5 Max, 128 GB)

| Mode | End-to-end p50 |
|---|---|
| Speed (Parakeet + Qwen3-30B-A3B) | 200–350 ms |
| Accuracy (Qwen3-ASR + Qwen3-30B-A3B) | 350–600 ms |
| Command (Qwen3-235B-A22B) | 2–5 s |

## Layout

```
Witzper/
├── flow/                    # Python inference daemon
│   ├── core/                # Orchestration, hotkey, audio, VAD
│   ├── models/              # ASR + LLM wrappers (Qwen3-ASR, Parakeet, Qwen3-30B, Qwen3-235B)
│   ├── context/             # Focused-app context, dictionary, few-shot retrieval
│   ├── insert/              # Clipboard-paste + keystroke fallback
│   ├── personalize/         # Edit-watch, corrections store, LoRA fine-tune, DSPy
│   └── ui/                  # Menu-bar pill, notifications
├── swift-helper/            # Swift CGEventTap + AXUIElement XPC helper
├── scripts/                 # setup, download-models, train-lora, run
├── configs/                 # default.toml, models.toml
├── tests/
├── data/                    # local SQLite (corrections, dictionary) — gitignored
└── .github/workflows/       # CI (lint, tests, package)
```

## Quick start

```bash
./scripts/setup.sh            # installs Python deps, builds Swift helper
./scripts/download_models.sh  # prefetches Parakeet v3 + Qwen3-30B-A3B (~40 GB)
./scripts/run.sh              # starts the daemon; hold Fn to dictate
```

See [`docs/architecture.md`](docs/architecture.md) for the full pipeline walkthrough.

## Status

**Scaffold** — end-to-end pipeline wired but each component is a minimal first pass. See `TODO.md` for the build-out order.

## License

MIT
