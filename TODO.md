# TODO

The scaffold wires the full pipeline end-to-end. Each component is a
minimal-but-runnable first pass; the work below is what turns it into a
production-quality app.

## Recently shipped (this pass)

- [x] Full A-to-Z audit of Swift helper + Python daemon + build & CI
- [x] Kill the random Accessibility popup on every launch (silent probe +
      centralized `Permissions` + `PermissionWatcher`)
- [x] Reactive onboarding with auto-advance when the user flips a
      permission toggle in System Settings
- [x] Live mic meter during onboarding (`LiveMicMeter.swift`) so the user
      sees their voice register before leaving the wizard
- [x] Press-a-key hotkey picker (`HotkeyCapture.swift`) — replaces the
      legacy dropdown; full `HotkeyName` translator for fn / right_option
      / f-keys / modifier pairs
- [x] New onboarding structure: Welcome → Accessibility → Input Monitoring
      → Microphone (with live meter) → Hotkey → Models → Ready checklist
- [x] Menu-bar SF Symbols + pulse animation + dynamic hotkey label
- [x] Dashboard: bundle-driven version, richer empty state, one-click
      Export Transcripts
- [x] Download progress with real MB/s rate, ETA, GB/GB counter
- [x] Parakeet ASR: skip the tempfile-per-call I/O (numpy → mx.array →
      get_logmel → generate), warmup pass on init
- [x] Incremental streaming partials via `transcribe_stream` —
      partial-ASR loop is now O(delta), not O(total-so-far)
- [x] Cleanup LLM fast-path: skip the 50-80 ms LLM pass for ultra-short
      utterances (new `passthrough_word_count` cfg)
- [x] Cached encoded prefix IDs to shave re-tokenization per cleanup call

## P0 — get it running

- [ ] `./scripts/setup.sh` — verify on this M5 Max
- [ ] `./scripts/download_models.sh` — fetch Parakeet + Qwen3-30B-A3B (~33 GB)
- [ ] `./scripts/run.sh` — confirm hotkey → audio → ASR → cleanup → paste works
- [ ] Grant Accessibility + Input Monitoring perms to `flow-helper`
- [ ] `flow doctor` passes all checks

## P1 — Qwen3-ASR accuracy mode

- [ ] Vendor the community `qwen3-asr-mlx` port; pin the commit
- [ ] Wire context_prompt into `Qwen3ASR.transcribe` with real API signature
- [ ] Benchmark accuracy vs Parakeet on a held-out set of your own dictation
- [ ] Auto-switch mode based on utterance length (<5 words → speed)

## P1 — Swift helper polish

- [ ] Replace right-option with Fn via IOHIDManager (low-level HID, bypasses CGEventTap's inability to see Fn)
- [ ] AX snapshot: add retry + caching (~50 ms TTL) so repeated snapshots don't stall
- [ ] Menu-bar UI: status item with model loaded, last utterance latency, dictionary size
- [ ] Floating pill window (SwiftUI overlay) driven by socket state
- [ ] Launch-at-login via SMAppService
- [ ] Universal binary + codesign + notarize

## P1 — Edit watcher

- [ ] Swift helper exposes an AX "poll field contents" RPC so Python can read the focused text field without AppleScript
- [ ] Debounce + compute proper diff (Myers) instead of string equality
- [ ] Skip text fields with secure input (password fields)

## P2 — Personalization

- [ ] Nightly LoRA cron via launchd plist (generated from cron string in config)
- [ ] DSPy prompt optimizer against a held-out validation set
- [ ] Adapter A/B — maintain two adapters, auto-promote the better one on validation
- [ ] ASR LoRA: integrate with Qwen3-ASR trainer once the MLX port exposes one

## P2 — Command Mode

- [ ] Separate hotkey (right_cmd+right_option) triggers Command Mode using the shared cleanup LLM
- [ ] Grab selected text from AX on trigger, treat dictation as instruction
- [ ] Insert result as replacement (not paste) — needs AX `AXSelectedText` setter

## P2 — Quality

- [ ] Alt-hypothesis rerank: feed ASR top-N into cleanup LLM as a reranking task
- [ ] Sub-vocal / whisper-quiet speech support: tune pyannote thresholds + record labeled examples
- [ ] Code-switching eval on mixed-language utterances

## P3 — Nice-to-have

- [ ] iCloud Drive sync of dictionary across devices
- [ ] Import/export dictionary CSV
- [ ] Waveform/RMS-driven pill animation
- [ ] Optional cloud model passthrough (e.g. hit Claude API for Command Mode on big tasks) — **off by default, never on hot path**
- [ ] Linux port (X11/Wayland hotkey, portaudio)
