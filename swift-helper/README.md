# flow-helper (Swift)

macOS menu-bar helper providing:
- Global hotkey via `CGEventTap` → `/tmp/flow-local.sock`
- Focused-element AX snapshot server → `/tmp/flow-context.sock`

## Build

```bash
cd swift-helper
swift build -c release
```

The binary lives at `.build/release/flow-helper`.

## Run

```bash
./.build/release/flow-helper
```

You'll be prompted to grant **Accessibility** and **Input Monitoring** permission in System Settings → Privacy & Security. Relaunch after granting.

## Notes

- The default hotkey is **Right-Option** for broad compatibility. To use Fn, integrate with the IOHID framework — see the TODO.
- Sockets are created with mode 0600 so only your user can read them.
