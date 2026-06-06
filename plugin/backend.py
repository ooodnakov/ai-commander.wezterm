#!/usr/bin/env python3
"""Linux Python backend for ai-commander.wezterm."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

import requests


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


def parse_sse_lines(lines: Iterable[bytes], provider: str) -> Iterable[str]:
    for raw in lines:
        line = raw.decode("utf-8", errors="replace").strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            event = json.loads(payload)
        except json.JSONDecodeError:
            continue
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


def iter_stream_deltas(response: requests.Response, provider: str) -> Iterable[str]:
    return parse_sse_lines(response.iter_lines(chunk_size=1), provider)


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

    def write(self, text: str) -> None:
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
def post(
    config: dict[str, Any],
    system: str,
    messages: list[dict[str, Any]],
    *,
    stream: bool,
    max_tokens: int,
):
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
    try:
        response = requests.post(
            api_url,
            headers=headers_for(provider, credential),
            json=body,
            stream=request_stream,
            timeout=(10, 120),
        )
        response.raise_for_status()
        return provider, response, request_stream
    except requests.RequestException as exc:
        raise BackendError(f"HTTP request failed: {exc}") from exc


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
        raise BackendError(
            f"Failed to parse API response: {response.text[:1500]}"
        ) from exc
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
    if not config.get("conversation_continuity"):
        return []
    path = config.get("conversation_state_file")
    state = read_optional_json(path)
    if isinstance(state, list):
        return [
            item
            for item in state
            if isinstance(item, dict) and item.get("role") in ("user", "assistant")
        ]
    if isinstance(state, dict) and isinstance(state.get("messages"), list):
        return [
            item
            for item in state["messages"]
            if isinstance(item, dict) and item.get("role") in ("user", "assistant")
        ]
    return []


def save_history(config: dict[str, Any], history: list[dict[str, str]]) -> None:
    if not config.get("conversation_continuity"):
        return
    path = expand_path(config.get("conversation_state_file"))
    if not path:
        return
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
    try:
        config = load_config(args.config)
        provider = config.get("provider") or "anthropic"
        print(f"INFO provider: {provider}")
        for warning in validate_config(config):
            print(f"WARN config: {warning}")
        credential = resolve_auth(config, provider)
        endpoint = resolve_endpoint(config, provider, credential)
        print(f"OK auth: credentials resolved with {credential['type']} auth")
        print(f"INFO endpoint: {endpoint}")
    except BackendError as exc:
        ok = False
        print(f"FAIL auth: {exc}")
        config = DEFAULT_CONFIG
    print("OK backend: python requests backend available")
    renderer = str(config.get("renderer") or "")
    if not renderer or renderer == "cat":
        print("OK renderer: raw markdown")
    elif renderer == "rich":
        if rich_available():
            print("OK renderer: rich")
        else:
            ok = False
            print("FAIL renderer: rich package is not installed")
    elif renderer == "streamdown":
        if command_available(renderer):
            print("OK renderer: streamdown")
        else:
            print(
                "INFO renderer: optional renderer not found: streamdown; raw markdown fallback will be used"
            )
    elif command_available(renderer):
        print(f"OK renderer: {renderer}")
    else:
        print(
            f"WARN renderer: not found: {renderer}; raw markdown fallback will be used"
        )
    return 0 if ok else 1


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
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except BackendError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
