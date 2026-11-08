# JpSnap

I realized that I couldn't learn through immersion without being able to quickly translate the interface or the caption, so I quickly made this project.

Press **Ctrl+Alt+J**, drag over Japanese text anywhere on screen, and a small overlay breaks it down for learning:

- every word with its kana reading, pitch accent line (top = high, bottom = low), part-of-speech colored underline and romaji
- hover a word (or a punctuation mark) for its meaning, role in the sentence, how the form is built and why (including sound changes such as 8杯 = はっぱい), and its pitch type;
  hold **Alt** for the whole word (8 + 杯), **Shift** for its part of the sentence, each with how its pieces stack together; click plays what is selected
- ⚡ **fast mode** (default on): a quick translation with readings in about 10 s, the full explanations replace it when they arrive (about 25 s)
- click a word to hear it, ▶ / Space to hear the sentence with phrase-by-phrase karaoke, **1× / 0.7×** for slower speech
- right-click a word or press ★ to save it to `Documents\JpSnap\deck.tsv` (Anki import); every snip goes to `history.jsonl`
- ⚙ settings: server (ssh or HTTPS) or this PC, server address, optional API key, fast mode, model, Codex fast tier, voice (Nanami / Keita), speech speed
- drag to move, Esc / ✕ to close

## Quick start (Windows 10/11)

1. **Code → Download ZIP** on GitHub and extract it (or `git clone`).
2. Double-click **`setup.bat`**. It installs JpSnap for your Windows user (no admin) and asks whether to start it with
   Windows. Run it again any time to update; your settings are kept.
3. Press **Ctrl+Alt+J** and drag over Japanese text.

Needs Python 3.11–3.14 (`winget install Python.Python.3.12`) and the Codex app or CLI signed in (`codex login`), or an
OpenAI API key in ⚙ settings. "Start with Windows" can also be switched in ⚙ settings.
Windows may warn about a file from the internet when you start `setup.bat`; choose *Run* (or unblock the zip first).

Translation runs through the Codex CLI (`codex exec`, model `gpt-6-luna`, JSON output schema) on your Codex subscription,
or per run on your own OpenAI API key. Pitch accent comes from the Kanjium dictionary (GPT estimate as fallback, drawn faint).
The voice is edge-tts (`ja-JP-NanamiNeural` or `ja-JP-KeitaNeural`) with word timings.

## Layout

| Path | Runs on | What |
|---|---|---|
| `jpsnap_core.py` | server and PC | `translate` (codex + pitch enrichment), `tts` (edge-tts + word marks), `selftest` |
| `schema.json`, `prompt.txt`, `prompt_fast.txt`, `accents.txt` | server and PC | output schema (the fast one is cut from it), prompts, pitch dictionary |
| `server/jp-translate` | server | ssh forced command; dispatches to `jpsnap_core.py` |
| `server/jp-https`, `server/jpsnap-https.service` | server | HTTPS front for networks that block ssh (same bodies over POST), its systemd unit template |
| `pc/jpsnap.ps1` | PC | entry: snip (native `ms-screenclip:`), overlay, lookup flow, events |
| `pc/lib/config.ps1` | PC | `config.json`, input checks, DPAPI-encrypted API key |
| `pc/lib/backend.ps1` | PC | runs the core over ssh, HTTPS or locally, background jobs |
| `pc/lib/render.ps1` | PC | word blocks, pitch lines, tooltips, Alt/Shift hover, "now" strip |
| `pc/lib/speech.ps1` | PC | voice cache, prefetch, karaoke |
| `pc/lib/deck.ps1`, `pc/lib/settings.ps1` | PC | history and Anki deck; settings window |
| `pc/ui/overlay.xaml`, `pc/ui/settings.xaml` | PC | the two windows |
| `pc/hotkey.ps1` | PC | resident Ctrl+Alt+J listener (Startup folder) |
| `setup.bat`, `pc/install.ps1` | PC | install / update: app files, venv with edge-tts, selftest, Start Menu entry, start with Windows |
| `pc/ui_test.ps1`, `pc/run_ui_test.ps1` | PC | session-1 UI test (UI Automation only, no mouse/keyboard input) |
| `pc/hover_test.ps1` | PC | hover levels and moving between words, on the real functions, no window or input |
| `pc/config_test.ps1` | PC | config defaults, plain-text key migration, server and key checks |

