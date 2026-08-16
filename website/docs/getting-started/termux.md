---
sidebar_position: 3
title: "Android / Termux"
description: "Run Hermes Agent directly on an Android phone with Termux"
---

# Hermes on Android with Termux

:::warning Tier 2 platform
Termux (Android) is a [Tier 2 platform](./platform-support.md#tier-2). The installer script and documentation here are maintained on a best-effort basis only. Commits to `main` may break these packages at any point in time.
:::

Hermes Agent can run directly on an Android phone through [Termux](https://termux.dev/).

It gives you a working local CLI on the phone, plus the core extras that are currently known to install cleanly on Android.

## What is supported in the tested path?

The tested Termux bundle installs:

- the Hermes CLI
- cron support
- PTY/background terminal support
- Telegram gateway support (manual / best-effort background runs)
- MCP support
- Honcho memory support
- ACP support

Concretely, it maps to:

```bash
python -m pip install -e '.[termux]' -c constraints-termux.txt
```

## What is not part of the tested path yet?

A few features still need desktop/server-style dependencies that are not published for Android, or have not been validated on phones yet:

- `.[all]` is not supported on Android today
- the `voice` extra is blocked by `faster-whisper -> ctranslate2`, and `ctranslate2` does not publish Android wheels
- automatic browser / Playwright bootstrap is skipped in the Termux installer
- Docker-based terminal isolation is not available inside Termux
- Android may still suspend Termux background jobs, so gateway persistence is best-effort rather than a normal managed service

### Termux path protection

When Hermes runs with the local Termux backend, its agent-facing tools apply a
defense-in-depth path policy: `/sdcard` (and Android shared-storage aliases)
cannot be read or searched, and `$PREFIX` cannot be accessed through terminal
commands or modified through file tools. This protects the Termux installation
from accidental agent edits, but it is not an operating-system sandbox: a
deliberately hostile process could still try to hide paths inside shell or
Python code. Use a real isolated backend or an external sandbox when that
boundary is required.

That does not stop Hermes from working well as a phone-native CLI agent — it just means the recommended mobile install is intentionally narrower than the desktop/server install.

---

## Option 1: One-line installer

Hermes now ships a Termux-aware installer path:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

On Termux, the installer automatically:

- uses `pkg` for system packages
- creates the venv with `python -m venv`
- attempts the broad `.[termux-all]` extra first and falls back to the smaller `.[termux]` extra (then a base install) — the curl installer matches this order automatically
- links `hermes` into `$PREFIX/bin` so it stays on your Termux PATH
- skips the untested browser / WhatsApp bootstrap

If you want the explicit commands or need to debug a failed install, use the manual path below.

---

## Option 2: Manual install (fully explicit)

### 1. Update Termux and install system packages

```bash
pkg update
pkg install -y git python clang rust make pkg-config libffi openssl python-cryptography python-pillow nodejs ripgrep ffmpeg
```

Why these packages?

- `python` — runtime + venv support (current Termux releases may ship Python 3.14)
- `git` — clone/update the repo
- `clang`, `rust`, `make`, `pkg-config`, `libffi`, `openssl`, `python-cryptography`, `python-pillow` — needed to build or provide a few Python dependencies on Android
- `nodejs` — optional Node runtime for experiments beyond the tested core path
- `ripgrep` — fast file search
- `ffmpeg` — media / TTS conversions

Para usar el sintetizador nativo de Android, instala también la aplicación
**Termux:API** y su paquete dentro de Termux:

```bash
pkg install -y termux-api
```

Hermes usará `termux-tts-speak` automáticamente en Termux cuando no se
configure un proveedor o se mantenga el valor histórico `edge`. No requiere
una API de voz ni descarga un modelo. Los proveedores cloud explícitos siguen
disponibles como alternativa. Puedes ajustar el motor en
`~/.hermes/config.yaml`:

```yaml
tts:
  provider: termux
  termux:
    language: es
    region: MX
    rate: 1.0
    pitch: 1.0
    stream: MUSIC
```

Para reconocimiento de voz, Hermes usa `termux-speech-to-text` por defecto en
Termux cuando STT está en `local` (el valor histórico) o no se define proveedor:

```yaml
stt:
  provider: local
  termux:
    timeout: 120
    progress: false
```

La aplicación **Termux:API** debe estar instalada además del paquete `termux-api`.
Los proveedores cloud explícitos siguen disponibles como alternativa.

### 2. Clone Hermes

```bash
git clone https://github.com/NousResearch/hermes-agent.git
cd hermes-agent
```

Después del clon, el procedimiento completo se puede ejecutar con el script
idempotente incluido en el repositorio:

```bash
bash scripts/setup_termux.sh
```

Usa `~/.local/bin/tcr -j 3 -n 19` para las operaciones Python que puedan
compilar dependencias, con un máximo de tres trabajos. Para una comprobación
sin instalar paquetes:

```bash
bash scripts/setup_termux.sh --skip-packages --skip-python
```

### 3. Create a virtual environment

```bash
python -m venv --system-site-packages venv
source venv/bin/activate
export ANDROID_API_LEVEL="$(getprop ro.build.version.sdk)"
python -m pip install --upgrade pip setuptools wheel
```

`ANDROID_API_LEVEL` is important for Rust / maturin-based packages such as `jiter`.
The Termux venv exposes Termux-provided native packages such as
`python-cryptography`, avoiding a rebuild from a PyPI Android sdist when no
compatible wheel is published.

### 4. Install the tested Termux bundle

```bash
python -m pip install -e '.[termux]' -c constraints-termux.txt
```

#### Optional: cooler builds on phones

If compilation makes the phone hot, run the dependency build through the
`tcr` wrapper (it uses `taskset`, `nice`, `ionice`, safe CPU groups and up to
three native build jobs):

```bash
export ANDROID_API_LEVEL="$(getprop ro.build.version.sdk)"
~/.local/bin/tcr -j 3 -n 19 -- python -m pip install -e '.[termux]' -c constraints-termux.txt
```

The same wrapper can throttle the complete installer:

```bash
~/.local/bin/tcr -j 3 -n 19 -- bash scripts/install.sh --skip-setup
```

Use `tcr -h` for the available CPU, priority, memory and RAM-guard options.

#### Optional: standalone binary with Nuitka

The setup script can also build an Android/Termux standalone distribution.
This is opt-in because Nuitka compilation is CPU- and storage-intensive:

```bash
bash scripts/setup_termux.sh --standalone
```

The build uses `~/.local/bin/tcr` when available and places the result under
`dist/hermes-termux/hermes-termux.dist/`. It compiles the CLI entry point and
bundles Hermes' dynamically discovered tool packages; the normal venv launcher
remains available as a fallback if a dependency is not compatible with Nuitka.

If you only want the minimal core agent, this also works:

```bash
python -m pip install -e '.' -c constraints-termux.txt
```

### 5. Put `hermes` on your Termux PATH

```bash
ln -sf "$PWD/venv/bin/hermes" "$PREFIX/bin/hermes"
```

`$PREFIX/bin` is already on PATH in Termux, so this makes the `hermes` command persist across new shells without re-activating the venv every time.

### 6. Verify the install

```bash
hermes version
hermes doctor
```

### 7. Start Hermes

```bash
hermes
```

---

## Recommended follow-up setup

### Configure a model

```bash
hermes model
```

Or set keys directly in `~/.hermes/.env`.

### Re-run the full interactive setup wizard later

```bash
hermes setup
```

### Install optional Node dependencies manually

The tested Termux path skips Node/browser bootstrap on purpose. If you want to experiment with browser tooling later, what you need depends on which backend you use:

- **Cloud browser providers** (Browserbase, Browser Use, Firecrawl) host their own Chromium, so Node.js alone is enough — `agent-browser` resolves lazily via `npx agent-browser` on first use:

  ```bash
  pkg install nodejs-lts
  ```

- **Local browser automation** on Termux needs a real `agent-browser` install — the bare npx fallback is deliberately rejected in local mode as too fragile to advertise as ready:

  ```bash
  pkg install nodejs-lts
  npm install -g agent-browser && agent-browser install
  ```

The browser tool automatically includes Termux directories (`/data/data/com.termux/files/usr/bin`) in its PATH search, so `agent-browser` and `npx` are discovered without any extra PATH configuration.

Treat browser / WhatsApp tooling on Android as experimental until documented otherwise.

---

## Troubleshooting

### `No solution found` when installing `.[all]`

Use the tested Termux bundle instead:

```bash
python -m pip install -e '.[termux]' -c constraints-termux.txt
```

The blocker is currently the `voice` extra:

- `voice` pulls `faster-whisper`
- `faster-whisper` depends on `ctranslate2`
- `ctranslate2` does not publish Android wheels

### `uv pip install` fails on Android

Use the Termux path with the stdlib venv + `pip` instead:

```bash
python -m venv venv
source venv/bin/activate
export ANDROID_API_LEVEL="$(getprop ro.build.version.sdk)"
python -m pip install --upgrade pip setuptools wheel
python -m pip install -e '.[termux]' -c constraints-termux.txt
```

### `jiter` / `maturin` complains about `ANDROID_API_LEVEL`

Set the API level explicitly before installing:

```bash
export ANDROID_API_LEVEL="$(getprop ro.build.version.sdk)"
python -m pip install -e '.[termux]' -c constraints-termux.txt
```

### `hermes doctor` says ripgrep or Node is missing

Install them with Termux packages:

```bash
pkg install ripgrep nodejs
```

### Build failures while installing Python packages

Make sure the build toolchain is installed:

```bash
pkg install clang rust make pkg-config libffi openssl
```

Then retry:

```bash
python -m pip install -e '.[termux]' -c constraints-termux.txt
```

---

## Known limitations on phones

- Docker backend is unavailable
- local voice transcription via `faster-whisper` is unavailable in the tested path
- browser automation setup is intentionally skipped by the installer
- some optional extras may work, but only `.[termux]` and `.[termux-all]` are currently documented as the tested Android bundles

If you hit a new Android-specific issue, please open a GitHub issue with:

- your Android version
- `termux-info`
- `python --version`
- `hermes doctor`
- the exact install command and full error output
