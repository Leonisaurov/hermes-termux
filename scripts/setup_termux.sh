#!/data/data/com.termux/files/usr/bin/bash
# Reproducible, low-heat Termux setup for the current Hermes checkout.
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
TCR="${TCR:-$HOME/.local/bin/tcr}"
BUILD_JOBS=3
USE_TCR=true
SKIP_PACKAGES=false
SKIP_PYTHON=false
BUILD_STANDALONE=false

usage() {
    printf '%s\n' \
        'Usage: scripts/setup_termux.sh [--standalone] [--no-tcr] [--skip-packages] [--skip-python]' \
        '' \
        'Prepares the current Hermes checkout for Termux/Android.' \
        'The Termux:API Android application must be installed separately.'
}

while (($#)); do
    case "$1" in
        --no-tcr) USE_TCR=false; shift ;;
        --skip-packages) SKIP_PACKAGES=true; shift ;;
        --skip-python) SKIP_PYTHON=true; shift ;;
        --standalone|--nuitka) BUILD_STANDALONE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ -n "${PREFIX:-}" && "$PREFIX" == *"com.termux/files/usr"* ]] || die 'this script must run inside Termux'
[[ -f "$REPO_ROOT/pyproject.toml" ]] || die "Hermes checkout not found: $REPO_ROOT"

if [[ "$SKIP_PACKAGES" != true ]]; then
    command -v pkg >/dev/null 2>&1 || die 'Termux pkg command is unavailable'
    info 'Installing Termux runtime and build dependencies'
    pkg install -y python python-cryptography git clang rust make pkg-config libffi openssl ca-certificates curl ripgrep ffmpeg termux-api patchelf binutils ldd
fi

if [[ "$USE_TCR" == true ]]; then
    [[ -x "$TCR" ]] || die "missing $TCR; install tcr or pass --no-tcr"
    RUNNER=("$TCR" -j "$BUILD_JOBS" -n 19 --)
else
    RUNNER=()
    warn 'Python setup is unthrottled; compilation may heat the device.'
fi

PYTHON="$(command -v python || true)"
[[ -n "$PYTHON" ]] || die 'python is not installed'
export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-$(getprop ro.build.version.sdk 2>/dev/null || true)}"
export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-24}"
VENV_PYTHON="$REPO_ROOT/venv/bin/python"

recreate_broken_venv() {
    local backup
    backup="$REPO_ROOT/venv.broken.$(date +%Y%m%d%H%M%S).$$"
    warn "existing venv Python is not executable; preserving it at $backup"
    mv "$REPO_ROOT/venv" "$backup"
    info 'Creating a fresh Termux-compatible virtual environment'
    "${RUNNER[@]}" "$PYTHON" -m venv --system-site-packages "$REPO_ROOT/venv"
}

bootstrap_venv_pip() {
    # The Termux Python package normally supplies the ensurepip wheel. If a
    # device has a damaged Python package, use the system pip as fallback.
    if "${RUNNER[@]}" "$VENV_PYTHON" -m ensurepip --upgrade; then
        return 0
    fi
    warn 'ensurepip is unavailable or missing its bundled wheel; using system pip'
    "${RUNNER[@]}" "$PYTHON" -m pip --python "$VENV_PYTHON" install --upgrade pip \
        || die 'cannot install pip into the Termux venv with system pip'
}

use_termux_native_cryptography() {
    # Termux's python-cryptography is built against Android's Python loader.
    # A PyPI abi3 wheel can install successfully on arm64, but its Rust
    # extension expects CPython symbols to be globally exported and then
    # fails at import time with an unresolved PyLong_Type.  Because this venv
    # uses --system-site-packages, remove only the venv copy and let Python
    # resolve the ABI-matched Termux package instead.
    local site_packages="$REPO_ROOT/venv/lib/python$("$VENV_PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')/site-packages"
    local system_python="$PREFIX/bin/python"
    [[ -x "$system_python" ]] || system_python="$PYTHON"
    "$system_python" -c 'import cryptography' >/dev/null 2>&1 \
        || die 'Termux python-cryptography is unavailable; install it with pkg install python-cryptography and rerun setup'
    if [[ -d "$site_packages/cryptography" ]]; then
        rm -rf "$site_packages/cryptography" "$site_packages"/cryptography-*.dist-info
    fi
    "$VENV_PYTHON" - <<'PY'
import cryptography
from cryptography.hazmat.primitives import hashes

if "/venv/" in cryptography.__file__:
    raise SystemExit(f"Termux cryptography is still shadowed: {cryptography.__file__}")
print(f"Using Termux cryptography {cryptography.__version__}: {cryptography.__file__}")
print(hashes.SHA256)
PY
}

