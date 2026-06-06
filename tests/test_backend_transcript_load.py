import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
from pathlib import Path


BACKEND_PATH = Path(__file__).resolve().parents[1] / "plugin" / "backend.py"


def load_backend():
    spec = importlib.util.spec_from_file_location("ai_commander_backend", BACKEND_PATH)
    backend = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(backend)
    return backend


class FakeResponse:
    def __init__(self, text="answer"):
        self.text = text

    def iter_lines(self, **kwargs):
        yield ('data: {"type":"response.output_text.delta","delta":' + json.dumps(self.text) + '}').encode()


def run_chat_with_input(backend, config, stdin_text, context=""):
    old_stdin = sys.stdin
    with tempfile.NamedTemporaryFile("w+", encoding="utf-8") as config_file, tempfile.NamedTemporaryFile("w+", encoding="utf-8") as context_file:
        json.dump(config, config_file)
        config_file.flush()
        context_file.write(context)
        context_file.flush()
        args = type("Args", (), {"config": config_file.name, "context": context_file.name})()
        sys.stdin = io.StringIO(stdin_text)
        stdout = io.StringIO()
        try:
            with contextlib.redirect_stdout(stdout):
                assert backend.run_chat(args) == 0
        finally:
            sys.stdin = old_stdin
    return stdout.getvalue()


def write_transcript(path, user, assistant):
    path.write_text(f"USER:\n{user}\n\nASSISTANT:\n{assistant}\n", encoding="utf-8")


def test_parse_saved_transcript_blocks():
    backend = load_backend()
    body = "USER:\nhello\n\nASSISTANT:\nhi\n"
    assert backend.parse_transcript_text(body) == [
        {"role": "user", "content": "hello"},
        {"role": "assistant", "content": "hi"},
    ]


def test_load_latest_restores_history_for_next_request_and_persists_trimmed_history():
    backend = load_backend()
    calls = []

    def fake_post(config, system, messages, *, stream, max_tokens):
        calls.append(messages)
        return "openai", FakeResponse("fresh answer"), True

    backend.post = fake_post
    old_env = dict(os.environ)
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["XDG_STATE_HOME"] = tmp
        transcript_dir = Path(tmp) / "ai-commander" / "transcripts"
        transcript_dir.mkdir(parents=True)
        older = transcript_dir / "chat-older.md"
        latest = transcript_dir / "chat-latest.md"
        write_transcript(older, "old", "old answer")
        write_transcript(latest, "loaded", "loaded answer")
        os.utime(older, (1, 1))
        os.utime(latest, (2, 2))
        state_path = Path(tmp) / "conversation.json"
        config = {
            "provider": "openai",
            "renderer": "cat",
            "chat_system_prompt": "sys",
            "max_conversation_messages": 3,
            "conversation_continuity": True,
            "conversation_state_file": str(state_path),
        }
        try:
            output = run_chat_with_input(backend, config, "/load\nnext\n/q\n")
        finally:
            os.environ.clear()
            os.environ.update(old_env)

        assert f"Transcript loaded: {latest} (2 messages)" in output
        assert len(calls) == 1
        assert calls[0] == [
            {"role": "user", "content": "loaded"},
            {"role": "assistant", "content": "loaded answer"},
            {"role": "user", "content": "next"},
        ]
        assert json.loads(state_path.read_text(encoding="utf-8")) == {
            "messages": [
                {"role": "user", "content": "loaded"},
                {"role": "assistant", "content": "loaded answer"},
                {"role": "user", "content": "next"},
                {"role": "assistant", "content": "fresh answer"},
            ][-3:]
        }


def test_load_list_number_and_explicit_path_keep_loop_alive_on_invalid_file():
    backend = load_backend()
    calls = []

    def fake_post(config, system, messages, *, stream, max_tokens):
        calls.append(messages)
        return "openai", FakeResponse("after load"), True

    backend.post = fake_post
    old_env = dict(os.environ)
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["XDG_STATE_HOME"] = tmp
        transcript_dir = Path(tmp) / "ai-commander" / "transcripts"
        transcript_dir.mkdir(parents=True)
        newest = transcript_dir / "chat-newest.md"
        second = transcript_dir / "chat-second.md"
        explicit = Path(tmp) / "explicit.md"
        invalid = Path(tmp) / "invalid.md"
        write_transcript(newest, "newest", "newest answer")
        write_transcript(second, "second", "second answer")
        write_transcript(explicit, "explicit", "explicit answer")
        invalid.write_text("not a transcript\n", encoding="utf-8")
        os.utime(newest, (3, 3))
        os.utime(second, (2, 2))
        config = {
            "provider": "openai",
            "renderer": "cat",
            "chat_system_prompt": "sys",
            "max_conversation_messages": 12,
            "conversation_continuity": False,
        }
        try:
            output = run_chat_with_input(
                backend,
                config,
                f"/load list\n/load 2\n/load {explicit}\n/load {invalid}\nnext\n/q\n",
            )
        finally:
            os.environ.clear()
            os.environ.update(old_env)

        assert "Recent transcripts:" in output
        assert f"1. {newest}" in output
        assert f"2. {second}" in output
        assert f"Transcript loaded: {second} (2 messages)" in output
        assert f"Transcript loaded: {explicit} (2 messages)" in output
        assert f"Load failed: Invalid transcript: {invalid}" in output
        assert len(calls) == 1
        assert calls[0] == [
            {"role": "user", "content": "explicit"},
            {"role": "assistant", "content": "explicit answer"},
            {"role": "user", "content": "next"},
        ]


if __name__ == "__main__":
    test_parse_saved_transcript_blocks()
    test_load_latest_restores_history_for_next_request_and_persists_trimmed_history()
    test_load_list_number_and_explicit_path_keep_loop_alive_on_invalid_file()
    print("ok")
