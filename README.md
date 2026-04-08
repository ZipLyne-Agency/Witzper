# flow-local

A fully local, open-source dictation system for macOS Apple Silicon. Built to match or exceed Wispr Flow on latency and quality, with zero cloud dependency.

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
flow-local/
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
