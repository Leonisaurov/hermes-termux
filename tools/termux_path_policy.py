"""Defense-in-depth path policy for Hermes running directly in Termux.

This is not an OS sandbox: the local terminal still runs as the Termux user.
Use an isolated terminal backend or external sandbox for a hard boundary.
"""

from __future__ import annotations

import os
import re

from hermes_constants import is_termux

SHARED_STORAGE_ROOTS = (
    "/sdcard",
    "/storage/emulated/0",
    "/storage/self/primary",
    "/storage/[^/]+",
    "/android_asset",
)

# Termux's writable home directory.  Every file the agent is allowed to touch
# must resolve *under* this prefix.  This is the canonical Termux home on
# Android: ``$PREFIX`` (/data/data/com.termux/files/usr) and the shared
# storage mounts live *outside* it and are already blocked, but a strict
# allow-list makes the boundary explicit and impossible to bypass via
# redirection or symlink tricks.
TERMUX_HOME_ROOT: str = "/data/data/com.termux/files/home"


def _under(path: str, root: str) -> bool:
    try:
        resolved = os.path.realpath(os.path.expandvars(os.path.expanduser(path)))
        root_resolved = os.path.realpath(root)
        return resolved == root_resolved or resolved.startswith(root_resolved + os.sep)
    except (OSError, ValueError):
        return False


def shared_storage_path(path: str) -> bool:
    if not is_termux():
        return False
    return any(_under(path, root) for root in SHARED_STORAGE_ROOTS)


def prefix_path(path: str) -> bool:
    if not is_termux():
        return False
    prefix = os.environ.get("PREFIX", "")
    return bool(prefix) and _under(path, prefix)


def out_of_home_path(path: str) -> bool:
    """Return True when *path* resolves outside the Termux home directory.

    This is the strict allow-list: the agent may only read/write files that
    live under ``/data/data/com.termux/files/home``.  Everything else —
    ``/system``, ``/data/data/<other-app>``, ``/etc``, ``/proc``, ``/dev``,
    and any other Android or Linux path — is refused by policy.

    A symlink that points outside the home is resolved with ``realpath`` and
    therefore caught: the check operates on the *target*, not the link.
    """
    if not is_termux():
        return False
    return not _under(path, TERMUX_HOME_ROOT)


def path_policy_error(path: str, *, operation: str = "access") -> str | None:
    """Return an error string if *path* is blocked by the Termux path policy.

    Blocks, in order:
      1. Android shared storage (``/sdcard``, ``/storage/emulated/0``, ...).
      2. The Termux installation prefix (``$PREFIX``).
      3. **Any path outside the Termux home** (strict allow-list).

    Returns ``None`` when the path is acceptable.
    """
    if not is_termux():
        return None
    if shared_storage_path(path):
        return (
            f"Termux policy blocked {operation} to Android shared storage. "
            "The agent cannot access /sdcard."
        )
    if prefix_path(path):
        return (
            "Termux policy blocked "
            f"{operation} inside the Termux installation prefix ($PREFIX). "
            "The agent cannot access the Termux installation."
        )
    if out_of_home_path(path):
        return (
            "Termux policy blocked "
            f"{operation} outside the Termux home directory. "
            f"The agent can only access {TERMUX_HOME_ROOT} and its subdirectories."
        )
    return None


# We reject a whole command when it names a protected area. This avoids trying
# to infer write intent in compound shell commands, redirections, or pipelines.
_SHARED_TEXT_RE = re.compile(
    r"(?<![A-Za-z0-9_])(?:/sdcard|/storage/emulated/0|/storage/self/primary|/storage/[^/\s]+|/android_asset)(?:/|\b)",
    re.IGNORECASE,
)
_PREFIX_TEXT_RE = re.compile(
    r"(?<![A-Za-z0-9_])(?:\$\{?PREFIX\}?|/data/data/[^\s'\"`|;&]+/files/usr)(?:/|\b)",
    re.IGNORECASE,
)

# Absolute paths under common system roots that must never be named in a
# shell command from the agent — they are outside the Termux home and the
# agent has no business touching them interactively.
_OUTSIDE_HOME_SYSTEM_RE = re.compile(
    r"(?<![A-Za-z0-9_]) (?:/bin /boot /dev /etc /lib /lib64 /proc /root /run /sbin /srv /sys /system /usr /var"
    r" /data/(?!data/data/com\.termux/files/home) /android /vendor /odm /product /oem\b)",
    re.IGNORECASE | re.VERBOSE,
)


def command_policy_error(command: str) -> str | None:
    """Return an error string if a shell *command* must be blocked under Termux.

    Blocks commands that:
      * reference Android shared storage (``/sdcard``, ``/storage/...``);
      * reference the Termux prefix (``$PREFIX``);
      * reference any system path outside the Termux home (e.g. ``/etc``,
        ``/system``, ``/data/data/<other-app>``).

    The final check uses a regex that looks for absolute paths starting with
    well-known system roots.  ``/data/data/com.termux/files/home`` is the
    *only* ``/data/...`` sub-tree that is ever allowed.
    """
    if not is_termux():
        return None
    if _SHARED_TEXT_RE.search(command or ""):
        return (
            "Termux policy blocked this command because it references Android "
            "shared storage (/sdcard)."
        )
    if _PREFIX_TEXT_RE.search(command or ""):
        return (
            "Termux policy blocked this command because it references $PREFIX. "
            "The agent must not access or modify the Termux installation."
        )

    # Strict: any absolute path that is NOT under the Termux home is blocked.
    # Tokenise the command into shell tokens so a path argument embedded in a
    # redirection or pipeline is still caught.
    for token in re.split(r"\s+", command or ""):
        token = token.strip()
        if not token or not token.startswith("/"):
            continue
        # Strip a trailing punctuation that is shell syntax, not part of path.
        path_token = token.rstrip(";:|&<>{}()\"'\\")
        if not path_token or not path_token.startswith("/"):
            continue
        err = path_policy_error(path_token, operation="access")
        if err:
            return (
                "Termux policy blocked this command because it references a "
                f"path outside the Termux home directory ({path_token}). "
                f"The agent can only access {TERMUX_HOME_ROOT}."
            )
    return None
