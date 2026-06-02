# OpenAutoComplete

System-wide autocomplete for macOS. Ghost-text suggestions in any text field, powered by a local LLM that runs entirely on your machine.

It's an open-source take on apps like [Cotypist](https://cotypist.app). The point isn't to be better than them — it's that a tool which reads every keystroke you type should be something you can actually read the source of. No network calls at runtime, no telemetry, no account. The model downloads once and then everything runs offline.

> **Status: works, but rough.** Suggestions show up and Tab-to-accept works across most native text fields. Suggestion *quality* is still well behind the commercial apps — I'm actively tuning prompts and sampling. Treat this as a working prototype, not a daily driver yet.

## How it works

- **Keystroke capture** — a `CGEventTap` sees keys as you type, system-wide.
- **Context** — the focused field's text is read through the macOS Accessibility API, with a keystroke buffer that stays ahead of AX's lag. For surfaces AX can't read (some browsers, canvas apps), it falls back to screen capture + Vision OCR.
- **Inference** — a local LLM via [MLX](https://github.com/ml-explore/mlx-swift) on Apple Silicon. KV-cache reuse keeps follow-up suggestions fast.
- **Rendering** — a transparent overlay window draws the ghost text at the caret, matching the host app's font, size, and color, and wrapping at its right margin.
- **Accept** — Tab commits one word at a time (punctuation counts as a word). Configurable.

Nothing leaves your machine. The only network access is the one-time model download from Hugging Face.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14+
- Xcode (full install, not just Command Line Tools — MLX needs Xcode's build system to compile its Metal shaders)
- ~1–3 GB of disk for the model

## Build & run

```sh
make run
```

First launch triggers two permission prompts. Grant both in **System Settings → Privacy & Security**, then `make run` again:

- **Accessibility** — to read the focused text field and position the overlay
- **Input Monitoring** — to see keystrokes for suggestions
- (optional) **Screen Recording** — only if you want OCR context for apps AX can't read

The app lives in the menu bar. Logs:

```sh
tail -f ~/Library/Logs/OpenAutoComplete/openautocomplete.log
```

Other targets:

| Command | What it does |
|---|---|
| `make build` | Compile only |
| `make bundle` | Build the `.app` bundle |
| `make run-fg` | Run in the foreground (shows stderr / crashes) |
| `make run-probe` | AX diagnostic tool — dumps what the Accessibility API exposes per app |
| `make clean` | Remove build artifacts |

## Settings

Click the menu-bar icon → **Settings**:

- **Model** — pick which local LLM to load (Gemma 4, Llama 3.2, Qwen 2.5; smaller = faster, larger = better). Changes apply on relaunch.
- **Accept key** — the key that commits the suggestion. Default Tab; also Return, Right Arrow, or F1.

Default model is `mlx-community/gemma-4-e4b-it-4bit` (~3.2 GB).

## Why

I used a closed-source autocomplete app for a while and liked it, but it reads every keystroke I type — about the most sensitive data stream on the machine. That's a lot of trust to hand to software you can't see inside. This is the version you can audit.

## License

MIT
