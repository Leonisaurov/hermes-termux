"""Tests for the Android Termux:API TTS backend."""

import json
from types import SimpleNamespace

import tools.tts_tool as tts


def test_termux_is_implicit_default(monkeypatch):
    monkeypatch.setattr(tts, "is_termux", lambda: True)
    assert tts._get_provider({}) == "termux"
    assert tts._get_provider({"provider": "edge"}) == "termux"
    assert tts._get_provider({"provider": "openai"}) == "openai"


def test_termux_tts_uses_stdin_without_api(monkeypatch):
    calls = []

    monkeypatch.setattr(tts, "is_termux", lambda: True)
    monkeypatch.setattr(tts.shutil, "which", lambda name: "/usr/bin/termux-tts-speak")

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr(tts.subprocess, "run", fake_run)
    result = tts.text_to_speech_tool(
        "Hola desde Android",
        provider="termux",
        speed=1.25,
    )

    payload = json.loads(result)
    assert payload["success"] is True
    assert payload["provider"] == "termux"
    assert payload["spoken"] is True
    assert calls[0][0] == ["termux-tts-speak", "-r", "1.25"]
    assert calls[0][1]["input"] == "Hola desde Android"
