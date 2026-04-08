"""Text insertion via the Swift helper (which holds Accessibility permission).

The helper exposes an RPC at /tmp/flow-context.sock that accepts:
    {"op":"insert","text":"..."}
It uses CGEventPost (not osascript) so it works in any focused app.
"""

from __future__ import annotations

import json
import os
import socket
import time
from pathlib import Path

from flow.config import InsertionCfg

CONTEXT_SOCKET = Path(os.environ.get("FLOW_CONTEXT_SOCKET", "/tmp/flow-context.sock"))


class Inserter:
    def __init__(self, cfg: InsertionCfg):
        self.cfg = cfg

    def insert(self, text: str, app_ctx=None) -> None:
        if not text:
            return
        if not self._insert_via_helper(text):
            print("[flow] WARNING: insert failed — helper unreachable")

    @staticmethod
    def _insert_via_helper(text: str) -> bool:
        if not CONTEXT_SOCKET.exists():
            return False
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(str(CONTEXT_SOCKET))
            payload = json.dumps({"op": "insert", "text": text}) + "\n"
            s.sendall(payload.encode("utf-8"))
            # Wait briefly for ack so the helper finishes paste before we move on
            try:
                _ = s.recv(4096)
            except Exception:
                pass
            s.close()
            time.sleep(0.05)
            return True
        except Exception as e:  # noqa: BLE001
            print(f"[flow] insert RPC failed: {e}")
            return False
