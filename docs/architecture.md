# Architecture

## The pipeline

```
┌──────────────────────────────────────────────────────────────┐
│ Swift helper (menu-bar, Accessibility perms)                 │
│   CGEventTap → hotkey_down / hotkey_up  → /tmp/Witzper.sock│
│   AXUIElement → {app, window, surrounding, selected}          │
│                                          → /tmp/flow-context.sock│
└───────────────┬──────────────────────────┬───────────────────┘
                │                          │
                ▼                          ▼
        ┌──────────────┐           ┌──────────────┐
        │ HotkeyListener│          │ AppContext    │
        └──────┬────────┘          └──────┬────────┘
               │                          │
               ▼                          │
      ┌────────────────┐                  │
      │ AudioCapture   │                  │
      │ 16 kHz mono    │                  │
      └────────┬───────┘                  │
               │                          │
               ▼                          │
      ┌────────────────┐                  │
      │ VAD (pyannote) │                  │
      └────────┬───────┘                  │
               │                          │
               ▼                          │
      ┌──────────────────┐                │
      │ ASR              │◄───────────────┤
      │  speed: Parakeet │   context_prompt
      │  accuracy: Qwen3 │   (app, window, surrounding, boost terms)
      │  v3 → text + alts│                │
      └────────┬─────────┘                │
               │                          │
               ▼                          │
      ┌────────────────────┐              │
      │ FewShotRetriever   │              │
      │ top-N from local DB│              │
      └────────┬───────────┘              │
               │                          │
               ▼                          │
      ┌──────────────────────────────┐    │
      │ CleanupLLM                   │◄───┘
      │ Qwen3-30B-A3B 8-bit (MLX)    │
      │ + system rules               │
      │ + dynamic N=5 few-shots      │
      │ + tone priming per app       │
      │ + alt-hypothesis rerank      │
      └────────┬─────────────────────┘
               │
               ▼
      ┌──────────────────────┐
      │ Hallucination guard  │ — fallback to raw if ratio exceeded
      └────────┬─────────────┘
               │
               ▼
      ┌──────────────────────┐
      │ Dictionary replace    │ — deterministic wrong→right rules
      └────────┬─────────────┘
               │
               ▼
      ┌──────────────────────┐
      │ Inserter             │ — clipboard paste (or keystroke for terminals)
      └────────┬─────────────┘
               │
               ▼
      ┌───────────────────────────────────────┐
      │ EditWatcher                           │
      │   poll focused field for N seconds    │
      │   if edited: store correction pair    │
      │   if single-token diff: auto-learn    │
      │   nightly → LoRA fine-tune cleanup    │
      │   biweekly → LoRA fine-tune ASR       │
      └───────────────────────────────────────┘
```

## Latency budget (target, M-series Max 64 GB)

| Stage                    | Target      |
|--------------------------|-------------|
| VAD endpoint trim        | ≤30 ms      |
| ASR (Parakeet v3)        | 40–80 ms    |
| ASR (Qwen3-ASR)          | 150–300 ms  |
| Cleanup LLM (Qwen3-30B)  | 150–250 ms  |
| Insertion                | ≤10 ms      |
| **End-to-end p50**       | **200–600 ms** |

## Why these models

- **Parakeet TDT 0.6B v3** — fastest high-accuracy ASR on Apple Silicon. 10× Whisper Large v3 speed, lower WER, multilingual (25 langs). Ideal for speed mode.
- **Qwen3-ASR** — audio-language model that accepts a text prompt. This is the only open ASR that enables the Wispr-style context-conditioned recognition: we pass the focused app, window title, surrounding text, and dictionary boost terms.
- **Qwen3-30B-A3B-Instruct-2507 (MoE, 8-bit)** — 30B total, 3B active per token. 30B-class reasoning at 3B-class latency on Apple Silicon. Used for both the cleanup hot path and (reused) Command Mode transformations.

## Personalization loop

1. **Edit watcher** captures edits within N seconds of insertion → stored as `(raw_transcript, inserted_text, final_text, audio)` rows.
2. **Few-shot retriever** embeds raw transcripts with MiniLM and returns top-5 most similar examples at inference time. Zero training required; quality improves with every correction.
3. **Nightly cleanup LoRA** — mlx-lm trains a rank-16 LoRA adapter over all (raw → final) pairs. Adapter is hot-swapped without reloading the base model.
4. **Biweekly ASR LoRA** — rank-8 LoRA over (audio → final_text) pairs. Uses the Qwen3-ASR MLX port's trainer.
5. **DSPy prompt optimization** (optional) evolves the system prompt itself against a held-out validation set.
6. **Dictionary auto-learn** — single-token edits within edit distance ≤2 append to the boost dictionary automatically.

## What goes over the network

Nothing. All inference is local MLX, all storage is local SQLite + local audio files under `~/.local/share/Witzper/`. The Swift helper's sockets are Unix domain sockets mode 0600. No telemetry, no cloud models, no account required.
