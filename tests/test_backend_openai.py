import importlib.util
import os
import sys
from pathlib import Path

import contextlib
import io
import tempfile
import json


BACKEND_PATH = Path(__file__).resolve().parents[1] / "plugin" / "backend.py"


def load_backend():
    spec = importlib.util.spec_from_file_location("ai_commander_backend", BACKEND_PATH)
    backend = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = backend
    assert spec.loader is not None
    spec.loader.exec_module(backend)
    return backend


def header_value(headers, name):
    if isinstance(headers, dict):
        return headers.get(name)
    for key, value in headers:
        if key == name:
            return value
    return None


def test_codex_subscription_request_body_omits_public_api_fields():
    backend = load_backend()
    credential = {"type": "oauth", "headers": {"Authorization": "Bearer test"}}
    config = {
        "provider": "openai",
        "api_url": {"openai": "https://api.openai.com/v1/responses"},
        "subscription_api_url": {"openai": "https://chatgpt.com/backend-api/codex/responses"},
        "model": {"openai": "gpt-5.5"},
        "temperature": 0.1,
    }
    messages = [
        {"role": "user", "content": "first"},
        {"role": "assistant", "content": "second"},
        {"role": "user", "content": "third"},
    ]

    public_body = backend.build_body(
        config, "openai", "sys", messages, stream=True, max_tokens=200
    )
    body = backend.prepare_codex_body(public_body)
    headers = backend.headers_for("openai", credential)

    assert header_value(headers, "Authorization") == "Bearer test"
    assert backend.is_codex_subscription_response(
        config["subscription_api_url"]["openai"], credential
    )

    assert body["model"] == "gpt-5.5"
    assert body["instructions"] == "sys"
    assert body["input"] == [
        {"role": "user", "content": "first"},
        {"role": "assistant", "content": "second"},
        {"role": "user", "content": "third"},
    ]
    assert body["stream"] is True
    assert body["store"] is False
    assert "max_output_tokens" not in body
    assert "temperature" not in body
    assert "reasoning" not in body
    assert "previous_response_id" not in body


def test_openai_sse_parser_yields_text_deltas_only():
    backend = load_backend()
    lines = [
        b'data: {"type":"response.output_text.delta","delta":"printf ok"}',
        b'data: {"type":"response.output_text.delta","delta":"\\n## Print ok"}',
        b'data: {"type":"response.completed","response":{"status":"completed","output":[]}}',
        b"data: [DONE]",
    ]

    assert list(backend.parse_sse_lines(lines, "openai")) == ["printf ok", "\n## Print ok"]


def test_chat_prints_header_ignores_blank_and_keeps_history():
    backend = load_backend()
    calls = []
    responses = []

    class FakeResponse:
        def __init__(self, text):
            self.text = text
            self.chunk_sizes = []

        def iter_lines(self, **kwargs):
            self.chunk_sizes.append(kwargs.get("chunk_size"))
            yield ('data: {"type":"response.output_text.delta","delta":' + json.dumps(self.text) + '}').encode()
    def fake_post(config, system, messages, *, stream, max_tokens):
        calls.append(messages)
        response = FakeResponse("answer")
        responses.append(response)
        return "openai", response, True

    backend.post = fake_post
    config = {
        "provider": "openai",
        "renderer": "cat",
        "chat_system_prompt": "sys",
        "max_conversation_messages": 12,
        "conversation_continuity": False,
    }

    with tempfile.NamedTemporaryFile("w+", encoding="utf-8") as config_file, tempfile.NamedTemporaryFile("w+", encoding="utf-8") as context_file:
        json.dump(config, config_file)
        config_file.flush()
        context_file.write("ctx")
        context_file.flush()
        args = type("Args", (), {"config": config_file.name, "context": context_file.name})()
        old_stdin = sys.stdin
        sys.stdin = io.StringIO("\nfirst\nsecond\n/q\n")
        stdout = io.StringIO()
        try:
            with contextlib.redirect_stdout(stdout):
                assert backend.run_chat(args) == 0
        finally:
            sys.stdin = old_stdin

    output = stdout.getvalue()
    assert "AI Commander chat pane." in output
    assert "Renderer: cat" in output
    assert [response.chunk_sizes for response in responses] == [[1], [1]]
    assert output.count("answer") == 2
    assert len(calls) == 2
    assert calls[0] == [{"role": "user", "content": "first\n\nContext:\nctx"}]
    assert calls[1][0]["role"] == "user"
    assert calls[1][1] == {"role": "assistant", "content": "answer"}
    assert calls[1][2] == {"role": "user", "content": "second\n\nContext:\nctx"}


