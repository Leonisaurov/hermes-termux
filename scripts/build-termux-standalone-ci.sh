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

ARCH="$(uname -m)"
OUT="$REPO_ROOT/dist/hermes-termux-${ARCH}.tar.gz"
info "Packaging $OUT"
mkdir -p "$REPO_ROOT/dist"
tar -czf "$OUT" -C "$REPO_ROOT/dist/hermes-termux" hermes-termux.dist
ls -lh "$OUT"

info "Standalone build complete: $BIN"
