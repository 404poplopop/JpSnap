# JpSnap

Press **Ctrl+Alt+J**, drag over Japanese text anywhere on screen, and a small overlay breaks it down for learning:

- every word with its kana reading, pitch accent line (top = high, bottom = low), part-of-speech colored underline and romaji
- hover a word (or a punctuation mark) for its meaning, role in the sentence, how the form is built and why, and its pitch type
- click a word to hear it, ▶ / Space to hear the sentence with phrase-by-phrase karaoke, *Slow* for slower speech
- right-click a word or press ★ to save it to `Documents\JpSnap\deck.tsv` (Anki import); every snip goes to `history.jsonl`
- drag to move, Esc / ✕ to close

Translation runs through the Codex CLI (`codex exec`, model `gpt-6-luna`, JSON output schema) on your Codex subscription,
or per run on your own OpenAI API key. Pitch accent comes from the Kanjium dictionary (GPT estimate as fallback, drawn faint).
The voice is edge-tts `ja-JP-NanamiNeural` with word timings.

## Layout

| Path | Runs on | What |
|---|---|---|
| `jpsnap_core.py` | server and PC | `translate` (codex + pitch enrichment), `tts` (edge-tts + word marks), `selftest` |
| `schema.json`, `prompt.txt`, `accents.txt` | server and PC | codex output schema, prompt, pitch dictionary |
| `server/jp-translate` | server | ssh forced command; dispatches to `jpsnap_core.py` |
| `pc/jpsnap.ps1` | PC | snip (native `ms-screenclip:`), WPF overlay, karaoke, deck |
| `pc/hotkey.ps1` | PC | resident Ctrl+Alt+J listener (Startup folder) |
| `pc/install.ps1` | PC | Start Menu entry, Startup listener, venv with edge-tts, selftest |
| `pc/ui_test.ps1`, `pc/run_ui_test.ps1` | PC | session-1 UI test (UI Automation Invoke only, no mouse/keyboard input) |

## Setup

**Server** (Linux, Codex CLI logged in):
```bash
python3 -m venv ~/.local/share/jpsnap-venv && ~/.local/share/jpsnap-venv/bin/pip install edge-tts==7.3.1
git clone <this repo> ~/.local/share/jpsnap
ln -s ~/.local/share/jpsnap/server/jp-translate ~/.local/bin/jp-translate
# dedicated key for the PC, locked to the translator:
echo "command=\"$HOME/.local/bin/jp-translate\",restrict $(cat jpsnap_key.pub)" >> ~/.ssh/authorized_keys
```

**PC** (Windows 11, Python 3.11 via `py`): copy `pc/*` to `%LOCALAPPDATA%\JpSnap`, the core files
(`jpsnap_core.py schema.json prompt.txt accents.txt`) to `%LOCALAPPDATA%\JpSnap\core`, the private key to
`jpsnap_key` and the server host key to `known_hosts` as `jpsnap-server ssh-ed25519 AAAA...`, then run
`powershell -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\JpSnap\install.ps1`.

## Settings

⚙ opens `%LOCALAPPDATA%\JpSnap\config.json` (created on first run; applies to the next snip):

```json
{ "run_on": "server", "server": "user@your-server", "openai_api_key": "" }
```

- `server`: `user@host` of the machine with `server/jp-translate` (first run opens the settings until it is set).
- `run_on`: `server` = translate and speak on the server over ssh; `pc` = everything on the PC
  (needs `openai_api_key` or a one-time `codex login`; the Codex desktop app login is not usable by its CLI).
- `openai_api_key` (optional, `sk-...`): passed to codex as `CODEX_API_KEY` for that run only, never stored on the server.
  On the PC it sits in plain text in `config.json`.

## Checks

```bash
~/.local/share/jpsnap-venv/bin/python -I jpsnap_core.py selftest          # pitch logic
powershell -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\JpSnap\run_ui_test.ps1 -Mode server   # on the PC
```

The UI test feeds a rendered sentence through the real snip path and checks translation, words, karaoke, save, close
and temp-file cleanup. Hover tooltips and right-click are checked by hand.

## Security

- Screenshots are untrusted input (text on screen can be a prompt injection). codex runs with every tool disabled
  (`NO_TOOLS` in `jpsnap_core.py`: no shell, code mode, web, browser, apps, plugins, MCP or user config), so the model
  can only answer; it cannot read files or reach the network. Check: ask it to run a command, it fails closed.
- Model output is shown as plain text (never parsed as XAML) and HTML-escaped before it goes into `deck.tsv`.
- The PC's ssh key is locked to `jp-translate` with `command=...,restrict` (no shell, no forwarding); the ssh
  command only picks `translate` or `tts`. The API key is checked against `sk-[A-Za-z0-9_-]+`, sent on stdin and
  given to codex in its environment for that run only.

Third-party data and services: see `THIRD_PARTY.md`.
