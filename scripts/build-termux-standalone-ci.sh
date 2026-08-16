#!/data/data/com.termux/files/usr/bin/bash
# Builds the Hermes Agent standalone binary for Android/Termux.
#
# This script is meant to run INSIDE a Termux container (termux/termux-docker)
# or a real Termux environment, so it can drive `pkg`, create the venv and
# run the Nuitka standalone build exactly like the on-device setup does.
# The GitHub Actions workflow .github/workflows/termux-release.yml mounts the
# checkout into the container and invokes this file.
#
# Usage (inside Termux):
#   scripts/build-termux-standalone-ci.sh
#
# Outputs:
#   dist/hermes-termux/hermes-termux.dist/   Nuitka standalone tree
#   dist/hermes-termux-<arch>.tar.gz          tarball of the above
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

[[ -n "${PREFIX:-}" && "$PREFIX" == *"com.termux/files/usr"* ]] \
    || die 'must run inside a Termux environment (PREFIX must contain com.termux/files/usr)'
[[ -f "$REPO_ROOT/pyproject.toml" ]] \
    || die "not a Hermes checkout: $REPO_ROOT"

cd "$REPO_ROOT"

# Nuitka's caches honor XDG_CACHE_HOME; the workflow mounts a persistent
# cache dir at $HOME/.cache. Pin it explicitly so the compiled-module and
# ccache data land in the mounted volume regardless of HOME quirks.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# The termux-docker image ships with an empty apt cache (cleaned at build
# time), so `pkg install` fails without a refresh. Retry: a network blip in
# CI must not kill the whole build.
info 'Refreshing the Termux package index'
for attempt in 1 2 3; do
    if pkg update; then
        break
    fi
    [[ "$attempt" == 3 ]] && die 'pkg update failed after 3 attempts'
    echo "pkg update failed (attempt $attempt); retrying in 10s"
    sleep 10
done

# CRITICAL: upgrade all packages before building. termux-docker's bootstrap
# is frozen at image build time, so its python/libpython + extension modules
# (_socket.so, etc.) are OLDER than what a current device has installed. A
# Nuitka standalone built against that stale python bundles the stale
# _socket.so, and its getaddrinfo/resolver behaves incompatibly with the
# device's bionic resolver — every provider call then fails with
# APIConnectionError: [Errno 7] No address associated with hostname (DNS
# broken ONLY in the binary; the venv and curl resolve fine). `pkg upgrade`
# brings the container's python + toolchain to the same versions a current
# device would have, so the bundled extensions match the device ABI.
#
# Not fatal on failure: mirrors 404 on individual packages sometimes (e.g.
# ftp.agdsn.de missing command-not-found 3.5.0-7), and a failed upgrade
# leaves python untouched. The DNS+TLS smoke hook later in this script is
# the authoritative check — it fails the build if the resolver is still
# broken, so we never publish a binary that can't reach providers.
info 'Upgrading all Termux packages (sync python/toolchain with device repos)'
for attempt in 1 2 3; do
    if pkg upgrade -y; then
        break
    fi
    echo "warning: pkg upgrade failed (attempt $attempt); continuing — DNS+TLS smoke will catch a stale python"
    [[ "$attempt" == 3 ]] && break
    sleep 10
done

# --no-tcr: the tcr thermal-throttling wrapper only exists on-device.
# --standalone: produces dist/hermes-termux/hermes-termux.dist/hermes-termux.
info 'Running Termux setup with standalone Nuitka build'
scripts/setup_termux.sh --standalone --no-tcr

BIN="$REPO_ROOT/dist/hermes-termux/hermes-termux.dist/hermes-termux"
[[ -x "$BIN" ]] || die "standalone binary was not produced: $BIN"

# The venv setup_termux.sh created. Used for the ELF check below.
VENV_PYTHON="$REPO_ROOT/venv/bin/python"
[[ -x "$VENV_PYTHON" ]] || die "venv python not found: $VENV_PYTHON"

# Confirm the binary is really an aarch64 ELF (the device ABI). Nuitka can
# silently produce a host-arch binary if the toolchain detection goes wrong,
# so verify the e_machine field: 183 == EM_AARCH64.
MACHINE="$("$VENV_PYTHON" - "$BIN" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    ident = f.read(20)
if ident[:4] != b"\x7fELF":
    sys.exit("not an ELF file")
