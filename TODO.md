# TODO

The scaffold wires the full pipeline end-to-end. Each component is a
minimal-but-runnable first pass; the work below is what turns it into a
production-quality app.

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

- [ ] Separate hotkey (right_cmd+right_option) loads Qwen3-235B-A22B lazily
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