def test_chat_slash_commands_save_copy_and_clear_without_leaking_tokens():
    backend = load_backend()
    calls = []

    class FakeResponse:
        def iter_lines(self, **kwargs):
            yield b'data: {"type":"response.output_text.delta","delta":"answer"}'

    def fake_post(config, system, messages, *, stream, max_tokens):
        calls.append(messages)
        return "openai", FakeResponse(), True

    backend.post = fake_post
    old_env = dict(os.environ)
    old_stdin = sys.stdin
    with tempfile.TemporaryDirectory() as tmp:
        state_path = Path(tmp) / "conversation.json"
        config = {
            "provider": "openai",
            "renderer": "cat",
            "chat_system_prompt": "sys",
            "model": {"openai": "gpt-test"},
            "api_key": {"openai": "secret-token"},
            "api_url": {"openai": "https://api.example.test/responses"},
            "max_conversation_messages": 12,
            "conversation_continuity": True,
            "conversation_state_file": str(state_path),
        }
        with tempfile.NamedTemporaryFile("w+", encoding="utf-8") as config_file, tempfile.NamedTemporaryFile("w+", encoding="utf-8") as context_file:
            json.dump(config, config_file)
            config_file.flush()
            context_file.write("selected context line")
            context_file.flush()
            args = type("Args", (), {"config": config_file.name, "context": context_file.name})()
            os.environ["XDG_STATE_HOME"] = tmp
            sys.stdin = io.StringIO("/model\n/provider\n/context\nfirst\n/save\n/copy\n/clear\n/q\n")
            stdout = io.StringIO()
            try:
                with contextlib.redirect_stdout(stdout):
                    assert backend.run_chat(args) == 0
            finally:
                sys.stdin = old_stdin
                os.environ.clear()
                os.environ.update(old_env)

        output = stdout.getvalue()
        assert "Model: gpt-test" in output
        assert "Provider: openai, endpoint https://api.example.test/responses, auth api_key" in output
        assert "secret-token" not in output
        assert "Context: selected" in output
        assert "Preview: selected context line" in output
        assert "Transcript saved:" in output
        assert "Transcript copy unsupported" in output
        assert "Chat history cleared." in output
        saved = sorted((Path(tmp) / "ai-commander" / "transcripts").glob("chat-*.md"))
        assert len(saved) == 1
        assert "USER:\nfirst" in saved[0].read_text(encoding="utf-8")
        assert json.loads(state_path.read_text(encoding="utf-8")) == {"messages": []}
    assert len(calls) == 1


def test_chat_ctrl_c_cancels_response_and_keeps_loop_alive():
    backend = load_backend()
    calls = []
    stream_calls = 0

    class FakeResponse:
        pass

    def fake_post(config, system, messages, *, stream, max_tokens):
        calls.append(messages)
        return "openai", FakeResponse(), True

    def fake_iter_stream_deltas(response, provider):
        nonlocal stream_calls
        stream_calls += 1
        if stream_calls == 1:
            raise KeyboardInterrupt
        yield "second answer"

    backend.post = fake_post
    backend.iter_stream_deltas = fake_iter_stream_deltas
    config = {
        "provider": "openai",
        "renderer": "cat",
        "chat_system_prompt": "sys",
        "max_conversation_messages": 12,
        "conversation_continuity": False,
    }

    with tempfile.NamedTemporaryFile("w+", encoding="utf-8") as config_file, tempfile.NamedTemporaryFile("w+", encoding="utf-8") as context_file:
        json.dump(config, config_file)
        config_file.flush()
        context_file.flush()
        args = type("Args", (), {"config": config_file.name, "context": context_file.name})()
        old_stdin = sys.stdin
        sys.stdin = io.StringIO("first\nsecond\n/q\n")
        stdout = io.StringIO()
        try:
            with contextlib.redirect_stdout(stdout):
                assert backend.run_chat(args) == 0
        finally:
            sys.stdin = old_stdin

    output = stdout.getvalue()
    assert "AI response cancelled" in output
    assert "Chat remains open." in output
    assert "second answer" in output
    assert len(calls) == 2
    assert calls[1] == [{"role": "user", "content": "second"}]


def test_rich_renderer_uses_live_markdown_updates():
    backend = load_backend()
    assert backend.rich_available()

    stdout = io.StringIO()
    with contextlib.redirect_stdout(stdout):
        writer = backend.DeltaWriter("rich")
        writer.write("# Hello\n\n")
        writer.write("```python\nprint('ok')\n```\n")
        writer.close()

    output = stdout.getvalue()
    assert "\x1b[" in output
    assert "Hello" in output
    assert "print" in output
    assert "```" not in output
    assert "\x1b7" not in output
    assert "╭" in output
    assert "╰" in output
    assert "\x1b8\x1b[J" not in output


if __name__ == "__main__":
    test_codex_subscription_request_body_omits_public_api_fields()
    test_openai_sse_parser_yields_text_deltas_only()
    test_chat_prints_header_ignores_blank_and_keeps_history()
    test_chat_slash_commands_save_copy_and_clear_without_leaking_tokens()
    test_chat_ctrl_c_cancels_response_and_keeps_loop_alive()
    test_rich_renderer_uses_live_markdown_updates()
    print("ok")
