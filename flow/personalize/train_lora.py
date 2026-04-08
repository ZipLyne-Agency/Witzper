"""Nightly/biweekly LoRA fine-tuning of cleanup + ASR models.

Uses mlx-lm's LoRA trainer for the cleanup model. ASR LoRA depends on the
Qwen3-ASR MLX port; we write examples to disk in a format its trainer accepts.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
import time
from pathlib import Path

from rich.console import Console

from flow.config import load_config
from flow.personalize.store import CorrectionStore

console = Console()

LORA_ROOT = Path.home() / ".local" / "share" / "Witzper" / "lora"


def train_cleanup() -> None:
    cfg = load_config()
    store = CorrectionStore.open_default()
    pairs = store.pairs_for_cleanup_training()
    if len(pairs) < 20:
        console.print(f"[yellow]only {len(pairs)} correction pairs — need ≥20, skipping[/]")
        return

    out_dir = LORA_ROOT / f"cleanup-{int(time.time())}"
    out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        train_path = Path(td) / "train.jsonl"
        valid_path = Path(td) / "valid.jsonl"
        split = int(len(pairs) * 0.9)
        _write_jsonl(train_path, pairs[:split])
        _write_jsonl(valid_path, pairs[split:] or pairs[-2:])

        cmd = [
            "python",
            "-m",
            "mlx_lm.lora",
            "--model",
            cfg.cleanup.model,
            "--train",
            "--data",
            td,
            "--adapter-path",
            str(out_dir),
            "--lora-rank",
            str(cfg.personalization.cleanup_lora_rank),
            "--iters",
            "600",
            "--batch-size",
            "2",
            "--learning-rate",
            "1e-5",
        ]
        console.print(f"[cyan]$ {' '.join(cmd)}[/]")
        subprocess.run(cmd, check=True)
    console.print(f"[green]adapter saved to {out_dir}[/]")


def train_asr() -> None:
    """Acoustic LoRA — requires the Qwen3-ASR MLX port's trainer."""
    store = CorrectionStore.open_default()
    pairs = store.pairs_for_asr_training()
    if len(pairs) < 50:
        console.print(f"[yellow]only {len(pairs)} audio pairs — need ≥50, skipping[/]")
        return
    console.print(
        "[yellow]ASR LoRA is a stub — integrate with the Qwen3-ASR MLX port's "
        "training script. Pairs are ready:[/]"
    )
    console.print(f"  {len(pairs)} (audio_path, transcript) tuples available")
    # Write manifest for the external trainer to consume
    manifest = LORA_ROOT / "asr_manifest.jsonl"
    manifest.parent.mkdir(parents=True, exist_ok=True)
    with manifest.open("w") as f:
        for audio_path, text in pairs:
            f.write(json.dumps({"audio": audio_path, "text": text}) + "\n")
    console.print(f"[green]manifest written to {manifest}[/]")


def _write_jsonl(path: Path, pairs: list[tuple[str, str]]) -> None:
    with path.open("w") as f:
        for raw, cleaned in pairs:
            obj = {
                "messages": [
                    {"role": "user", "content": raw},
                    {"role": "assistant", "content": cleaned},
                ]
            }
            f.write(json.dumps(obj) + "\n")