## Setup

**Server** (Linux, Codex CLI logged in):
```bash
python3 -m venv ~/.local/share/jpsnap-venv && ~/.local/share/jpsnap-venv/bin/pip install edge-tts==7.3.1
git clone <this repo> ~/.local/share/jpsnap
ln -s ~/.local/share/jpsnap/server/jp-translate ~/.local/bin/jp-translate
# dedicated key for the PC, locked to the translator:
echo "command=\"$HOME/.local/bin/jp-translate\",restrict $(cat jpsnap_key.pub)" >> ~/.ssh/authorized_keys
```

**PC**: run `setup.bat` (above). For server mode put the private key in `%LOCALAPPDATA%\JpSnap\jpsnap_key` and the
server host key in `known_hosts` as `jpsnap-server ssh-ed25519 AAAA...`, then choose *Server* in ⚙ settings.
`setup.bat -AutoStart Yes|No|Keep` answers the start-with-Windows question without asking.

**HTTPS (when ssh is blocked, e.g. on a corp VPN)**: `server/jp-https` listens on 127.0.0.1:8893 and runs the same
core; your TLS reverse proxy (nginx, Caddy, Cloudflare in front, ...) forwards `/jpsnap/` to it, for example nginx:
```nginx
location ^~ /jpsnap/ { client_max_body_size 30m; proxy_pass http://127.0.0.1:8893/; proxy_read_timeout 180s; }
```
```bash
umask 077; mkdir -p ~/.config/jpsnap; python3 -c 'import secrets;print(secrets.token_urlsafe(32))' > ~/.config/jpsnap/https_token
sed "s|__USER__|$USER|g; s|__HOME__|$HOME|g; s|__NODE_BIN__|$(dirname "$(command -v node)")|g" server/jpsnap-https.service |
  sudo tee /etc/systemd/system/jpsnap-https.service >/dev/null && sudo systemctl enable --now jpsnap-https
```
Run it as the user whose Codex login and token file it should use.
On the PC choose *Server (HTTPS)* in ⚙ settings, address `https://<site>/jpsnap`, and paste the token (stored
DPAPI-encrypted). Errors from the core come back as HTTP 422 (Cloudflare and some proxies replace 502 bodies).

## Settings

⚙ opens the settings window; it writes `%LOCALAPPDATA%\JpSnap\config.json`:

```json
{ "run_on": "server", "server": "user@your-server", "fast": true, "voice": "nanami", "speed": "normal", "openai_api_key_dpapi": "" }
```

- `run_on`: `server` = translate and speak on the server over ssh; `https` = the same over HTTPS; `pc` = everything on the PC
  (needs an API key or a one-time `codex login`; the Codex desktop app login is not usable by its CLI).
- `server`: `user@host` of the machine with `server/jp-translate`.
- `model`: the Codex model (`gpt-6-luna` default; the list is fixed in `MODELS`, the core refuses others).
- `fast_tier`: Codex's priority service tier (`service_tier="priority"`): about 1.5× faster, uses more of your plan.
- `https_url`, `https_token_dpapi`: `run_on: https` posts to `<https_url>/translate` and `/tts` with
  `Authorization: Bearer <token>`; uses the Windows proxy settings. A plain `https_token` is encrypted on first start.
- `fast`: quick and full lookup start together (two requests per snip); the quick result is drawn first.
- API key (optional, `sk-...`): stored DPAPI-encrypted for your Windows account (`openai_api_key_dpapi`); a plain
  `openai_api_key` from older versions is encrypted and removed on first start. Each run passes it to codex as
  `CODEX_API_KEY`; it is never stored on the server.

