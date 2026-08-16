"""DNS fallback for Nuitka standalone binaries on Termux/Android.

Root cause this fixes (2026-08-16, hermes-termux): a Nuitka standalone
binary compiled inside a Termux container (termux/termux-docker) does NOT
use Android's netd resolver. bionic's ``getaddrinfo`` normally talks to
``/dev/socket/dnsproxyd`` (seen via strace on the venv interpreter); the
compiled binary instead falls back to a local resolver whose nameserver
list is EMPTY — strace shows ``connect(6, AF_INET, 0.0.0.0:53)`` for every
hostname. Result: every provider/model call fails with

    APIConnectionError: Hermes can't reach the model provider...
    [Errno 7] No address associated with hostname   (EAI_NODATA)

while the venv and curl resolve fine.

This module installs a ``socket.getaddrinfo`` wrapper that catches exactly
that failure class (EAI_NODATA / EAI_NONAME / EAI_AGAIN on a hostname that
has no dots-only-local form) and resolves the name itself against the
nameservers listed in Termux's ``$PREFIX/etc/resolv.conf`` (e.g.
8.8.8.8/8.8.4.4) using a minimal DNS UDP query. Successful fallback
results are cached so the rest of the process (httpx, ssl, aiohttp)
connects by literal IP — no other code needs to change.

Only active on Termux (``PREFIX`` set) and only as a last resort: the
native ``getaddrinfo`` is always tried first, so on a healthy device the
wrapper is a no-op passthrough.
"""

from __future__ import annotations

import os
import socket
import struct
import threading
from typing import Any

_CACHE: dict[str, tuple[int, ...]] = {}
_CACHE_LOCK = threading.Lock()
_ORIG_GETADDRINFO = socket.getaddrinfo

# EAI_* values seen from the broken resolver.
_EAI_NODATA = getattr(socket, "EAI_NODATA", 7)
_EAI_NONAME = getattr(socket, "EAI_NONAME", -2)
_EAI_AGAIN = getattr(socket, "EAI_AGAIN", -3)
_FALLBACK_ERRS = {_EAI_NODATA, _EAI_NONAME, _EAI_AGAIN}

_installed = False


def _nameservers() -> list[str]:
    """Parse nameservers from Termux's resolv.conf (best-effort)."""
    prefix = os.environ.get("PREFIX", "")
    candidates = []
    if prefix:
        candidates.append(os.path.join(prefix, "etc", "resolv.conf"))
    candidates.append("/data/data/com.termux/files/usr/etc/resolv.conf")
    out: list[str] = []
    for path in candidates:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if line.startswith("nameserver"):
                        parts = line.split()
                        if len(parts) >= 2:
                            ns = parts[1]
                            if ns not in out:
                                out.append(ns)
        except OSError:
            continue
        if out:
            break
    return out or ["8.8.8.8", "8.8.4.4"]


def _dns_query(host: str, server: str, timeout: float = 3.0) -> str | None:
    """Minimal A-record DNS query over UDP. Returns an IPv4 string or None.

    Builds a single-question A query with a random ID, sends it to
    *server*:53, and parses the first A answer. No recursion, no TCP
    fallback, no CNAME chasing beyond the answer section — good enough to
    un-break provider endpoints.
    """
    try:
        import random

        qid = random.randint(0, 0xFFFF)
        header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
        qname = b"".join(
            bytes([len(part)]) + part.encode()
            for part in host.split(".")
            if part
        ) + b"\x00"
        question = qname + struct.pack(">HH", 1, 1)  # A, IN
        query = header + question

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.settimeout(timeout)
            sock.sendto(query, (server, 53))
            data, _ = sock.recvfrom(4096)
        finally:
            sock.close()

        if len(data) < 12:
            return None
        (resp_id, flags, qd, an, _, _) = struct.unpack(">HHHHHH", data[:12])
        if resp_id != qid:
            return None
        if flags & 0x8000 == 0 or (flags & 0x000F) != 0:  # no response / rcode != 0
            return None

        # Skip question section (assume exactly qd questions, all A/IN).
        offset = 12
        for _ in range(qd):
            while offset < len(data) and data[offset] != 0:
                offset += data[offset] + 1
            offset += 1 + 4  # null label + QTYPE/QCLASS

        # Walk answer section for the first A record.
        for _ in range(an):
            while offset < len(data) and data[offset] != 0:
                # compressed name pointer
                if data[offset] & 0xC0 == 0xC0:
                    offset += 2
                    break
                offset += data[offset] + 1
            else:
                offset += 1
            if offset + 10 > len(data):
                return None
            _type, _class, _ttl = struct.unpack(">HHI", data[offset : offset + 8])
            rdlen = struct.unpack(">H", data[offset + 8 : offset + 10])[0]
            offset += 10
            if _type == 1 and rdlen == 4 and offset + 4 <= len(data):
                return socket.inet_ntoa(data[offset : offset + 4])
            offset += rdlen
        return None
    except Exception:
        return None


def _fallback_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    """socket.getaddrinfo wrapper: native first, Termux-resolver fallback."""
    try:
        return _ORIG_GETADDRINFO(host, port, family, type, proto, flags)
    except socket.gaierror as exc:
        errno = getattr(exc, "errno", None)
        if errno not in _FALLBACK_ERRS:
            raise
        # Only fall back for real hostnames, not numeric IPs or localhost.
        if not isinstance(host, str) or not host or host in ("localhost", "localhost.localdomain"):
            raise
        if host.replace(".", "").isdigit():  # already an IP literal
            raise
        with _CACHE_LOCK:
            cached = _CACHE.get(host)
        if cached:
            return [
                (socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port))
                for ip in cached
            ]
        for ns in _nameservers():
            ip = _dns_query(host, ns)
            if ip:
                with _CACHE_LOCK:
                    _CACHE[host] = (ip,)
                return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port))]
        raise


def install_dns_fallback() -> bool:
    """Install the getaddrinfo fallback. Idempotent. Returns True if active.

    Only installs on Termux (PREFIX set) — on desktop Linux the native
    resolver is fine and the wrapper would add nothing.
    """
    global _installed
    if _installed:
        return True
    if not os.environ.get("PREFIX"):
        return False
    socket.getaddrinfo = _fallback_getaddrinfo  # type: ignore[assignment]
    _installed = True
    return True
