# OpenAutoComplete

System-wide autocomplete for macOS. It shows ghost-text suggestions in any text field, using a local LLM that runs entirely on your machine.

This is an open-source version of apps like [Cotypist](https://cotypist.app). I'm not trying to beat them. The reason it exists is that a tool which reads every keystroke you type should be something you can actually read the source of. There are no network calls at runtime, no telemetry, and no account. The model downloads once, and after that everything runs offline.

> **Status: works, but rough.** Suggestions appear and Tab-to-accept works in most native text fields. The quality of the suggestions is still well behind the commercial apps, and I'm actively tuning the prompts and sampling. It's a working prototype, not a daily driver yet.

## How it works

- **Keystroke capture.** A `CGEventTap` sees keys as you type, system-wide.
- **Context.** The focused field's text is read through the macOS Accessibility API, with a keystroke buffer that stays ahead of AX's lag. For surfaces AX can't read (some browsers, canvas apps), it falls back to screen capture plus Vision OCR.
- **Inference.** A local LLM runs through [MLX](https://github.com/ml-explore/mlx-swift) on Apple Silicon. Reusing the KV cache keeps follow-up suggestions fast.
- **Rendering.** A transparent overlay window draws the ghost text at the caret, matching the host app's font, size, and color, and wrapping at its right margin.
- **Accept.** Tab commits one word at a time (punctuation counts as a word). The key is configurable.

Nothing leaves your machine. The only network access is the one-time model download from Hugging Face.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14+
- Xcode, full install. The Command Line Tools alone aren't enough, because MLX needs Xcode's build system to compile its Metal shaders.
- 1 to 3 GB of disk for the model

## Build and run

```sh
make run
```

The first launch triggers two permission prompts. Grant both in **System Settings → Privacy & Security**, then run `make run` again:

- **Accessibility**, to read the focused text field and position the overlay
- **Input Monitoring**, to see keystrokes for suggestions
- **Screen Recording** (optional), only if you want OCR context for apps AX can't read

The app lives in the menu bar. To watch the logs:

```sh
tail -f ~/Library/Logs/OpenAutoComplete/openautocomplete.log
```

Other targets:

| Command | What it does |
|---|---|
| `make build` | Compile only |
| `make bundle` | Build the `.app` bundle |
| `make run-fg` | Run in the foreground, so you see stderr and crashes |
| `make run-probe` | AX diagnostic tool that dumps what the Accessibility API exposes per app |
| `make clean` | Remove build artifacts |

## Settings

Click the menu-bar icon, then **Settings**:

- **Model.** Pick which local LLM to load (Gemma 4, Llama 3.2, Qwen 2.5). Smaller models are faster, larger ones are more accurate. Changes apply on relaunch.
- **Accept key.** The key that commits the suggestion. Defaults to Tab; you can also use Return, Right Arrow, or F1.

The default model is `mlx-community/gemma-4-e4b-it-4bit` (about 3.2 GB).

## Why

I used a closed-source autocomplete app for a while and liked it, but it reads every keystroke I type, which is about the most sensitive thing on my machine. That's a lot of trust to hand to software you can't see inside. This is the version you can audit.

## License

MIT
