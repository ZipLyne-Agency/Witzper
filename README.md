# Witzper

A fully local, open-source dictation system for macOS Apple Silicon. Built to match or exceed Wispr Flow on latency and quality, with zero cloud dependency. Push-to-talk anywhere on your Mac → speech gets transcribed, cleaned up by a local LLM, and pasted into the focused text field. Your audio, transcripts, dictionary, and corrections never leave your machine.

---

## What Witzper actually does

1. You hold a hotkey (default: **Fn**).
2. A Swift menu-bar helper captures the keypress via `CGEventTap` and grabs context from the focused text field via `AXUIElement` (app name, window title, surrounding text).
3. Audio is recorded at 16 kHz mono and trimmed by a voice-activity detector.
4. The audio is transcribed by a local ASR model (Parakeet by default, optionally Qwen3-ASR or Whisper).
5. The raw transcript is cleaned up by a local MLX LLM — using a per-app *Flow Style* instruction, top-N few-shot examples retrieved from your own corrections, and your personal dictionary as vocabulary boost.
6. Deterministic dictionary replacements and voice snippets are applied.
7. The result is pasted into the focused field (or typed, for terminals / password fields).
8. An edit watcher observes the field for N seconds — any edit you make becomes a training pair for nightly LoRA fine-tuning of the cleanup model (and biweekly LoRA of the ASR model).

Everything runs on MLX on Apple Silicon. No network calls after the first model download.

---

## System requirements

Witzper runs real 30B-parameter models in unified memory. Plan accordingly.

### Minimum
- **Mac**: Apple Silicon (M1 or newer). Intel is not supported.
- **macOS**: 14.0 Sonoma or later.
- **RAM**: 16 GB — only if you swap the default cleanup model for a smaller one (Qwen3 4B / Llama 3.2 3B). The default 30B model will not fit.
- **Disk**: 5–10 GB for a small-model setup.

### Recommended
- **Mac**: M3/M4 Max or M-series Ultra.
- **RAM**: 64 GB. Runs the default Qwen3-30B-A3B cleanup + Parakeet ASR comfortably. End-to-end p50 ~300–600 ms.
- **Disk**: 40 GB for the default model set.

### Maxed out (dev target: M5 Max 128 GB)
- **RAM**: 128 GB. Keeps the 30B cleanup model hot AND loads Qwen3-235B-A22B for Command Mode without unloading.
- **Disk**: 200 GB for every model in the catalog + correction store + nightly LoRA checkpoints.

### Runtime resident memory (default config, steady state)
| Component                                | RAM     |
|------------------------------------------|---------|
| Qwen3-30B-A3B-Instruct-2507 (8-bit)      | ~32 GB  |
| Parakeet TDT 0.6B v3                     | ~1 GB   |
| MiniLM few-shot embedder                 | ~150 MB |
| Silero VAD                               | ~50 MB  |
| Witzper.app (Swift menu-bar + dashboard) | ~80 MB  |
| Python daemon overhead + activations     | ~3 GB   |
| **Total hot path**                       | **~36 GB** |
| + Command Mode (Qwen3-235B-A22B 4-bit, lazy) | +100 GB |

### Other prerequisites
- **Xcode Command Line Tools**: `xcode-select --install`
- **Python 3.11+** (3.13 default). `brew install python@3.13`
- **Homebrew** — <https://brew.sh>
- **ffmpeg** — `brew install ffmpeg` (parakeet-mlx shells out for audio decode)
- **Microphone** — built-in works; externals improve accuracy.
- **macOS permissions** on first run: **Accessibility**, **Input Monitoring**, **Microphone**.

### Network
- **First run only**: model downloads from Hugging Face Hub (~5–40 GB depending on your chosen model set).
- **After that**: zero network. No telemetry, ever.

---

## Install & run

```bash
./scripts/setup.sh            # Python venv + deps + Swift helper build
./scripts/download_models.sh  # prefetch default model set (~40 GB)
./scripts/run.sh              # starts Swift helper + Python daemon
```

