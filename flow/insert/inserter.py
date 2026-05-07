"""Text insertion via the Swift helper (which holds Accessibility permission).

The helper exposes an RPC at /tmp/flow-context.sock that accepts:
    {"op":"insert","text":"...","strategy":"paste"|"type"}
It uses CGEventPost (not osascript) so it works in any focused app.
"""

from __future__ import annotations

import json
import os
import socket
import time
from pathlib import Path
from typing import Literal

from flow.config import InsertionCfg

CONTEXT_SOCKET = Path(os.environ.get("FLOW_CONTEXT_SOCKET", "/tmp/flow-context.sock"))
InsertionStrategy = Literal["paste", "type"]


class Inserter:
    def __init__(self, cfg: InsertionCfg):
        self.cfg = cfg

    def insert(self, text: str, app_ctx=None) -> None:
        if not text:
            return
        strategy = self._strategy_for(app_ctx)
        if not self._insert_via_helper(text, strategy, self.cfg.restore_clipboard_after_ms):
            print("[flow] WARNING: insert failed — helper unreachable")

    def _strategy_for(self, app_ctx=None) -> InsertionStrategy:
        rule_strategy = getattr(getattr(app_ctx, "rule", None), "insertion", None)
        if rule_strategy in ("paste", "type"):
            return rule_strategy
        return self.cfg.default_strategy

    @staticmethod
    def _insert_via_helper(
        text: str,
        strategy: InsertionStrategy,
        restore_clipboard_after_ms: int,
    ) -> bool:
        if not CONTEXT_SOCKET.exists():
            return False
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(str(CONTEXT_SOCKET))
            payload = json.dumps({
                "op": "insert",
                "text": text,
                "strategy": strategy,
                "restore_clipboard_after_ms": restore_clipboard_after_ms,
            }) + "\n"
            s.sendall(payload.encode("utf-8"))
            # Wait briefly for ack so the helper finishes paste before we move on
            data = b""
            try:
                data = s.recv(4096)
            except Exception:
                pass
            s.close()
            if data:
                try:
                    obj = json.loads(data.decode("utf-8"))
                    if obj.get("ok") is False:
                        error = obj.get("error", "helper rejected insert")
                        print(f"[flow] insert rejected by helper: {error}")
                        return False
                except Exception:
                    pass
            time.sleep(0.05)
            return True
        except Exception as e:  # noqa: BLE001
            print(f"[flow] insert RPC failed: {e}")
            return False
