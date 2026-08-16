"""Tests for the Android Termux:API speech-to-text backend."""

from types import SimpleNamespace
from pathlib import Path

import tools.transcription_tools as stt


def test_termux_is_default_for_historical_local_provider(monkeypatch):
    monkeypatch.setattr(stt, "is_termux", lambda: True)
    monkeypatch.setattr(stt, "_termux_speech_to_text_available", lambda: True)
    monkeypatch.setattr(stt, "_HAS_FASTER_WHISPER", False)

    assert stt._get_provider({}) == "termux"
    assert stt._get_provider({"provider": "local"}) == "termux"
    assert stt._get_provider({"provider": "groq"}) == "none"


def test_termux_speech_to_text_parses_final_output(monkeypatch):
    calls = []

    monkeypatch.setattr(stt, "is_termux", lambda: True)
    monkeypatch.setattr(stt.shutil, "which", lambda name: "/usr/bin/termux-speech-to-text")

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        return SimpleNamespace(returncode=0, stdout="partial\ntexto final\n", stderr="")

    monkeypatch.setattr(stt.subprocess, "run", fake_run)
    result = stt._transcribe_termux_speech({"termux": {"progress": True}})

    assert result == {
        "success": True,
        "transcript": "texto final",
        "provider": "termux",
    }
    assert calls[0][0] == ["termux-speech-to-text", "-p"]
    assert calls[0][1]["stdin"] is stt.subprocess.DEVNULL


def test_termux_voice_recorder_uses_one_live_capture(monkeypatch, tmp_path):
    import tools.voice_mode as voice

    class FakeProcess:
        returncode = 0

        def communicate(self, **kwargs):
            return "parcial\nrespuesta final\n", ""

        def terminate(self):
            pass

        def kill(self):
            pass

    monkeypatch.setattr(voice, "_termux_speech_to_text_command", lambda: "termux-speech-to-text")
    monkeypatch.setattr(voice, "_termux_api_app_installed", lambda: True)
    monkeypatch.setattr(voice.subprocess, "Popen", lambda *args, **kwargs: FakeProcess())
    monkeypatch.setattr(voice, "_TEMP_DIR", str(tmp_path))

    recorder = voice.TermuxSpeechToTextRecorder()
    recorder.start()
    result_path = recorder.stop()

    assert result_path is not None
    assert Path(result_path).read_text(encoding="utf-8") == "respuesta final"
    assert voice.transcribe_recording(result_path)["transcript"] == "respuesta final"