## Checks

```bash
~/.local/share/jpsnap-venv/bin/python -I jpsnap_core.py selftest          # pitch logic, request parsing
~/.local/share/jpsnap-venv/bin/python -I server/jp-https selftest      # HTTPS front: token, routes, size limit
# on the PC:
powershell -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\JpSnap\run_ui_test.ps1 -Mode server        # fast mode
powershell -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\JpSnap\run_ui_test.ps1 -Mode https         # over HTTPS
powershell -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\JpSnap\run_ui_test.ps1 -Mode server -Full  # fast mode off
powershell -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\JpSnap\hover_test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\JpSnap\config_test.ps1
```

The UI test feeds a rendered sentence through the real snip path and checks translation, details, words, voice prefetch,
karaoke, save, settings (bad server refused, saved values, encrypted key), close and temp-file cleanup. It runs the app
with its own config copy and data folder (`JPSNAP_CONFIG`, `JPSNAP_DATA`) and only drives and closes the JpSnap
process it started, so your settings, deck and history are not touched. `JPSNAP_DEBUG=<file>` traces lookups and
playback. Real hovering and right-click are checked by hand.

## Security

- Screenshots are untrusted input (text on screen can be a prompt injection). codex runs with every tool disabled
  (`NO_TOOLS` in `jpsnap_core.py`: no shell, code mode, web, browser, apps, plugins, MCP or user config), so the model
  can only answer; it cannot read files or reach the network. Check: ask it to run a command, it fails closed.
- Model output is shown as plain text (never parsed as XAML) and HTML-escaped before it goes into `deck.tsv`.
- The PC's ssh key is locked to `jp-translate` with `command=...,restrict` (no shell, no forwarding); the ssh
  command only picks `translate` or `tts`. Everything on stdin is checked in `jpsnap_core.py`
  (`parse_translate_request`, `parse_tts_request`): JSON header, key format `sk-[A-Za-z0-9_-]`, PNG signature,
  voice and rate from fixed lists.
- `setup.bat` installs the voice runtime from `pc/requirements.txt`: exact versions with SHA-256 hashes, wheels only
  (`--require-hashes --only-binary=:all:`), so a changed or newly published package is refused and no build scripts run.
- HTTPS front: every request needs the 256-bit bearer token (constant-time compare) before the body is read; bodies
  over 30 MB are refused, at most 6 core runs at once (then 503), 170 s per run; it listens on 127.0.0.1 only.
  A corp proxy that inspects TLS can read the requests (screenshots, token, API key): use your own API key there with care.
- The server setting must be `user@host` (no spaces or leading `-`) and ssh gets `--` before it, so it cannot become
  an ssh option. The API key is encrypted with DPAPI and only decrypted for the request that needs it.

## History

- 2026-11-08: first version (snip, word breakdown with pitch accent, hover explanations, karaoke voice, Anki deck);
  audit: codex runs without tools, no addresses or names in the repo, deck HTML-escaped.
- 2026-11-08: Alt / Shift hover for whole words and sentence parts, contextual readings (8杯 = はっぱい), word voice prefetch.
- 2026-11-08 (was PR #2, Copilot-reviewed): fast mode, settings window, split into `pc/lib` + `pc/ui`, DPAPI API key,
  hover popup instead of WPF tooltips. Review fixes: loading bar after a failed full lookup, config merge across
  windows, no cards from quick results, karaoke redraw after a re-render, keyboard keys and screen-reader names.
  The repo was recreated afterwards to drop old commits; the PR page went with it.

- 2026-11-08: HTTPS transport (`run_on: https`) for networks that block ssh; model choice and the Codex fast tier
  in settings.

## License

Code: MIT (`LICENSE`). `accents.txt` keeps its own license, CC BY-SA 4.0 (Kanjium); third-party data and
services: see `THIRD_PARTY.md`.