if [[ "$BUILD_STANDALONE" == true && "$SKIP_PYTHON" == true ]]; then
    die '--standalone requires the Hermes venv; remove --skip-python'
fi

if [[ "$SKIP_PYTHON" != true ]]; then
    if [[ ! -x "$VENV_PYTHON" ]]; then
        info 'Creating the Termux-compatible virtual environment'
        "${RUNNER[@]}" "$PYTHON" -m venv --system-site-packages "$REPO_ROOT/venv"
    elif ! "$VENV_PYTHON" -c 'import sys; print(sys.executable)' >/dev/null 2>&1; then
        recreate_broken_venv
    else
        info 'Keeping existing venv'
    fi
    [[ -x "$VENV_PYTHON" ]] || die 'venv Python was not created'
    if ! "$VENV_PYTHON" -c 'import pip' >/dev/null 2>&1; then
        info 'Bootstrapping pip in the existing venv'
        bootstrap_venv_pip
    fi
    # Upgrade pip/setuptools/wheel BEFORE the psutil prebuild below: the
    # Android shim installs with `pip install --no-build-isolation`, which
    # requires setuptools to be importable in the venv. On-device the Termux
    # system site-packages usually provides it, but in a fresh CI container
    # (termux/termux-docker) nothing does — without this reorder the build
    # dies with "BackendUnavailable: Cannot import 'setuptools.build_meta'".
    info 'Upgrading pip, setuptools and wheel'
    "${RUNNER[@]}" "$VENV_PYTHON" -m pip install --upgrade pip setuptools wheel
    if "$VENV_PYTHON" -c 'import sys; raise SystemExit(0 if sys.platform == "android" else 1)' \
        >/dev/null 2>&1 && ! "$VENV_PYTHON" -c 'import psutil' >/dev/null 2>&1; then
        info 'Prebuilding the psutil Android compatibility shim'
        PSUTIL_INSTALLER=("$VENV_PYTHON" "$REPO_ROOT/scripts/install_psutil_android.py")
        if [[ "$USE_TCR" == true ]]; then
            PSUTIL_PIP="$TCR -j $BUILD_JOBS -n 19 -- $VENV_PYTHON -m pip"
        else
            PSUTIL_PIP="$VENV_PYTHON -m pip"
        fi
        "${PSUTIL_INSTALLER[@]}" --pip "$PSUTIL_PIP"
    fi
    info 'Installing Hermes with the curated Termux dependency profile'
    "${RUNNER[@]}" "$VENV_PYTHON" -m pip install -e '.[termux]' -c "$REPO_ROOT/constraints-termux.txt"
    use_termux_native_cryptography
fi

