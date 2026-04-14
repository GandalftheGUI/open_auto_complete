# AX Probe

A diagnostic tool for the Cotypist-style autocomplete project. Polls the macOS Accessibility API every 250 ms and dumps everything we'd need to render ghost text over an arbitrary text field — focused element, frame, value, caret offset, caret bounds rect, and the font / color of the character before the caret.

## Why

We're building an open-source system-wide autocomplete and need to verify that AX gives us the data required to draw ghost text that:
- starts exactly at the caret
- matches the host app's font, size, and color
- wraps at the host's right margin

Before writing the renderer, we need a per-app support matrix: which apps cooperate, which don't, and what fallbacks are needed.

## Run

```sh
make run
```

First launch will trigger an Accessibility-permission prompt. Grant it (System Settings → Privacy & Security → Accessibility), then `make run` again.

Switch to any app, focus a text field, type a few keys. The probe prints a snapshot whenever anything changes.

## What to look for

For each candidate app (TextEdit, Terminal, Notes, Mail, Safari address bar, Safari web inputs, VS Code, Chrome, Slack, etc.):

| Field | Need it |
|---|---|
| `Frame` (origin + size) | ✅ for overlay positioning |
| `Value` (chars) | ✅ for context window |
| `Selected` (caret loc) | ✅ for context + caret position |
| `Caret rect` | ✅ — without this, no overlay |
| `Font` | ✅ — without this, no font matching |
| `Color` | nice-to-have — fall back to gray |

If `Caret rect` is missing → that app can't be supported with this technique.
If `Font` is missing but `Caret rect` works → fallback to a reasonable default font.
