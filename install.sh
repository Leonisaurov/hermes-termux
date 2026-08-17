#!/bin/sh
# ============================================================================
# Hermes Agent — standalone installer for Termux (aarch64)
# ============================================================================
# Downloads the prebuilt Nuitka standalone binary from GitHub Releases and
# installs it under $HOME/.hermes/hermes-termux, then links a `hermes`
# command into $PREFIX/bin. This single script is repo-independent: it only
# talks to GitHub to fetch a release asset — no checkout, no source, no
# build toolchain.
#
# The binary is compiled for Android/Termux (bionic libc, arm64-v8a), so it
# runs ONLY inside Termux on an aarch64 device.
#
# Usage:
#   curl -fsSL https://github.com/Leonisaurov/hermes-termux/raw/main/install.sh | sh
#
# Pin a release / override paths:
#   curl -fsSL <same url> | sh -s -- --tag v0.1.6
#   curl -fsSL <same url> | sh -s -- --install-dir "$PREFIX/lib/hermes" --skip-deps
#
# Re-running installs/updates to the latest release (idempotent).
# ============================================================================

set -eu

# --- configuration ---------------------------------------------------------
# Override REPO via env (e.g. a fork) or edit the default below.
REPO="${HERMES_REPO:-Leonisaurov/hermes-termux}"
ASSET="hermes-termux-aarch64.tar.xz"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
INSTALL_DIR="${HERMES_TERMUX_INSTALL_DIR:-$HERMES_HOME/hermes-termux}"

TAG=""
SKIP_DEPS=false
NO_VERIFY=false

# Runtime packages the standalone binary shells out to (not build deps; the
# binary bundles its own Python + native extensions).
RUNTIME_DEPS="ca-certificates curl ripgrep ffmpeg termux-api"

# --- helpers ---------------------------------------------------------------
if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_NC=''
fi

info() { printf '%s==> %s%s\n' "$C_CYAN" "$*" "$C_NC"; }
ok()   { printf '%s[ok] %s%s\n' "$C_GREEN" "$*" "$C_NC"; }
warn() { printf '%s[!] %s%s\n' "$C_YELLOW" "$*" "$C_NC"; }
die()  { printf '%s[error] %s%s\n' "$C_RED" "$*" "$C_NC" >&2; exit 1; }

usage() {
    cat <<EOF
Hermes Agent — standalone installer for Termux (aarch64)

Usage:
  curl -fsSL https://github.com/$REPO/raw/main/install.sh | sh [-- OPTIONS]

Options:
  --tag TAG        Install a specific release (default: latest stable)
  --install-dir D  Extract the standalone tree into D
                   (default: \$HOME/.hermes/hermes-termux)
  --skip-deps      Do not install runtime packages via pkg
  --no-verify      Skip the post-install 'hermes --version' check
  -h, --help       Show this help

Environment:
  HERMES_REPO               GitHub repo to fetch releases from
                            (default: $REPO)
  HERMES_TERMUX_INSTALL_DIR Overrides --install-dir
  HERMES_HOME               Data dir (default: ~/.hermes)
EOF
}

# --- argument parsing ------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --tag|-t)
            TAG="${2:-}"
            [ -n "$TAG" ] || die "--tag needs a value"
            shift 2
            ;;
        --install-dir)
            INSTALL_DIR="${2:-}"
            [ -n "$INSTALL_DIR" ] || die "--install-dir needs a value"
            shift 2
            ;;
        --skip-deps)
            SKIP_DEPS=true
            shift
            ;;
        --no-verify)
            NO_VERIFY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            warn "ignoring unknown option: $1"
            shift
            ;;
    esac
done

# --- environment checks ----------------------------------------------------
command -v uname >/dev/null 2>&1 || die "uname not found; is this a real shell?"

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64|armv8*) ;;
    *) die "this installer is for aarch64 (arm64-v8a) only; detected '$ARCH'" ;;
esac

is_termux=false
[ -n "${TERMUX_VERSION:-}" ] && is_termux=true
case "$PREFIX" in
    *com.termux/files/usr*) is_termux=true ;;
esac
if [ "$is_termux" = false ]; then
    die "this installer targets Termux on Android (bionic + aarch64); aborting"
fi

