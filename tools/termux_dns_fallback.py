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

Both A (IPv4) and AAAA (IPv6) records are queried, and the result is
family-filtered to match what the caller asked for (``family`` argument),
so httpx/anyio's connection loops find a usable address.

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

_CACHE: dict[str, tuple[str, ...]] = {}
_CACHE_LOCK = threading.Lock()
# Serializes actual DNS queries: when 20 doctor/provider threads hit the
# broken resolver at once, every thread would fire its own UDP query and
# responses get lost/dropped under the burst (strace showed sendto without
# recvfrom under load). One query at a time, cached, so the first thread
# resolves and the rest hit the cache.
_RESOLVE_LOCK = threading.Lock()
_ORIG_GETADDRINFO = socket.getaddrinfo

# EAI_* values seen from the broken resolver (Android/bionic: positive).
_EAI_NODATA = getattr(socket, "EAI_NODATA", 7)
_EAI_NONAME = getattr(socket, "EAI_NONAME", 8)
_EAI_AGAIN = getattr(socket, "EAI_AGAIN", 2)
_FALLBACK_ERRS = {_EAI_NODATA, _EAI_NONAME, _EAI_AGAIN}

_installed = False

# QTYPE constants
_QTYPE_A = 1
_QTYPE_AAAA = 28


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


def _dns_query(host: str, server: str, qtype: int, timeout: float = 3.0) -> str | None:
    """Minimal DNS query (A or AAAA) over UDP. Returns one address string.

    Builds a single-question query with a random ID, sends it to
    *server*:53, and parses the first matching answer. No recursion, no TCP
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
        question = qname + struct.pack(">HH", qtype, 1)  # A/AAAA, IN
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

        # Skip question section (assume exactly qd questions).
        offset = 12
        for _ in range(qd):
            while offset < len(data) and data[offset] != 0:
                offset += data[offset] + 1
            offset += 1 + 4  # null label + QTYPE/QCLASS

        # Walk answer section for the first address record of the right type.
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
            if _type == qtype:
                if qtype == _QTYPE_A and rdlen == 4 and offset + 4 <= len(data):
                    return socket.inet_ntoa(data[offset : offset + 4])
                if qtype == _QTYPE_AAAA and rdlen == 16 and offset + 16 <= len(data):
                    return socket.inet_ntop(socket.AF_INET6, data[offset : offset + 16])
            offset += rdlen
        return None
    except Exception:
        return None


def _resolve_via_dns(host: str) -> tuple[list[str], list[str]]:
    """Resolve *host* via Termux nameservers. Returns ([ipv4], [ipv6])."""
    ipv4: list[str] = []
    ipv6: list[str] = []
    for ns in _nameservers():
        if not ipv4:
            ip = _dns_query(host, ns, _QTYPE_A)
            if ip:
                ipv4.append(ip)
        if not ipv6:
            ip6 = _dns_query(host, ns, _QTYPE_AAAA)
            if ip6:
                ipv6.append(ip6)
        if ipv4 and ipv6:
            break
    return ipv4, ipv6


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
            return _build_results(cached, port, family, type, proto)
        # Double-checked locking under _RESOLVE_LOCK: only one thread does
        # the actual DNS queries; concurrent callers wait and then hit the
        # cache. Prevents the UDP burst that loses responses.
        with _RESOLVE_LOCK:
            with _CACHE_LOCK:
                cached = _CACHE.get(host)
            if cached:
                return _build_results(cached, port, family, type, proto)
            ipv4, ipv6 = _resolve_via_dns(host)
            if not ipv4 and not ipv6:
                raise
            with _CACHE_LOCK:
                _CACHE[host] = tuple(ipv4 + ipv6)
            return _build_results(tuple(ipv4 + ipv6), port, family, type, proto)


def _build_results(addrs: tuple[str, ...], port, family, type, proto):
    """Build getaddrinfo-style tuples filtered by requested family."""
    results: list[tuple] = []
    want_v6 = family in (socket.AF_UNSPEC, socket.AF_INET6)
    want_v4 = family in (socket.AF_UNSPEC, socket.AF_INET)
    socktype = type or socket.SOCK_STREAM
    for ip in addrs:
        if ":" in ip:
            fam = socket.AF_INET6
            sockaddr = (ip, port, 0, 0)
            usable = want_v6
        else:
            fam = socket.AF_INET
            sockaddr = (ip, port)
            usable = want_v4
        if usable:
            results.append((fam, socktype, proto or 6, "", sockaddr))
    if not results:
        # Family mismatch: re-raise the original EAI for the caller.
        raise socket.gaierror(
            _EAI_NODATA,
            "No address associated with hostname (fallback family mismatch)",
        )
    # Prefer IPv4 first (matches native getaddrinfo ordering on Android).
    results.sort(key=lambda r: 0 if r[0] == socket.AF_INET else 1)
    return results


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