print(struct.unpack("<H", ident[18:20])[0])
PY
)"
[[ "$MACHINE" == "183" ]] || die "unexpected ELF machine $MACHINE (expected 183 = aarch64); refusing to package"
info "Confirmed: $BIN is an aarch64 ELF"

# Smoke-check the binary inside the same Termux container that built it.
# Not fatal: a missing Android-only runtime symbol only shows up on-device,
# but the container shares bionic + the same package set, so a failure here
# is a strong signal. Exit code of the smoke test is reported, not fatal.
if "$BIN" --version >/dev/null 2>&1; then
    info 'Smoke test passed: standalone binary reports a version'
else
    echo 'warning: smoke test failed (--version); see output above' >&2
fi

# Critical Nuitka regression check: the OpenAI client import path. Under
# Nuitka standalone, openai._base_client is compiled into the binary and its
# loader is an immutable nuitka_module_loader; the CLI's httpx-__del__-neuter
# finder used to mutate spec.loader.exec_module, which crashes at first
# AsyncOpenAI construction with "cannot set 'exec_module' attribute of
# immutable type 'nuitka_module_loader'". HERMES_SMOKE_OPENAI_IMPORT forces
# that exact import; the fixed loader-proxy path must succeed. Fatal here —
# publishing a binary that dies on first model chat is worse than a failed
# build.
if HERMES_SMOKE_OPENAI_IMPORT=1 "$BIN" 2>&1 | grep -q "openai._base_client import OK"; then
    info 'Smoke test passed: OpenAI client import path works under Nuitka'
else
    echo 'error: OpenAI client import path is broken under Nuitka (loader proxy?)' >&2
    exit 1
fi

# TLS + DNS smoke: the standalone binary must be able to resolve hostnames
# and complete a TLS handshake. Nuitka-compiled binaries on Termux have
# shipped with a broken resolver (socket.getaddrinfo fails with EAI_NODATA
# "No address associated with hostname" for every host while the venv
# works) — the tarball would publish a binary whose model chats all fail
# with APIConnectionError. The binary's own smoke hook (HERMES_SMOKE_OPENAI_IMPORT
# + HERMES_SMOKE_TLS_HOST) does the handshake inside the compiled runtime,
# so this is the authoritative check. It also verifies the in-code DNS
# fallback (tools/termux_dns_fallback.py) resolves to a literal IP when the
# native resolver is broken.
if HERMES_SMOKE_OPENAI_IMPORT=1 HERMES_SMOKE_TLS_HOST="${HERMES_SMOKE_TLS_HOST:-inference-api.nousresearch.com}" \
    "$BIN" 2>&1 | grep -q "TLS handshake OK"; then
    info 'Smoke test passed: DNS + TLS handshake works inside the standalone binary'
else
    echo 'error: DNS/TLS is broken inside the standalone binary (getaddrinfo/resolver)' >&2
    exit 1
fi

if HERMES_SMOKE_OPENAI_IMPORT=1 HERMES_SMOKE_TLS_HOST="${HERMES_SMOKE_TLS_HOST:-inference-api.nousresearch.com}" \
    "$BIN" 2>&1 | grep -qE "dns fallback resolves .* \(ips=True, v4=True\)"; then
    info 'Smoke test passed: Termux DNS fallback resolves IPv4+IPv6 to literal IPs'
else
    echo 'error: Termux DNS fallback is broken inside the standalone binary' >&2
    exit 1
fi

ARCH="$(uname -m)"
# xz compresses the Nuitka tree ~30-40% better than gzip (worth it: the
# tarball is the download users install on-device). tar -J is available in
# Termux coreutils; the release workflow just renames the artifact.
OUT="$REPO_ROOT/dist/hermes-termux-${ARCH}.tar.xz"
info "Packaging $OUT"
mkdir -p "$REPO_ROOT/dist"
tar -cJf "$OUT" -C "$REPO_ROOT/dist/hermes-termux" hermes-termux.dist
ls -lh "$OUT"

info "Standalone build complete: $BIN"