if [[ "$BUILD_STANDALONE" == true ]]; then
    [[ -x "$VENV_PYTHON" ]] || die 'cannot build standalone binary without venv/bin/python'
    info 'Checking Nuitka'
    if ! "$VENV_PYTHON" -c 'import nuitka' >/dev/null 2>&1; then
        info 'Installing Nuitka into the Hermes venv'
        "${RUNNER[@]}" "$VENV_PYTHON" -m pip install Nuitka
    fi
    "$VENV_PYTHON" -m nuitka --version >/dev/null 2>&1 \
        || die 'Nuitka is installed but cannot be executed'

    # Compile the actual Hermes CLI entry point, not the editable console
    # script. Dynamic tool discovery requires the relevant Python packages to
    # be included explicitly in the standalone distribution.
    STANDALONE_PARENT="$REPO_ROOT/dist/hermes-termux"
    STANDALONE_DIR="$STANDALONE_PARENT/hermes-termux.dist"
    mkdir -p "$STANDALONE_PARENT"
    info "Building standalone Hermes with Nuitka (output: $STANDALONE_DIR)"
    "${RUNNER[@]}" "$VENV_PYTHON" -m nuitka \
        --standalone \
        --follow-imports \
        --jobs="$BUILD_JOBS" \
        --low-memory \
        --output-dir="$STANDALONE_PARENT" \
        --output-filename=hermes-termux \
        --include-package=agent \
        --include-package=hermes_cli \
        --include-package=tools \
        --include-package=providers \
        "$REPO_ROOT/hermes_cli/main.py"
    if [[ ! -d "$STANDALONE_DIR" && -d "$STANDALONE_PARENT/main.dist" ]]; then
        mv "$STANDALONE_PARENT/main.dist" "$STANDALONE_DIR"
    fi
    STANDALONE_BIN="$STANDALONE_DIR/hermes-termux"
    [[ -x "$STANDALONE_BIN" ]] || die "Nuitka completed without producing $STANDALONE_BIN"
    info "Standalone binary ready: $STANDALONE_BIN"
fi

if [[ -x "$VENV_PYTHON" ]]; then
    info 'Installing the Hermes launcher'
    mkdir -p "$PREFIX/bin"
    launcher="$PREFIX/bin/hermes"
    target="$REPO_ROOT/venv/bin/hermes"
    if [[ -L "$launcher" && "$(readlink "$launcher")" == "$target" ]]; then
        :
    elif [[ -e "$launcher" || -L "$launcher" ]]; then
        warn "$launcher already exists; leaving it unchanged"
    else
        ln -s "$target" "$launcher"
    fi
fi

# Seed only missing state; explicit credentials and provider choices survive.
mkdir -p "$HERMES_HOME"
if [[ ! -e "$HERMES_HOME/.env" && -f "$REPO_ROOT/.env.example" ]]; then
    cp "$REPO_ROOT/.env.example" "$HERMES_HOME/.env"
    chmod 600 "$HERMES_HOME/.env"
fi
if [[ ! -e "$HERMES_HOME/config.yaml" && -f "$REPO_ROOT/cli-config.yaml.example" ]]; then
    cp "$REPO_ROOT/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
    chmod 600 "$HERMES_HOME/config.yaml"
fi

info 'Checking Termux:API command availability'
for command_name in termux-tts-speak termux-speech-to-text; do
    if command -v "$command_name" >/dev/null 2>&1; then
        printf '  ok: %s\n' "$command_name"
    else
        warn "$command_name unavailable; install the Termux:API package and Android app"
    fi
done

if [[ -x "$VENV_PYTHON" ]]; then
    info 'Checking Hermes Termux path policy'
    "$VENV_PYTHON" - <<'PY'
import os
from tools.termux_path_policy import command_policy_error, path_policy_error
assert command_policy_error("ls /sdcard")
assert command_policy_error("printf x > $PREFIX/bin/blocked")
assert path_policy_error("/sdcard/example", operation="read")
assert path_policy_error(os.path.join(os.environ["PREFIX"], "bin", "blocked"), operation="write")
# Strict Termux home allow-list: anything outside the home is blocked.
assert path_policy_error("/etc/passwd", operation="read")
assert path_policy_error("/storage/emulated/0/foo.txt", operation="read")
assert command_policy_error("cat /etc/passwd")
assert command_policy_error("cat /data/data/com.android.settings/foo")
print("  ok: /sdcard and $PREFIX protections + strict Termux home allow-list")
PY
    info 'Hermes version'
    "$VENV_PYTHON" -m hermes_cli.main version || true
fi

printf '\nTermux setup complete.\nCheckout: %s\nHermes home: %s\nPython: %s\nAndroid API level: %s\n' \
    "$REPO_ROOT" "$HERMES_HOME" "$VENV_PYTHON" "$ANDROID_API_LEVEL"
printf '%s\n' 'Next steps: install Termux:API Android app if needed; run hermes setup; then hermes doctor.'