`run.sh` launches the first-run hotkey wizard if no user config exists at `~/.config/Witzper/config.toml`, then starts the Swift menu-bar helper and the Python daemon. Hold your hotkey to dictate.

See [`docs/architecture.md`](docs/architecture.md) for the full pipeline walkthrough.

---

## CLI (`flow`)

After `setup.sh` the `flow` command lives inside `.venv`. Everything the daemon does is also scriptable:

| Command | What it does |
|---|---|
| `flow run [-v]` | Start the dictation daemon. `-v` prints per-stage latency. |
| `flow setup` | Interactive first-run wizard (pick your push-to-talk hotkey). |
| `flow doctor` | Check models, permissions, Swift helper, audio devices. |
| `flow dict --add <word>` | Add a vocabulary boost word. |
| `flow dict --replace 'wrong=right'` | Add a deterministic replacement rule. |
| `flow dict --remove <term>` | Remove a boost word or replacement. |
| `flow dict --list` | Show the full dictionary. |
| `flow snippet --add '<trigger>' --text '<expansion>'` | Add a voice snippet (e.g. `'my address' → '123 Main St'`). |
| `flow snippet --remove '<trigger>'` | Remove a snippet. |
| `flow snippet --list` | Show all snippets. |
| `flow style` | Show current Flow Styles per category. |
| `flow style <category> <name>` | Set a style (see *Flow Styles* below). |
| `flow train cleanup` | Manually run a LoRA fine-tune of the cleanup LLM on accumulated corrections. |
| `flow train asr` | Manually run a LoRA fine-tune of the ASR model. |

---

## Models