command -v pkg >/dev/null 2>&1 || die "Termux 'pkg' command not found"

# Ensure curl is present before trying to download.
if ! command -v curl >/dev/null 2>&1; then
    info "installing curl + ca-certificates (needed to download)"
    pkg install -y curl ca-certificates >/dev/null 2>&1 \
        || die "could not install curl; run: pkg install curl ca-certificates"
fi

# Runtime dependencies (non-fatal: the binary still works without some of them).
if [ "$SKIP_DEPS" = false ]; then
    info "installing runtime packages ($RUNTIME_DEPS)"
    if pkg install -y $RUNTIME_DEPS >/dev/null 2>&1; then
        ok "runtime packages present"
    else
        warn "some runtime packages failed to install (continuing — re-run without --skip-deps later)"
    fi
fi

# --- download --------------------------------------------------------------
if [ -n "$TAG" ]; then
    URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
else
    URL="https://github.com/$REPO/releases/latest/download/$ASSET"
fi

if command -v mktemp >/dev/null 2>&1; then
    TMP_DIR="$(mktemp -d)"
else
    TMP_DIR="$HERMES_HOME/.hermes-termux-install-$$"
fi
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

info "downloading $URL"
curl -fL --retry 3 --retry-delay 2 -o "$TMP_DIR/$ASSET" "$URL" \
    || die "download failed: $URL (release not found? check the tag/name)"

# Basic sanity: a real standalone tarball is tens of MB, never tiny.
SIZE=0
if command -v wc >/dev/null 2>&1; then
    SIZE="$(wc -c < "$TMP_DIR/$ASSET" 2>/dev/null || echo 0)"
fi
if [ "${SIZE:-0}" -lt 1000000 ]; then
    die "downloaded file is suspiciously small (${SIZE} bytes); aborting"
fi

# Verify it is a valid xz tarball before touching the install dir.
info "verifying archive"
tar -tJf "$TMP_DIR/$ASSET" >/dev/null 2>&1 \
    || die "downloaded file is not a valid xz tarball; aborting"

# --- extract & stage -------------------------------------------------------
STAGE="$TMP_DIR/stage"
mkdir -p "$STAGE"
info "extracting to staging area"
tar -xJf "$TMP_DIR/$ASSET" -C "$STAGE" || die "extraction failed"

BIN="$STAGE/hermes-termux.dist/hermes-termux"
[ -x "$BIN" ] || die "standalone binary not found in archive (expected hermes-termux.dist/hermes-termux)"

if [ "$NO_VERIFY" = false ]; then
    info "verifying the downloaded binary reports a version"
    "$BIN" --version >/dev/null 2>&1 \
        || die "downloaded binary failed '--version'; re-run with --no-verify to force"
    ok "binary is executable and reports a version"
fi

# --- install (atomic-ish swap) ---------------------------------------------
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR.old"
    mv "$INSTALL_DIR" "$INSTALL_DIR.old"
fi
mkdir -p "$INSTALL_DIR"
mv "$STAGE/hermes-termux.dist" "$INSTALL_DIR/hermes-termux.dist"
rm -rf "$INSTALL_DIR.old"

# Record what we installed, for diagnostics / future update checks.
printf '%s\n' "${TAG:-latest}" > "$INSTALL_DIR/.version"

# --- launcher --------------------------------------------------------------
mkdir -p "$PREFIX/bin"
LAUNCHER="$PREFIX/bin/hermes"
TARGET="$INSTALL_DIR/hermes-termux.dist/hermes-termux"
ln -sf "$TARGET" "$LAUNCHER"
ok "linked $LAUNCHER -> $TARGET"

if [ "$NO_VERIFY" = false ]; then
    if command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1; then
        ok "'hermes --version' works from PATH"
    else
        warn "'hermes' not on PATH in this shell yet — open a new shell or run: $LAUNCHER"
    fi
fi

# --- done ------------------------------------------------------------------
echo ""
printf '%sHermes Agent installed.%s\n' "$C_BOLD" "$C_NC"
echo "  binary   : $TARGET"
echo "  launcher : $LAUNCHER  (on PATH)"
echo "  version  : ${TAG:-latest} release"
echo ""
echo "  Run:    hermes"
echo "  Update: re-run this installer (curl ... | sh)"
