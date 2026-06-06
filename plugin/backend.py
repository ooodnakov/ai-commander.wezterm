#!/usr/bin/env python3
"""Linux Python backend for ai-commander.wezterm."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime
import hashlib
import importlib.metadata
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import venv
from pathlib import Path
from typing import Any, Iterable

try:
    import requests
except ImportError:  # explicit setup/doctor must work before deps are installed
    requests = None


DEFAULT_CONFIG: dict[str, Any] = {
    "provider": "anthropic",
    "auth_type": {"anthropic": "api_key", "openai": "api_key"},
    "api_key": {"anthropic": None, "openai": None},
    "api_url": {
        "anthropic": "https://api.anthropic.com/v1/messages",
        "openai": "https://api.openai.com/v1/responses",
    },
    "subscription_api_url": {
        "anthropic": "https://api.anthropic.com/v1/messages",
        "openai": "https://chatgpt.com/backend-api/codex/responses",
    },
    "oauth": {
        "anthropic": {"access_token": None, "credentials_path": None},
        "openai": {"access_token": None, "account_id": None, "credentials_path": None},
    },
    "model": {"anthropic": "claude-haiku-4-5", "openai": "gpt-5.5"},
    "max_tokens": 4000,
    "chat_max_tokens": 16000,
    "renderer": "rich",
    "conversation_continuity": False,
    "conversation_state_file": str(Path.home() / ".wezterm_ai_conversation_state.json"),
    "max_conversation_messages": 12,
    "temperature": 0.1,
    "chat_system_prompt": "\n".join(
        [
            "You are a helpful assistant running inside a terminal.",
            "Answer questions clearly and concisely using markdown formatting.",
            "Use code blocks with language tags for any code or commands.",
            "Keep explanations practical and actionable.",
        ]
    ),
}


class BackendError(Exception):
    pass


DEBUG_COUNTER = 0
SENSITIVE_KEY_RE = re.compile(
    r"(authorization|api[_-]?key|access[_-]?token|auth[_-]?token|bearer|password|secret|credential)",
    re.I,
)
SECRET_VALUE_RE = re.compile(
    r"(Bearer\s+)[A-Za-z0-9._~+/=-]+|"
    r"(sk-[A-Za-z0-9._-]+)|"
    r"(sk-ant-[A-Za-z0-9._-]+)|"
    r"([A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})"
)


def debug_enabled() -> bool:
    return os.getenv("WEZTERM_AI_COMMANDER_DEBUG") == "1"


def user_state_dir() -> Path:
    explicit = os.getenv("WEZTERM_AI_COMMANDER_STATE_DIR")
    if is_non_empty(explicit):
        return Path(expand_path(explicit) or explicit)
    xdg_state = os.getenv("XDG_STATE_HOME")
    if is_non_empty(xdg_state):
        return Path(expand_path(xdg_state) or xdg_state) / "ai-commander.wezterm"
    return Path.home() / ".local" / "state" / "ai-commander.wezterm"


def debug_dir() -> Path:
    explicit = os.getenv("WEZTERM_AI_COMMANDER_DEBUG_DIR")
    if is_non_empty(explicit):
        return Path(expand_path(explicit) or explicit)
    return user_state_dir() / "debug"


def debug_location() -> str:
    return str(debug_dir())


def redact_text(value: str) -> str:
    return SECRET_VALUE_RE.sub(
        lambda match: (match.group(1) + "<redacted>") if match.group(1) else "<redacted>",
        value,
    )


def redact(value: Any, key: str = "") -> Any:
    if SENSITIVE_KEY_RE.search(key):
        return "<redacted>"
    if isinstance(value, dict):
        return {str(k): redact(v, str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(item, key) for item in value]
    if isinstance(value, str):
        return redact_text(value)
    return value


def summarize_message(item: Any) -> Any:
    if not isinstance(item, dict):
        return {"type": type(item).__name__}
    content = item.get("content")
    text = json.dumps(content, ensure_ascii=False, sort_keys=True) if not isinstance(content, str) else content
    return {
        "role": item.get("role"),
        "content_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "content_bytes": len(text.encode("utf-8")),
    }


def summarize_history(history: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "message_count": len(history),
        "messages": [summarize_message(item) for item in history],
    }


def write_debug_json(kind: str, payload: Any) -> str | None:
    if not debug_enabled():
        return None
    global DEBUG_COUNTER
    DEBUG_COUNTER += 1
    directory = debug_dir()
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}-{DEBUG_COUNTER:04d}-{kind}.json"
    path.write_text(
        json.dumps(redact(payload), ensure_ascii=False, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    return str(path)


def write_backend_metadata(mode: str, args: argparse.Namespace | None = None) -> str | None:
    payload = {
        "mode": mode,
        "argv": sys.argv,
        "cwd": os.getcwd(),
        "python": sys.executable,
        "prefix": sys.prefix,
        "base_prefix": getattr(sys, "base_prefix", sys.prefix),
        "backend": str(Path(__file__).resolve()),
    }
    if args is not None:
        payload["args"] = vars(args)
    return write_debug_json("backend_command", payload)


def is_non_empty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def deep_merge(base: Any, override: Any) -> Any:
    if isinstance(base, dict) and isinstance(override, dict):
        merged = dict(base)
        for key, value in override.items():
            merged[key] = deep_merge(merged.get(key), value)
        return merged
    return override if override is not None else base


def load_json(path: str | Path) -> Any:
    try:
        with open(expand_path(path), "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise BackendError(f"Config not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise BackendError(f"Invalid JSON in {path}: {exc}") from exc
    except OSError as exc:
        raise BackendError(f"Cannot read {path}: {exc}") from exc


def load_config(path: str | Path) -> dict[str, Any]:
    value = load_json(path)
    if not isinstance(value, dict):
        raise BackendError("Config JSON must be an object")
    return deep_merge(DEFAULT_CONFIG, value)


def read_text(path: str | Path) -> str:
    try:
        return Path(expand_path(path)).read_text(encoding="utf-8")
    except OSError as exc:
        raise BackendError(f"Cannot read {path}: {exc}") from exc


def expand_path(path: str | Path | None) -> str | None:
    if path is None:
        return None
    return os.path.expandvars(os.path.expanduser(str(path)))


def get_path(value: Any, dotted: str) -> Any:
    cur = value
    for part in dotted.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur if cur != "" else None


def first_path(value: Any, paths: Iterable[str]) -> Any:
    for path in paths:
        found = get_path(value, path)
        if found is not None:
            return found
    return None


def first_env(names: Iterable[str]) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if is_non_empty(value):
            return value
    return None


def read_optional_json(path: str | Path | None) -> Any:
    expanded = expand_path(path)
    if not expanded:
        return None
    try:
        with open(expanded, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def default_claude_credentials_path() -> str:
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if is_non_empty(config_dir):
        return str(Path(config_dir) / ".credentials.json")
    return str(Path.home() / ".claude" / ".credentials.json")


def default_codex_auth_path() -> str:
    codex_home = os.environ.get("CODEX_HOME")
    if is_non_empty(codex_home):
        return str(Path(codex_home) / "auth.json")
    return str(Path.home() / ".codex" / "auth.json")


def resolve_api_key(
    config: dict[str, Any], provider: str
) -> tuple[str | None, str | None]:
    configured = (config.get("api_key") or {}).get(provider)
    if is_non_empty(configured):
        return configured, f"config api_key.{provider}"
    if provider == "anthropic":
        key = first_env(["ANTHROPIC_API_KEY"])
        return key, "ANTHROPIC_API_KEY" if key else None
    if provider == "openai":
        key = first_env(["OPENAI_API_KEY"])
        if key:
            return key, "OPENAI_API_KEY"
        auth_json = read_optional_json(default_codex_auth_path())
        key = (
            first_path(auth_json, ["OPENAI_API_KEY", "api_key", "apiKey"])
            if auth_json
            else None
        )
        if is_non_empty(key):
            return key, "Codex auth.json OPENAI_API_KEY"
    return None, None


def resolve_oauth(
    config: dict[str, Any], provider: str
) -> tuple[str | None, str | None, str | None]:
    oauth = (config.get("oauth") or {}).get(provider) or {}
    explicit = oauth.get("access_token") or oauth.get("token")
    if is_non_empty(explicit):
        return (
            explicit,
            oauth.get("account_id"),
            f"config oauth.{provider}.access_token",
        )
    if provider == "anthropic":
        token = first_env(["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"])
        if token:
            return token, None, "CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_AUTH_TOKEN"
        credentials_path = (
            oauth.get("credentials_path") or default_claude_credentials_path()
        )
        credentials = read_optional_json(credentials_path)
        token = (
            first_path(
                credentials,
                [
                    "claudeAiOauth.accessToken",
                    "claudeAiOauth.access_token",
                    "accessToken",
                    "access_token",
                ],
            )
            if credentials
            else None
        )
        if is_non_empty(token):
            return token, None, credentials_path
    if provider == "openai":
        token = first_env(
            ["CODEX_AUTH_TOKEN", "OPENAI_AUTH_TOKEN", "CHATGPT_AUTH_TOKEN"]
        )
        if token:
            return token, oauth.get("account_id"), "CODEX_AUTH_TOKEN/OPENAI_AUTH_TOKEN"
        auth_path = (
            oauth.get("credentials_path")
            or oauth.get("auth_path")
            or default_codex_auth_path()
        )
        auth_json = read_optional_json(auth_path)
        token = (
            first_path(
                auth_json,
                [
                    "access_token",
                    "accessToken",
                    "tokens.access_token",
                    "tokens.accessToken",
                    "tokens.access",
                    "chatgpt.access_token",
                    "chatgpt.accessToken",
                ],
            )
            if auth_json
            else None
        )
        account_id = oauth.get("account_id") or (
            first_path(
                auth_json,
                [
                    "account_id",
                    "accountId",
                    "chatgpt_account_id",
                    "chatgptAccountId",
                    "chatgpt.account_id",
                    "chatgpt.accountId",
                    "tokens.account_id",
                    "tokens.accountId",
                ],
            )
            if auth_json
            else None
        )
        if is_non_empty(token):
            return token, account_id, auth_path
    return None, None, None


def resolve_auth(config: dict[str, Any], provider: str) -> dict[str, Any]:
    configured = (config.get("auth_type") or {}).get(provider)
    auth_type = configured or "api_key"
    if auth_type in ("auto", "api_key"):
        api_key, source = resolve_api_key(config, provider)
        if api_key:
            header_name = "x-api-key" if provider == "anthropic" else "Authorization"
            header_value = api_key if provider == "anthropic" else f"Bearer {api_key}"
            return {
                "type": "api_key",
                "source": source,
                "headers": {header_name: header_value},
            }
    if auth_type in ("auto", "oauth", "subscription", "codex"):
        token, account_id, source = resolve_oauth(config, provider)
        if token:
            headers = {"Authorization": f"Bearer {token}"}
            if provider == "openai":
                headers["User-Agent"] = "codex-cli"
                if account_id:
                    headers["ChatGPT-Account-Id"] = str(account_id)
            return {
                "type": "oauth",
                "source": source,
                "account_id": account_id,
                "headers": headers,
            }
    hint = f'Please set api_key.{provider} or configure auth_type.{provider} = "oauth" with a supported token.'
    if provider == "anthropic":
        hint += " Claude OAuth can use CLAUDE_CODE_OAUTH_TOKEN or ~/.claude/.credentials.json."
    elif provider == "openai":
        hint += " Codex OAuth can use CODEX_AUTH_TOKEN/OPENAI_AUTH_TOKEN or ~/.codex/auth.json."
    raise BackendError(f"Error: {provider} credentials not configured. {hint}")


def provider_name(config: dict[str, Any]) -> str:
    provider = config.get("provider") or "anthropic"
    if provider not in ("anthropic", "openai"):
        raise BackendError(
            f"Error: Unsupported provider: {provider}. Available: anthropic, openai"
        )
    return provider


def resolve_endpoint(
    config: dict[str, Any], provider: str, credential: dict[str, Any]
) -> str:
    urls = config.get("api_url") or {}
    api_url = urls.get(provider)
    if credential.get("type") == "oauth":
        subscription_url = (config.get("subscription_api_url") or {}).get(provider)
        if subscription_url:
            api_url = subscription_url
    if not is_non_empty(api_url):
        raise BackendError(f"api_url.{provider} is not configured")
    return api_url


def reasoning_effort_for_model(model: Any) -> str | None:
    if not isinstance(model, str):
        return None
    return (
        "low"
        if model.startswith("gpt-5")
        or (len(model) >= 2 and model[0] == "o" and model[1].isdigit())
        else None
    )


def as_openai_content(content: Any) -> Any:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict) and is_non_empty(part.get("text")):
                parts.append(part["text"])
        if parts:
            return "".join(parts)
    return content


def build_body(
    config: dict[str, Any],
    provider: str,
    system: str,
    messages: list[dict[str, Any]],
    *,
    stream: bool,
    max_tokens: int,
) -> dict[str, Any]:
    model = (config.get("model") or {}).get(provider)
    temperature = config.get("temperature", 0.1)
    if provider == "anthropic":
        return {
            "model": model,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": stream,
            "system": system,
            "messages": [
                {"role": item["role"], "content": item["content"]} for item in messages
            ],
        }
    input_messages = [
        {"role": item["role"], "content": as_openai_content(item["content"])}
        for item in messages
    ]
    body: dict[str, Any] = {
        "model": model,
        "instructions": system,
        "input": input_messages,
        "max_output_tokens": max_tokens,
        "temperature": temperature,
        "stream": stream,
        "store": False,
    }
    effort = reasoning_effort_for_model(model)
    if effort:
        body["reasoning"] = {"effort": effort}
    return body


def is_codex_subscription_response(api_url: str, credential: dict[str, Any]) -> bool:
    return (
        credential.get("type") == "oauth"
        and "chatgpt.com/backend-api/codex/responses" in api_url
    )


def prepare_codex_body(body: dict[str, Any]) -> dict[str, Any]:
    return {
        "model": body.get("model"),
        "instructions": body.get("instructions"),
        "input": body.get("input"),
        "stream": True,
        "store": False,
    }


def headers_for(provider: str, credential: dict[str, Any]) -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if provider == "anthropic":
        headers["anthropic-version"] = "2023-06-01"
    headers.update(credential["headers"])
    return headers


def extract_openai_text(response: Any) -> str | None:
    if not isinstance(response, dict):
        return None
    if is_non_empty(response.get("output_text")):
        return response["output_text"]
    output = response.get("output")
    if not isinstance(output, list):
        return None
    parts: list[str] = []
    for item in output:
        if not isinstance(item, dict) or item.get("type", "message") != "message":
            continue
        content = item.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif (
                isinstance(block, dict)
                and block.get("type", "output_text") == "output_text"
            ):
                text = block.get("text") or block.get("output_text")
                if is_non_empty(text):
                    parts.append(text)
    return "".join(parts) if parts else None


def no_openai_text_error(response: Any) -> str:
    if not isinstance(response, dict):
        return "Error: OpenAI response was not a JSON object"
    error = response.get("error")
    if isinstance(error, dict):
        return (
            f"API error: {error.get('message') or error.get('code') or 'Unknown error'}"
        )
    if response.get("status") == "incomplete":
        details = (
            response.get("incomplete_details")
            if isinstance(response.get("incomplete_details"), dict)
            else {}
        )
        reason = str(details.get("reason") or "unknown reason")
        message = f"Error: OpenAI response incomplete: {reason}; no assistant text"
        if reason == "max_output_tokens":
            tokens = (
                (response.get("usage") or {}).get("output_tokens_details") or {}
            ).get("reasoning_tokens")
            if tokens is not None:
                message += f" (reasoning tokens used: {tokens})"
            message += (
                ". Increase max_tokens/chat_max_tokens or lower reasoning effort."
            )
        return message
    status = response.get("status")
    if status and status != "completed":
        return f"Error: OpenAI response status {status}; no assistant text"
    return "Error: No content found in OpenAI Responses API response"


def extract_anthropic_text(response: Any) -> str | None:
    if not isinstance(response, dict) or not isinstance(response.get("content"), list):
        return None
    parts = [
        block.get("text")
        for block in response["content"]
        if isinstance(block, dict) and is_non_empty(block.get("text"))
    ]
    return "".join(parts) if parts else None


def extract_response(provider: str, response: Any) -> str:
    if isinstance(response, dict) and response.get("error"):
        error = response["error"]
        if isinstance(error, dict):
            raise BackendError(
                f"API error: {error.get('message') or error.get('code') or 'Unknown error'}"
            )
        raise BackendError(f"API error: {error}")
    if isinstance(response, dict) and response.get("detail"):
        raise BackendError(f"API error: {response['detail']}")
    if provider == "openai":
        text = extract_openai_text(response)
        if text is not None:
            return text
        raise BackendError(no_openai_text_error(response))
    text = extract_anthropic_text(response)
    if text is not None:
        return text
    raise BackendError("Error: No content found in Anthropic Messages API response")


def parse_sse_lines(
    lines: Iterable[bytes],
    provider: str,
    debug_stream: dict[str, Any] | None = None,
) -> Iterable[str]:
    for raw in lines:
        line = raw.decode("utf-8", errors="replace").strip()
        if debug_stream is not None:
            debug_stream.setdefault("sse_lines", []).append(line)
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            event = json.loads(payload)
        except json.JSONDecodeError:
            if debug_stream is not None:
                debug_stream.setdefault("invalid_events", []).append(payload)
            continue
        if debug_stream is not None:
            debug_stream.setdefault("events", []).append(event)
        if provider == "openai":
            if event.get("type") == "response.output_text.delta" and isinstance(event.get("delta"), str):
                yield event["delta"]
            elif event.get("type") in ("response.failed", "error"):
                error = event.get("error") or (event.get("response") or {}).get("error")
                if isinstance(error, dict):
                    raise BackendError(f"API error: {error.get('message') or error.get('code') or 'Unknown error'}")
                raise BackendError(f"API error: {error or 'Unknown error'}")
        elif event.get("type") == "content_block_delta":
            delta = event.get("delta")
            if isinstance(delta, dict) and isinstance(delta.get("text"), str):
                yield delta["text"]


def iter_stream_deltas(response: Any, provider: str) -> Iterable[str]:
    debug_stream = {"provider": provider} if debug_enabled() else None
    try:
        yield from parse_sse_lines(
            response.iter_lines(chunk_size=1),
            provider,
            debug_stream,
        )
    finally:
        if debug_stream is not None:
            write_debug_json("response_stream", debug_stream)


def resolve_command_path(command: str) -> str | None:
    path = shutil.which(command)
    if path:
        return path
    if "/" in command:
        return command if Path(command).exists() else None
    for candidate in (
        f"/usr/bin/{command}",
        f"/usr/local/bin/{command}",
        f"{Path.home()}/.local/bin/{command}",
        f"{Path.home()}/.cargo/bin/{command}",
        f"/home/linuxbrew/.linuxbrew/bin/{command}",
    ):
        if Path(candidate).exists():
            return candidate
    return None


def resolve_renderer_argv(argv: list[str]) -> list[str] | None:
    if not argv:
        return None
    resolved = resolve_command_path(argv[0])
    if not resolved:
        return None
    return [resolved] + argv[1:]


def rich_available() -> bool:
    try:
        import rich  # noqa: F401
        from rich.console import Console  # noqa: F401
        from rich.live import Live  # noqa: F401
        from rich.markdown import Markdown  # noqa: F401
    except ImportError:
        return False
    return True

class DeltaWriter:
    def __init__(self, renderer: Any, theme: Any = None):
        self.process: subprocess.Popen[str] | None = None
        self.raw = True
        self.rich = False
        self.warned = False
        self.buffer = ""
        self.live = None
        self.markdown_cls = None
        self.panel_cls = None
        self.text_cls = None
        self.box = None
        self.palette = theme_palette(theme)
        command = str(renderer or "").strip()
        self.command = command
        self.resolved_argv: list[str] | None = None
        self.bytes_written = 0
        if not command or command == "cat":
            return
        try:
            argv = shlex.split(command)
        except ValueError:
            self._warn(f"renderer command is not parseable: {command}; using raw markdown")
            return
        if not argv:
            return

        if argv[0] == "rich":
            try:
                from rich import box
                from rich.console import Console
                from rich.live import Live
                from rich.markdown import Markdown
                from rich.panel import Panel
                from rich.text import Text
            except ImportError:
                self._warn("Rich is not installed; run the setup command from README or set renderer = 'cat'")
                return
            console = Console(
                force_terminal=True,
                color_system="truecolor",
                width=max(40, shutil.get_terminal_size((100, 30)).columns),
                soft_wrap=False,
            )
            self.markdown_cls = Markdown
            self.panel_cls = Panel
            self.text_cls = Text
            self.box = box
            self.live = Live(
                self._rich_renderable(),
                console=console,
                refresh_per_second=12,
                screen=False,
                transient=False,
                redirect_stdout=False,
                redirect_stderr=False,
                vertical_overflow="ellipsis",
            )
            self.live.start(refresh=False)
            self.rich = True
            self.raw = False
            return

        resolved = resolve_renderer_argv(argv)
        if not resolved:
            self._warn(f"renderer command not found: {argv[0]}; using raw markdown")
            return
        try:
            self.resolved_argv = resolved
            self.process = subprocess.Popen(resolved, stdin=subprocess.PIPE, text=True)
            self.raw = False
        except OSError as exc:
            self.process = None
            self.raw = True
            self._warn(f"renderer failed to start: {exc}; using raw markdown")

    def _warn(self, message: str) -> None:
        if self.warned:
            return
        sys.stdout.write(f"\n[ai-commander] {message}\n")
        sys.stdout.flush()
        self.warned = True

    def _rich_renderable(self):
        if self.markdown_cls is None or self.panel_cls is None or self.text_cls is None or self.box is None:
            return self.buffer
        if self.buffer.strip():
            body = self.markdown_cls(
                self.buffer,
                code_theme="monokai",
                inline_code_theme="monokai",
                hyperlinks=False,
            )
        else:
            body = self.text_cls("waiting for response…", style="dim")
        return self.panel_cls(
            body,
            title=self.text_cls(" AI ", style=f"bold {self.palette['accent2']}"),
            border_style=self.palette["accent2"],
            box=self.box.ROUNDED,
            padding=(0, 1),
        )

    def _render_rich(self) -> None:
        if not self.rich or self.live is None:
            return
        self.live.update(self._rich_renderable(), refresh=True)

    def _debug_state(self, phase: str) -> None:
        write_debug_json(
            "renderer_state",
            {
                "phase": phase,
                "renderer": self.command,
                "resolved_argv": self.resolved_argv,
                "raw": self.raw,
                "rich": self.rich,
                "warned": self.warned,
                "buffer_bytes": len(self.buffer.encode("utf-8")),
                "bytes_written": self.bytes_written,
                "has_process": self.process is not None,
            },
        )

    def write(self, text: str) -> None:
        self.bytes_written += len(text.encode("utf-8"))
        if self.rich:
            self.buffer += text
            self._render_rich()
            return
        if self.raw or self.process is None or self.process.stdin is None:
            print(text, end="", flush=True)
            return
        try:
            self.process.stdin.write(text)
            self.process.stdin.flush()
        except BrokenPipeError:
            self.raw = True
            print(text, end="", flush=True)

    def close(self) -> None:
        try:
            if self.rich:
                self._render_rich()
                if self.live is not None:
                    self.live.stop()
                return
            if self.process is None:
                return
            if self.process.stdin is not None:
                try:
                    self.process.stdin.close()
                except OSError:
                    pass
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
        finally:
            self._debug_state("close")
def post(
    config: dict[str, Any],
    system: str,
    messages: list[dict[str, Any]],
    *,
    stream: bool,
    max_tokens: int,
):
    if requests is None:
        raise BackendError(
            "Python dependency 'requests' is not installed. Run backend.py setup explicitly."
        )
    provider = provider_name(config)
    credential = resolve_auth(config, provider)
    api_url = resolve_endpoint(config, provider, credential)
    body = build_body(
        config, provider, system, messages, stream=stream, max_tokens=max_tokens
    )
    codex_stream = is_codex_subscription_response(api_url, credential)
    if codex_stream:
        body = prepare_codex_body(body)
    request_stream = stream or codex_stream
    headers = headers_for(provider, credential)
    request_debug_path = write_debug_json(
        "request",
        {
            "provider": provider,
            "model": body.get("model"),
            "endpoint": api_url,
            "auth_type": credential.get("type"),
            "auth_source": credential.get("source"),
            "stream": request_stream,
            "headers": headers,
            "body": body,
        },
    )
    try:
        response = requests.post(
            api_url,
            headers=headers,
            json=body,
            stream=request_stream,
            timeout=(10, 120),
        )
        response.raise_for_status()
        write_debug_json(
            "response_metadata",
            {
                "provider": provider,
                "status_code": getattr(response, "status_code", None),
                "headers": dict(getattr(response, "headers", {}) or {}),
                "request_debug": request_debug_path,
                "stream": request_stream,
            },
        )
        return provider, response, request_stream
    except requests.RequestException as exc:
        suffix = f" Debug files: {debug_location()}" if debug_enabled() else ""
        raise BackendError(f"HTTP request failed: {exc}.{suffix}") from exc


def run_generate(args: argparse.Namespace) -> int:
    config = load_config(args.config)
    system = read_text(args.system)
    prompt = read_text(args.prompt)
    provider, response, streamed = post(
        config,
        system,
        [{"role": "user", "content": prompt}],
        stream=False,
        max_tokens=int(config.get("max_tokens") or 4000),
    )
    if streamed:
        print("".join(iter_stream_deltas(response, provider)), end="")
        return 0
    try:
        payload = response.json()
    except ValueError as exc:
        write_debug_json(
            "response_text",
            {"provider": provider, "text": getattr(response, "text", "")},
        )
        raise BackendError(
            f"Failed to parse API response: {response.text[:1500]}"
        ) from exc
    write_debug_json("response_body", {"provider": provider, "body": payload})
    print(extract_response(provider, payload), end="")
    return 0


def trim_history(history: list[dict[str, str]], limit: Any) -> list[dict[str, str]]:
    try:
        max_messages = int(limit)
    except (TypeError, ValueError):
        max_messages = 12
    if max_messages <= 0 or len(history) <= max_messages:
        return history
    return history[-max_messages:]


def load_history(config: dict[str, Any]) -> list[dict[str, str]]:
    path = config.get("conversation_state_file")
    if not config.get("conversation_continuity"):
        write_debug_json("history_load", {"enabled": False, "path": path})
        return []
    state = read_optional_json(path)
    history: list[dict[str, str]] = []
    if isinstance(state, list):
        history = [
            item
            for item in state
            if isinstance(item, dict) and item.get("role") in ("user", "assistant")
        ]
    elif isinstance(state, dict) and isinstance(state.get("messages"), list):
        history = [
            item
            for item in state["messages"]
            if isinstance(item, dict) and item.get("role") in ("user", "assistant")
        ]
    write_debug_json(
        "history_load",
        {"enabled": True, "path": path, "snapshot": summarize_history(history)},
    )
    return history


def save_history(config: dict[str, Any], history: list[dict[str, str]]) -> None:
    path = expand_path(config.get("conversation_state_file"))
    if not config.get("conversation_continuity"):
        write_debug_json(
            "history_save",
            {"enabled": False, "path": path, "snapshot": summarize_history(history)},
        )
        return
    if not path:
        return
    write_debug_json(
        "history_save",
        {"enabled": True, "path": path, "snapshot": summarize_history(history)},
    )
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps({"messages": history}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def contextual_prompt(prompt: str, context: str) -> str:
    if not context.strip():
        return prompt
    return f"{prompt}\n\nContext:\n{context}"


def model_for(config: dict[str, Any], provider: str) -> str:
    return str((config.get("model") or {}).get(provider) or "")


def ansi_enabled() -> bool:
    return (
        hasattr(sys.stdout, "isatty")
        and sys.stdout.isatty()
        and not os.getenv("NO_COLOR")
    )



def normalize_hex_color(value: Any, fallback: str) -> str:
    text = str(value or "").strip()
    if len(text) == 7 and text[0] == "#":
        try:
            int(text[1:], 16)
        except ValueError:
            return fallback
        return text
    return fallback


def theme_palette(theme: Any = None) -> dict[str, str]:
    colors = theme if isinstance(theme, dict) else {}
    return {
        "foreground": normalize_hex_color(colors.get("foreground"), "#d8dee9"),
        "background": normalize_hex_color(colors.get("background"), "#11111b"),
        "accent": normalize_hex_color(colors.get("accent"), "#cba6f7"),
        "accent2": normalize_hex_color(colors.get("accent2"), "#89dceb"),
        "muted": normalize_hex_color(colors.get("muted"), "#6c7086"),
        "success": normalize_hex_color(colors.get("success"), "#a6e3a1"),
        "warning": normalize_hex_color(colors.get("warning"), "#f9e2af"),
    }


def hex_ansi(text: str, color: str, *, bold: bool = False) -> str:
    if not ansi_enabled():
        return text
    color = normalize_hex_color(color, "#ffffff")
    red = int(color[1:3], 16)
    green = int(color[3:5], 16)
    blue = int(color[5:7], 16)
    prefix = "1;" if bold else ""
    return f"\x1b[{prefix}38;2;{red};{green};{blue}m{text}\x1b[0m"


def style(text: str, code: str) -> str:
    if not ansi_enabled():
        return text
    return f"\x1b[{code}m{text}\x1b[0m"


def terminal_width(default: int = 80) -> int:
    return max(40, shutil.get_terminal_size((default, 24)).columns)


def shell_quote_label(value: str, max_len: int = 36) -> str:
    clean = " ".join(str(value or "").split())
    if len(clean) <= max_len:
        return clean
    return clean[: max_len - 1] + "…"


def context_summary(context: str) -> tuple[str, str]:
    if not context.strip():
        return "none, 0 chars, 0 lines", ""
    line_count = context.count("\n") + 1
    char_count = len(context)
    preview = " ".join(context.split())
    if len(preview) > 160:
        preview = preview[:159] + "…"
    return f"selected, {char_count} chars, {line_count} lines", preview


def transcript_text(transcript: list[dict[str, str]]) -> str:
    parts: list[str] = []
    for item in transcript:
        role = str(item.get("role") or "").strip() or "message"
        content = str(item.get("content") or "")
        parts.append(f"{role.upper()}:\n{content}")
    return "\n\n".join(parts) + ("\n" if parts else "")

TRANSCRIPT_HEADER_RE = re.compile(r"(?m)^(USER|ASSISTANT):\n")


def parse_transcript_text(body: str) -> list[dict[str, str]]:
    matches = list(TRANSCRIPT_HEADER_RE.finditer(body))
    messages: list[dict[str, str]] = []
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        content = body[start:end]
        if content.endswith("\n\n"):
            content = content[:-2]
        elif content.endswith("\n"):
            content = content[:-1]
        messages.append({"role": match.group(1).lower(), "content": content})
    return messages


def transcript_paths() -> list[Path]:
    target_dir = chat_state_dir() / "transcripts"
    try:
        paths = [path for path in target_dir.iterdir() if path.is_file()]
    except OSError:
        return []
    paths.sort(key=lambda path: (path.stat().st_mtime_ns, path.name), reverse=True)
    return paths


def load_transcript_path(path: Path) -> list[dict[str, str]]:
    try:
        body = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise BackendError(f"Cannot read transcript: {path}") from exc
    messages = parse_transcript_text(body)
    if not messages:
        raise BackendError(f"Invalid transcript: {path}")
    return messages


def handle_load_command(
    command: str,
    config: dict[str, Any],
    history: list[dict[str, str]],
    transcript: list[dict[str, str]],
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    parts = command.strip().split(maxsplit=1)
    arg = parts[1].strip() if len(parts) > 1 else "latest"
    paths = transcript_paths()
    if arg == "list":
        if not paths:
            print("No saved transcripts found.", flush=True)
            return history, transcript
        print("Recent transcripts:", flush=True)
        for index, path in enumerate(paths[:10], start=1):
            print(f"{index}. {path}", flush=True)
        return history, transcript

    try:
        if arg == "latest":
            if not paths:
                raise BackendError("No saved transcripts found.")
            path = paths[0]
        elif arg.isdigit():
            index = int(arg)
            if index <= 0 or index > len(paths):
                raise BackendError(f"No transcript #{index}. Use /load list.")
            path = paths[index - 1]
        else:
            path = Path(expand_path(arg) or arg)
        loaded = load_transcript_path(path)
    except BackendError as exc:
        print(f"Load failed: {exc}", flush=True)
        return history, transcript

    history = trim_history(loaded.copy(), config.get("max_conversation_messages"))
    transcript = loaded.copy()
    save_history(config, history)
    print(f"Transcript loaded: {path} ({len(loaded)} messages)", flush=True)
    return history, transcript


def chat_state_dir() -> Path:
    xdg_state = os.environ.get("XDG_STATE_HOME")
    if is_non_empty(xdg_state):
        return Path(xdg_state) / "ai-commander"
    return Path.home() / ".local" / "state" / "ai-commander"


def save_transcript(transcript: list[dict[str, str]]) -> Path:
    target_dir = chat_state_dir() / "transcripts"
    target_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    target = target_dir / f"chat-{timestamp}.md"
    suffix = 1
    while target.exists():
        target = target_dir / f"chat-{timestamp}-{suffix}.md"
        suffix += 1
    body = transcript_text(transcript)
    target.write_text(body or "# AI Commander transcript\n\nNo messages yet.\n", encoding="utf-8")
    return target


def copy_transcript_osc52(transcript: list[dict[str, str]]) -> bool:
    if not hasattr(sys.stdout, "isatty") or not sys.stdout.isatty():
        return False
    body = transcript_text(transcript)
    if not body:
        return False
    encoded = base64.b64encode(body.encode("utf-8")).decode("ascii")
    sys.stdout.write(f"\x1b]52;c;{encoded}\a\n")
    sys.stdout.flush()
    return True


def provider_status(config: dict[str, Any]) -> str:
    provider = str(config.get("provider") or DEFAULT_CONFIG["provider"])
    configured_auth = str((config.get("auth_type") or {}).get(provider) or "api_key")
    endpoint = str((config.get("api_url") or {}).get(provider) or "")
    auth = configured_auth
    try:
        credential = resolve_auth(config, provider)
        auth = str(credential.get("type") or configured_auth)
        endpoint = resolve_endpoint(config, provider, credential)
    except BackendError:
        subscription_url = (config.get("subscription_api_url") or {}).get(provider)
        if configured_auth in ("oauth", "subscription", "codex") and subscription_url:
            endpoint = str(subscription_url)
    endpoint_part = f", endpoint {endpoint}" if endpoint else ""
    return f"Provider: {provider}{endpoint_part}, auth {auth}"


def handle_chat_command(
    command: str,
    config: dict[str, Any],
    context: str,
    history: list[dict[str, str]],
    transcript: list[dict[str, str]],
) -> tuple[bool, list[dict[str, str]], list[dict[str, str]]]:
    name = command.strip().split(maxsplit=1)[0]
    if name == "/clear":
        history = []
        transcript = []
        save_history(config, history)
        print("Chat history cleared.", flush=True)
        return True, history, transcript
    if name == "/context":
        summary, preview = context_summary(context)
        print(f"Context: {summary}", flush=True)
        if preview:
            print(f"Preview: {preview}", flush=True)
        return True, history, transcript
    if name == "/model":
        provider = str(config.get("provider") or DEFAULT_CONFIG["provider"])
        print(f"Model: {model_for(config, provider)}", flush=True)
        return True, history, transcript
    if name == "/provider":
        print(provider_status(config), flush=True)
        return True, history, transcript
    if name == "/save":
        path = save_transcript(transcript)
        print(f"Transcript saved: {path}", flush=True)
        return True, history, transcript
    if name == "/load":
        history, transcript = handle_load_command(command, config, history, transcript)
        return True, history, transcript
    if name == "/copy":
        if copy_transcript_osc52(transcript):
            print("Transcript copied with OSC 52.", flush=True)
        else:
            print("Transcript copy unsupported in this terminal/session; use /save instead.", flush=True)
        return True, history, transcript
    return False, history, transcript


def print_chat_header(config: dict[str, Any], renderer: str, context: str, history_count: int) -> None:
    provider = str(config.get("provider") or DEFAULT_CONFIG["provider"])
    model = model_for(config, provider)
    context_status, _preview = context_summary(context)
    palette = theme_palette(config.get("theme"))
    memory_status = f"{history_count} history messages"
    if ansi_enabled() and rich_available():
        from rich import box
        from rich.console import Console
        from rich.panel import Panel
        from rich.table import Table
        from rich.text import Text

        grid = Table.grid(expand=True)
        grid.add_column(ratio=1)
        grid.add_column(ratio=1)
        grid.add_row(
            f"[bold {palette['accent2']}]provider[/] [{palette['foreground']}]{shell_quote_label(provider)}[/]",
            f"[bold {palette['accent']}]model[/] [{palette['foreground']}]{shell_quote_label(model)}[/]",
        )
        grid.add_row(
            f"[bold {palette['success']}]renderer[/] [{palette['foreground']}]{shell_quote_label(renderer)}[/]",
            f"[bold {palette['warning']}]context[/] [{palette['foreground']}]{shell_quote_label(context_status)}[/]",
        )
        grid.add_row(
            f"[dim {palette['muted']}]exit[/] [{palette['foreground']}]/q[/] [dim {palette['muted']}]or[/] [{palette['foreground']}]:q[/]",
            f"[dim {palette['muted']}]memory[/] [{palette['foreground']}]{shell_quote_label(memory_status)}[/]",
        )
        Console(force_terminal=True, color_system="truecolor", width=terminal_width()).print(
            Panel(
                grid,
                title=Text(" AI Commander ", style=f"bold {palette['accent2']}"),
                subtitle=Text(" Ctrl+Shift+A chat ", style=palette["muted"]),
                border_style=palette["accent2"],
                box=box.ROUNDED,
                padding=(0, 1),
            )
        )
        return

    if not ansi_enabled():
        print("AI Commander chat pane. Type /q, :q, quit, or exit to close.", flush=True)
        print(f"Provider: {provider}", flush=True)
        print(f"Model: {model}", flush=True)
        print(f"Renderer: {renderer}", flush=True)
        print(f"Context: {context_status}", flush=True)
        print(f"History: {history_count} messages", flush=True)
        return

    width = max(52, min(terminal_width(), 96))
    title = " AI Commander "
    top = "╭" + title + "─" * max(0, width - len(title) - 2) + "╮"
    bottom = "╰" + "─" * (width - 2) + "╯"
    lines = [
        f"Provider: {provider}  Model: {model}",
        f"Renderer: {renderer}  Context: {context_status}",
        f"History: {history_count} messages",
        "Exit: /q, :q, q, quit, exit",
    ]
    print(hex_ansi(top, palette["accent2"], bold=True))
    for line in lines:
        clipped = line[: width - 6]
        padding = " " * max(0, width - len(clipped) - 4)
        print(hex_ansi("│", palette["accent2"]) + " " + clipped + padding + " " + hex_ansi("│", palette["accent2"]))
    print(hex_ansi(bottom, palette["accent2"]), flush=True)


def prompt_hostname() -> str:
    hostname = os.getenv("WEZTERM_AI_COMMANDER_PROMPT_HOST") or socket.gethostname()
    hostname = hostname.split(".", 1)[0].strip()
    return hostname or "local"


def print_prompt(theme: Any = None) -> None:
    host = prompt_hostname()
    palette = theme_palette(theme)
    if ansi_enabled():
        print(hex_ansi("╭─┤", palette["accent"], bold=True) + " " + hex_ansi(host, palette["accent"], bold=True))
        print(hex_ansi("╰─❯", palette["accent"], bold=True) + " ", end="", flush=True)
        return
    print(f"{host}> ", end="", flush=True)


def print_assistant_start(theme: Any = None) -> None:
    palette = theme_palette(theme)
    if ansi_enabled():
        print(hex_ansi("╭─", palette["accent2"], bold=True) + hex_ansi(" AI", palette["accent2"], bold=True), flush=True)
        return
    print("AI:", flush=True)


def run_chat(args: argparse.Namespace) -> int:
    config = load_config(args.config)
    context = read_text(args.context)
    if getattr(args, "delete_input_files", False):
        for path in (args.config, args.context):
            try:
                Path(path).unlink()
            except OSError:
                pass
    system = str(
        config.get("chat_system_prompt") or DEFAULT_CONFIG["chat_system_prompt"]
    )
    history = trim_history(
        load_history(config), config.get("max_conversation_messages")
    )
    renderer = str(config.get("renderer") or "raw markdown")
    theme = config.get("theme")
    transcript: list[dict[str, str]] = []
    print_chat_header(config, renderer, context, len(history))
    print_prompt(theme)
    for line in sys.stdin:
        prompt = line.rstrip("\n")
        if not prompt:
            print_prompt(theme)
            continue
        stripped = prompt.strip()
        if stripped in ("/q", ":q", "q", "quit", "exit"):
            break
        if stripped.startswith("/") and stripped != "/":
            handled, history, transcript = handle_chat_command(
                stripped, config, context, history, transcript
            )
            if handled:
                print_prompt(theme)
                continue
        user_content = contextual_prompt(prompt, context)
        messages = history + [{"role": "user", "content": user_content}]
        writer = DeltaWriter(config.get("renderer"), theme)
        if not writer.rich:
            print_assistant_start(theme)
        assistant_parts: list[str] = []
        request_ok = False
        request_cancelled = False
        try:
            provider, response, _streamed = post(
                config,
                system,
                messages,
                stream=True,
                max_tokens=int(
                    config.get("chat_max_tokens") or config.get("max_tokens") or 4000
                ),
            )
            for delta in iter_stream_deltas(response, provider):
                assistant_parts.append(delta)
                writer.write(delta)
            request_ok = True
        except KeyboardInterrupt:
            request_cancelled = True
            print("\n# AI response cancelled\nChat remains open.", flush=True)
        except BackendError as exc:
            print(f"\n# AI request failed\n{exc}", flush=True)
        finally:
            writer.close()
        assistant_text = "".join(assistant_parts)
        if not writer.rich:
            print("", flush=True)
        if request_ok:
            history.extend(
                [
                    {"role": "user", "content": user_content},
                    {"role": "assistant", "content": assistant_text},
                ]
            )
            transcript.extend(
                [
                    {"role": "user", "content": prompt},
                    {"role": "assistant", "content": assistant_text},
                ]
            )
            history = trim_history(history, config.get("max_conversation_messages"))
            save_history(config, history)
        elif request_cancelled:
            assistant_parts.clear()
        print_prompt(theme)
    return 0


def command_available(command: str) -> bool:
    if not command or command == "cat":
        return True
    try:
        argv = shlex.split(command)
    except ValueError:
        return False
    if not argv:
        return True
    if argv[0] == "rich":
        return rich_available()
    from shutil import which

    return which(argv[0]) is not None


def package_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return "not installed"


def default_venv_path() -> Path:
    return Path.home() / ".local" / "share" / "ai-commander.wezterm" / "venv"


def venv_python_path(venv_path: Path) -> Path:
    return venv_path / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def backend_root() -> Path:
    return Path(__file__).resolve().parents[1]


def default_requirements_path() -> Path:
    return backend_root() / "requirements.txt"


def dependency_summary() -> dict[str, str]:
    return {
        "python": sys.version.split()[0],
        "requests": package_version("requests"),
        "rich": package_version("rich"),
    }


def renderer_summary(renderer: Any) -> str:
    value = str(renderer or "cat").strip()
    if not value or value == "cat":
        return "cat/raw markdown"
    if value == "rich":
        return f"rich ({'available' if rich_available() else 'not installed'})"
    try:
        argv = shlex.split(value)
    except ValueError:
        return f"{value} (not parseable)"
    if not argv:
        return "cat/raw markdown"
    resolved = resolve_renderer_argv(argv)
    return f"{value} ({resolved[0] if resolved else 'not found'})"


def validate_config(config: dict[str, Any]) -> list[str]:
    warnings: list[str] = []
    provider = config.get("provider") or "anthropic"
    if provider not in ("anthropic", "openai"):
        warnings.append(
            f"Unsupported provider {provider!r}; expected anthropic or openai."
        )
    if not (config.get("api_url") or {}).get(provider):
        warnings.append(f"api_url.{provider} is not configured.")
    if not (config.get("model") or {}).get(provider):
        warnings.append(f"model.{provider} is not configured.")
    auth_type = (config.get("auth_type") or {}).get(provider) or "api_key"
    if auth_type not in ("api_key", "oauth", "subscription", "auto", "codex"):
        warnings.append(
            f"auth_type.{provider} is {auth_type!r}; expected api_key, oauth, subscription, auto, or codex."
        )
    return warnings


def run_check(args: argparse.Namespace) -> int:
    ok = True
    config: dict[str, Any] = DEFAULT_CONFIG
    provider = DEFAULT_CONFIG["provider"]
    try:
        config = load_config(args.config)
        provider = provider_name(config)
        model = model_for(config, provider)
        auth_mode = (config.get("auth_type") or {}).get(provider) or "api_key"
        print(f"INFO provider: {provider}")
        print(f"INFO model: {model or '(unset)'}")
        print(f"INFO tokens: max={config.get('max_tokens')} chat={config.get('chat_max_tokens')}")
        print(f"INFO configured auth mode: {auth_mode}")
        for warning in validate_config(config):
            print(f"WARN config: {warning}")
        credential = resolve_auth(config, provider)
        endpoint = resolve_endpoint(config, provider, credential)
        source = credential.get("source") or "unknown source"
        print(f"OK auth: {credential['type']} credentials resolved ({source})")
        print(f"INFO endpoint: {endpoint}")
    except BackendError as exc:
        ok = False
        print(f"FAIL auth: {exc}")
    versions = dependency_summary()
    print(f"INFO python: {versions['python']} ({sys.executable})")
    print(f"INFO venv: prefix={sys.prefix} base={getattr(sys, 'base_prefix', sys.prefix)}")
    print(f"INFO expected venv: {default_venv_path()}")
    print(f"INFO backend: {Path(__file__).resolve()}")
    if requests is None:
        ok = False
        print("FAIL dependency: requests not installed")
    else:
        print(f"OK dependency: requests {versions['requests']}")
    if versions["rich"] == "not installed":
        print("WARN dependency: rich not installed")
    else:
        print(f"OK dependency: rich {versions['rich']}")
    print(f"INFO renderer: {renderer_summary(config.get('renderer'))}")
    renderer = str(config.get("renderer") or "")
    if renderer == "rich" and not rich_available():
        ok = False
        print("FAIL renderer: rich package is not installed")
    elif renderer and renderer not in ("cat", "rich", "streamdown") and not command_available(renderer):
        print(f"WARN renderer: not found: {renderer}; raw markdown fallback will be used")
    if debug_enabled():
        print(f"INFO debug_dir: {debug_location()}")
    return 0 if ok else 1



def run_setup(args: argparse.Namespace) -> int:
    venv_path = Path(expand_path(args.venv) or args.venv)
    requirements = Path(expand_path(args.requirements) or args.requirements)
    python_path = venv_python_path(venv_path)
    print(f"INFO venv: {venv_path}")
    if args.recreate or not python_path.exists():
        print("INFO setup: creating virtualenv")
        venv.EnvBuilder(with_pip=True, clear=bool(args.recreate)).create(venv_path)
    else:
        print("OK setup: virtualenv already exists")
    if not python_path.exists():
        raise BackendError(f"Python was not created at {python_path}")
    print(f"OK setup: interpreter {python_path}")
    if args.no_install:
        print("INFO setup: dependency install skipped by --no-install")
        return 0
    if not requirements.exists():
        raise BackendError(f"Requirements file not found: {requirements}")
    command = [str(python_path), "-m", "pip", "install", "-r", str(requirements)]
    print(f"INFO setup: installing dependencies from {requirements}")
    completed = subprocess.run(command, text=True)
    if completed.returncode != 0:
        raise BackendError(f"pip install failed with exit code {completed.returncode}")
    print("OK setup: dependencies installed")
    return 0


def run_doctor(args: argparse.Namespace) -> int:
    venv_path = Path(expand_path(args.venv) or args.venv)
    python_path = venv_python_path(venv_path)
    print(f"INFO expected venv: {venv_path}")
    if python_path.exists():
        print(f"OK expected interpreter: {python_path}")
    else:
        print(f"FAIL expected interpreter missing: {python_path}")
        return 1
    return run_check(args)

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="ai-commander Python backend")
    sub = parser.add_subparsers(dest="mode", required=True)
    generate = sub.add_parser("generate")
    generate.add_argument("--config", required=True)
    generate.add_argument("--system", required=True)
    generate.add_argument("--prompt", required=True)
    generate.set_defaults(func=run_generate)
    chat = sub.add_parser("chat")
    chat.add_argument("--config", required=True)
    chat.add_argument("--context", required=True)
    chat.add_argument("--delete-input-files", action="store_true")
    chat.set_defaults(func=run_chat)
    check = sub.add_parser("check")
    check.add_argument("--config", required=True)
    check.set_defaults(func=run_check)
    setup = sub.add_parser("setup")
    setup.add_argument("--venv", default=str(default_venv_path()))
    setup.add_argument("--requirements", default=str(default_requirements_path()))
    setup.add_argument("--no-install", action="store_true")
    setup.add_argument("--recreate", action="store_true")
    setup.set_defaults(func=run_setup)
    doctor = sub.add_parser("doctor")
    doctor.add_argument("--config", required=True)
    doctor.add_argument("--venv", default=str(default_venv_path()))
    doctor.set_defaults(func=run_doctor)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        write_backend_metadata(getattr(args, "mode", "unknown"), args)
        return args.func(args)
    except BackendError as exc:
        suffix = f"\nDebug files: {debug_location()}" if debug_enabled() else ""
        print(str(exc) + suffix, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