Witzper has three model **roles**. Each role has a catalog of swappable options (see `swift-helper/Sources/FlowHelper/ModelCatalog.swift` — the dashboard's Settings tab is driven by this list). You can override any model by editing `~/.config/Witzper/config.toml` or by using the dashboard picker.

### 1. Cleanup LLM (hot path, per-utterance)

The language model that fixes grammar, punctuation, and applies your Flow Style. Runs on every utterance, so latency matters.

| Model ID | Label | RAM | ~Latency | Quality | Notes |
|---|---|---|---|---|---|
| `juanquivilla/sotto-cleanup-lfm25-350m-mlx-4bit` | Sotto Cleanup 350M | 0.2 GB | 30 ms | ★★★★ | Purpose-built for transcript cleanup. 200 MB. Insanely fast. |
| `mlx-community/Llama-3.2-1B-Instruct-4bit` | Llama 3.2 1B | 0.7 GB | 40 ms | ★★★ | Tiny + fast. Good for low-RAM Macs. |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | Llama 3.2 3B | 2 GB | 70 ms | ★★★ | Solid baseline. |
| `mlx-community/Qwen3-4B-Instruct-2507-4bit` | Qwen3 4B | 2.5 GB | 80 ms | ★★★★ | Excellent default for 16 GB Macs. |
| `mlx-community/Qwen3-8B-Instruct-2507-4bit` | Qwen3 8B | 5 GB | 120 ms | ★★★★ | Headroom for tougher transcripts. |
| `mlx-community/Qwen3-14B-Instruct-2507-8bit` | Qwen3 14B | 15 GB | 180 ms | ★★★★★ | Sweet spot for 32–64 GB Macs. |
| `mlx-community/Qwen3-30B-A3B-Instruct-2507-8bit` | **Qwen3 30B-A3B (default)** | 32 GB | 250 ms | ★★★★★ | 30B MoE, 3B active per token. Witzper's default. |

### 2. ASR (speech-to-text)

| Model ID | Label | RAM | ~Latency | Notes |
|---|---|---|---|---|
| `mlx-community/parakeet-tdt-0.6b-v3` | **Parakeet TDT 0.6B v3 (default)** | 1 GB | 80 ms | 10× faster than Whisper Large v3. 25 languages. |
| `mlx-community/whisper-large-v3-turbo` | Whisper Large v3 Turbo | 3 GB | 200 ms | 100+ languages. Use for non-Parakeet langs. |
| `mlx-community/whisper-large-v3-mlx` | Whisper Large v3 (full) | 6 GB | 500 ms | Highest-quality Whisper. |
| `mlx-community/whisper-medium-mlx` | Whisper Medium | 1.5 GB | 250 ms | English-focused. |
| `mlx-community/Qwen3-ASR` | Qwen3-ASR (accuracy mode) | ~4 GB | 150–300 ms | Accepts a text context prompt — enables Wispr-style context-conditioned recognition. Lazy-loaded when `asr.mode = "accuracy"`. |

**ASR mode selection** (`[asr] mode = ...` in config):
- `speed` — always use Parakeet (no context prompt).
- `accuracy` — always use Qwen3-ASR with full app/window/dictionary context injection.
- `auto` — pick per-app based on `configs/app_rules.toml` (e.g. accuracy mode in Mail, speed mode in iMessage).

### 3. Command Mode (heavy, lazy-loaded)

A separate hotkey (default `right_cmd+right_option`) triggers Command Mode: "rewrite this as an email", "translate to Spanish", "restructure as bullets". The model is loaded on first use and kept warm.

| Model ID | Label | RAM | Notes |
|---|---|---|---|
| `mlx-community/Qwen3-14B-Instruct-2507-4bit` | Qwen3 14B (light) | 8 GB | Light Command Mode for 32 GB Macs. |
| `mlx-community/Qwen3-30B-A3B-Instruct-2507-8bit` | Qwen3 30B-A3B (shared) | 0 GB extra | Reuses the cleanup model — zero extra RAM. |
| `mlx-community/Qwen3-235B-A22B-Instruct-2507-4bit` | **Qwen3 235B-A22B (default heavy)** | 100 GB | 22B active params. Claude/GPT-class output. Needs 128 GB. |

### Auxiliary models (always on)
- **VAD**: Silero (default, ungated) or `pyannote/segmentation-3.1` (requires HF license accept). Set in `[vad]`.
- **Few-shot embedder**: MiniLM via `sentence-transformers` — embeds raw transcripts to retrieve the top-N most similar past corrections at inference time.

---

## Flow Styles

Styles control **formatting only** — never grammar or word choice. Witzper has four app categories and four styles. The default ships all categories set to **casual** (the recommended setup).

**Categories** — matched via `configs/app_categories.toml`:
- `personal_messages` — iMessage, WhatsApp, Telegram, Signal, Discord
- `work_messages` — Slack, Teams, Zoom chat
- `email` — Mail, Gmail, Outlook, Superhuman
- `other` — everything else

**Styles** — defined in `flow/context/styles.py`:
- `formal` — Capitalize sentences and proper nouns; full punctuation.
- `casual` (default) — Capitalize first word + proper nouns; light punctuation; **drop trailing period**; use question marks where needed.
- `very_casual` — ALL LOWERCASE, even sentence starts; drop trailing period; keep question marks.
- `excited` — Normal capitalization; liberal use of `!`.

Set a style:
```bash
flow style                          # show current
flow style personal_messages casual
flow style email formal
```

---

## Dictionary & snippets

- **Boost terms**: raw vocabulary words (names, acronyms, jargon) injected into the ASR context prompt to improve recognition. Auto-learned from single-token edits within edit distance 2.
- **Replacements**: deterministic `wrong → right` substitutions applied after LLM cleanup.
- **Snippets**: voice → text expansion. Triggered case-insensitively on whole words; if a transcript is *just* the trigger phrase, the trailing punctuation is stripped before matching.

All three are stored in a local SQLite database under `~/.local/share/Witzper/` and are also editable from the dashboard's Dictionary and Snippets tabs.

---

## Personalization loop

1. **Edit watcher** — polls the focused field for `edit_watch_window_seconds` after insertion. Any edit you make within the window is stored as a `(raw_transcript, inserted_text, final_text, audio)` row.
2. **Few-shot retriever** — embeds raw transcripts with MiniLM; returns top-N most similar past pairs at inference time. Quality improves with every correction, no training required.
3. **Nightly cleanup LoRA** — `mlx-lm` trains a rank-16 LoRA adapter over all `(raw → final)` pairs. Scheduled via cron `0 3 * * *`. Adapter hot-swaps without reloading the base model.
4. **Biweekly ASR LoRA** — rank-8 LoRA over `(audio → final_text)` pairs. Cron `0 4 */14 * *`.
5. **DSPy prompt optimization** (optional) — evolves the cleanup system prompt against a held-out validation set.
6. **Dictionary auto-learn** — single-token edits within edit distance ≤2 append to the boost dictionary automatically.

All knobs live under `[personalization]` in `configs/default.toml`.

---

## Dashboard (Witzper.app)

The Swift menu-bar helper also hosts a SwiftUI dashboard with tabs:
- **Live** — real-time transcript stream + per-stage latency (vad / asr / llm / total) via a Unix domain socket.
- **Dictionary** — browse / add / remove boost words and replacement rules.
- **Snippets** — manage voice snippets.
- **Settings** — model picker driven by `ModelCatalog.swift` (swap cleanup / ASR / command models), hotkey picker, style picker per category.
- **HUD** — floating pill that appears during recording.

---

## Configuration

Defaults live in `configs/default.toml`. User overrides go in `~/.config/Witzper/config.toml` — only the keys you want to change.

Key sections:

```toml
[hotkey]
key = "fn"              # "fn" | "right_option" | "right_cmd" | "caps_lock"
toggle_mode = false     # true = tap-to-toggle instead of hold-to-talk

[audio]
sample_rate = 16000
channels = 1
device = "default"
max_seconds = 120       # safety cap per utterance

[vad]
backend = "silero"      # "silero" (default) | "pyannote"
endpoint_silence_ms = 700

[asr]
mode = "auto"           # "speed" | "accuracy" | "auto"

[asr.speed]
model = "mlx-community/parakeet-tdt-0.6b-v3"
backend = "parakeet-mlx"

[asr.accuracy]
model = "mlx-community/Qwen3-ASR"
backend = "qwen3-asr-mlx"
context_prompt_max_tokens = 1024

[cleanup]
model = "mlx-community/Qwen3-30B-A3B-Instruct-2507-8bit"
max_tokens = 96
temperature = 0.0
few_shot_n = 5
max_length_ratio = 1.8          # hallucination guard: fall back to raw if exceeded
max_edit_distance_ratio = 0.5

[command]
enabled = true
model = "mlx-community/Qwen3-235B-A22B-Instruct-2507-4bit"
max_tokens = 2048
hotkey = "right_cmd+right_option"

[insertion]
default_strategy = "paste"       # "paste" | "type"
restore_clipboard_after_ms = 200

[personalization]
auto_add_to_dictionary = true
edit_watch_window_seconds = 10
cleanup_lora_enabled = true
cleanup_lora_rank = 16
cleanup_lora_schedule_cron = "0 3 * * *"
asr_lora_enabled = true
asr_lora_rank = 8
asr_lora_schedule_cron = "0 4 */14 * *"
dspy_enabled = true

[styles]
personal_messages = "casual"
work_messages = "casual"
email = "casual"
other = "casual"

[snippets]
case_insensitive = true
strip_trailing_punct_on_solo_trigger = true

[telemetry]
enabled = false          # locked off; Witzper has zero telemetry
```

---

## Target performance (M5 Max, 128 GB)

| Mode | Components | End-to-end p50 |
|---|---|---|
| Speed | Parakeet + Qwen3-30B-A3B | 200–350 ms |
| Accuracy | Qwen3-ASR + Qwen3-30B-A3B | 350–600 ms |
| Command | Qwen3-235B-A22B | 2–5 s |

Latency budget breakdown:

| Stage | Target |
|---|---|
| VAD endpoint trim | ≤30 ms |
| ASR (Parakeet v3) | 40–80 ms |
| ASR (Qwen3-ASR) | 150–300 ms |
| Cleanup LLM (Qwen3-30B) | 150–250 ms |
| Insertion | ≤10 ms |

---

## Layout

```
Witzper/
├── flow/                        # Python inference daemon
│   ├── __main__.py              # `flow` CLI entry point
│   ├── config.py                # TOML loader + pydantic config
│   ├── core/
│   │   ├── orchestrator.py      # hotkey → audio → VAD → ASR → cleanup → insert → edit-watch
│   │   ├── audio.py             # sounddevice capture
│   │   ├── vad.py               # Silero / pyannote wrappers
│   │   ├── hotkey.py            # pynput fallback (Swift helper preferred)
│   │   ├── doctor.py            # `flow doctor`
│   │   └── setup_wizard.py      # first-run hotkey picker
│   ├── models/
│   │   ├── asr_base.py          # ASR backend protocol
│   │   ├── parakeet.py          # Parakeet v3 backend
│   │   ├── whisper_mlx.py       # Whisper backend
│   │   ├── qwen3_asr.py         # Qwen3-ASR backend (context-conditioned)
│   │   ├── cleanup.py           # Cleanup LLM (mlx-lm)
│   │   └── command.py           # Command Mode LLM (lazy)
│   ├── context/
│   │   ├── app_context.py       # focused-app snapshot via Swift helper AXUIElement
│   │   ├── dictionary.py        # boost + replacement SQLite store
│   │   ├── few_shot.py          # MiniLM retriever over corrections
│   │   └── styles.py            # Flow Styles resolver
│   ├── insert/
│   │   └── inserter.py          # clipboard paste + keystroke fallback
│   ├── personalize/
│   │   ├── store.py             # CorrectionStore (SQLite)
│   │   ├── edit_watch.py        # post-insertion edit capture
│   │   ├── snippets.py          # voice-snippet store + expansion
│   │   └── train_lora.py        # mlx-lm LoRA training for cleanup + ASR
│   └── ui/
│       ├── pill.py              # floating HUD pill
│       └── stream.py            # Unix-socket event stream → dashboard
├── swift-helper/                # Swift menu-bar + dashboard
│   └── Sources/FlowHelper/
│       ├── main.swift
│       ├── Dashboard.swift      # Live / Dict / Snippets / Settings tabs
│       ├── HUD.swift            # recording pill
│       ├── Inserter.swift       # CGEvent-based paste/type
│       ├── ModelCatalog.swift   # the swappable model list above
│       ├── ModelPickerView.swift
│       ├── SettingsView.swift
│       ├── DictionaryView.swift
│       ├── SnippetsView.swift
│       ├── SQLiteStore.swift
│       └── Sounds.swift
├── configs/
│   ├── default.toml             # all defaults
│   ├── app_categories.toml      # app → style category rules
│   └── app_rules.toml           # app → ASR mode rules (auto)
├── scripts/
│   ├── setup.sh                 # venv + deps + Swift build
│   ├── download_models.sh       # HF prefetch
│   ├── run.sh                   # launch helper + daemon
│   ├── build_app.sh             # package Witzper.app
│   ├── build_icon.py            # .icns generator
│   ├── test_pipeline.py         # end-to-end smoke test
│   └── train_nightly.sh         # cron entry for LoRA training
├── docs/architecture.md
├── assets/                      # app icon + iconset
├── IDEAS.md                     # feature backlog
├── TODO.md                      # build-out order
└── .github/workflows/ci.yml
```

---

## What goes over the network

Nothing. All inference is local MLX, all storage is local SQLite + local audio under `~/.local/share/Witzper/`. The Swift helper's sockets are Unix domain sockets mode 0600. No telemetry, no cloud models, no account required. `[telemetry] enabled = false` is the only supported value.

---

## Status

**Scaffold** — end-to-end pipeline is wired but each component is a minimal first pass. See `TODO.md` for the build-out order and `IDEAS.md` for the feature backlog.

## License

MIT
