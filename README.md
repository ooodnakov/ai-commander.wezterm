# AI Commander for WezTerm

A WezTerm plugin that generates terminal commands and answers questions using AI providers (Anthropic Claude, OpenAI GPT, or custom).

![Example Usage](./example.gif)

![Ask Mode Example](./ask-mode-example.gif)

## Why

When you need a command you don't remember or hit an error you need to troubleshoot, the typical flow is: open ChatGPT/Claude in a browser, paste the context, wait for the answer, copy the command back. Or launch a CLI agent like Claude Code, which takes over your terminal session -- overkill when you just need a quick one-liner or want to ask "what does this error mean?"

AI Commander stays out of your way. Press a hotkey, type your question, get the answer -- all without leaving the terminal or interrupting your workflow:

- **Quick command generation** — describe what you need, pick from ready-to-run variants, it's pasted into your shell. 
- **Context-aware troubleshooting** — select an error message or log snippet in the terminal, press the hotkey, and get a fix specific to what just happened.
- **Streaming ask** — ask any question and get a formatted, streamed response in a split pane. 

## Features

- **Command Generation** — describe what you want in plain English, get ready-to-run commands
- **Streaming Ask** — ask AI questions and get streamed, markdown-rendered responses in a split pane
- **Multiple Options** — generates several command variants to choose from (default: 5)
- **Context-Aware** — select text in the terminal (error messages, file paths, logs) and use it as context
- **Results Recall** — browse and reuse previously generated commands without re-querying the API
- **Prompt History** — access previous prompts, edit them, then submit explicitly
- **Safe Insert Guard** — destructive commands require confirmation before being pasted
- **Syntax Highlighting** — commands are highlighted via `bat` (if installed) in the selection menu
- **Pluggable Providers** — Anthropic Messages and OpenAI Responses built in; provider support lives in the Python backend plus Lua diagnostics
- **Subscription OAuth** — can reuse Claude Code and Codex CLI login credentials instead of manual API keys
- **Provider Health Check** — validate credentials, Python backend, renderer availability, and config warnings
- **Conversation Continuity** — split-pane chat keeps message context; optionally persist it across panes

## Prerequisites

- **WezTerm** — recent version with Lua plugin support
- **Python 3 backend venv** — provider calls and Rich markdown rendering:
  ```sh
  python -m venv ~/.local/share/ai-commander.wezterm/venv
  ~/.local/share/ai-commander.wezterm/venv/bin/python -m pip install -r requirements.txt
  ```
- **API key** from [Anthropic](https://console.anthropic.com/) or [OpenAI](https://platform.openai.com/), or local OAuth/subscription credentials from Claude Code/Codex CLI
- **bat** (optional) — for syntax highlighting in the command selector

`backend_python = nil` auto-detects this venv before falling back to `python`/`python3`. You can also set `WEZTERM_AI_COMMANDER_BACKEND_PYTHON` or `backend_python` explicitly.

## Installation

Add to your `.wezterm.lua`:

```lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Load AI Commander plugin
local ai = wezterm.plugin.require("https://github.com/dimao/ai-commander.wezterm")

-- Apply configuration
ai.apply_to_config(config, {
  provider = "anthropic",  -- or "openai"
  api_key = {
    anthropic = "your-anthropic-api-key",
    openai = "your-openai-api-key",
  },
})

-- Keybindings
config.keys = {
  { key = 'X', mods = 'ALT|SHIFT',  action = wezterm.action_callback(function(w, p) ai.show_prompt(w, p) end) },
  { key = 'X', mods = 'CTRL|SHIFT', action = wezterm.action_callback(function(w, p) ai.show_last_results(w, p) end) },
  { key = 'R', mods = 'ALT|SHIFT',  action = wezterm.action_callback(function(w, p) ai.repeat_last_prompt(w, p) end) },
  { key = 'H', mods = 'ALT|SHIFT',  action = wezterm.action_callback(function(w, p) ai.show_history(w, p) end) },
  { key = 'A', mods = 'CTRL|SHIFT', action = wezterm.action_callback(function(w, p) ai.show_ask_inline(w, p) end) },
  { key = 'E', mods = 'CTRL|SHIFT', action = wezterm.action_callback(function(w, p) ai.complete_current_command(w, p) end) },
  { key = 'P', mods = 'CTRL|SHIFT', action = wezterm.action_callback(function(w, p) ai.check_provider(w, p) end) },
}

return config
```

## Usage

| Function              | Suggested Keybinding | Description                                    |
|-----------------------|----------------------|------------------------------------------------|
| `show_prompt(w, p)`       | `Alt+Shift+X`       | Open prompt input, generate commands from text |
| `show_last_results(w, p)` | `Ctrl+Shift+X`      | Recall previously generated commands           |
| `repeat_last_prompt(w, p)` | `Alt+Shift+R`      | Re-run the most recent prompt with current context |
| `show_history(w, p)`      | `Alt+Shift+H`       | Browse previous prompts and edit before submit |
| `show_ask_inline(w, p)`   | `Ctrl+Shift+A`      | Ask AI a question, stream response in split pane |
| `complete_current_command(w, p)` | `Ctrl+Shift+E` | Complete the currently typed shell command |
| `check_provider(w, p)`     | `Ctrl+Shift+P`      | Validate credentials, endpoint, dependencies, and config |

### Command Generation

1. Press `Alt+Shift+X` → type what you need (e.g. *"find all PDF files modified today"*)
2. AI Commander sends selected text plus shell context (cwd, foreground process, current line, git branch when available) alongside your prompt
3. Pick one of the styled command options, or choose regenerate/refine from the selector
4. Safe commands are inserted into your terminal; destructive commands show a confirmation selector first

### Command Completion

1. Type the beginning of a shell command in your pane, e.g. `git che`
2. Press `Ctrl+Shift+E`
3. AI Commander appends only the missing suffix at the cursor

### Streaming Ask

1. Press `Ctrl+Shift+A` to open an interactive bottom split
2. Type questions at the `Ask AI>` prompt; responses render incrementally with Python Rich markdown
3. Follow-up questions in the same chat pane include prior turns as context
4. Use slash commands inside the pane:
   - `/clear` clears in-pane history and the persisted conversation file when continuity is enabled
   - `/context` prints selected-context size and preview
   - `/model` prints the active provider model
   - `/provider` prints provider, endpoint, and auth type without token values
   - `/save` writes the current pane transcript to `~/.local/state/ai-commander/transcripts/` or `$XDG_STATE_HOME/ai-commander/transcripts/`
   - `/copy` copies the transcript with OSC 52 when the terminal supports it; otherwise it prints an unsupported message and keeps the pane open
5. Press `Ctrl+C` while a response streams to cancel that response only; the chat pane stays open
6. Type `/q`, `:q`, `q`, `quit`, or `exit` to close the chat pane

Rich uses `rich.live.Live(Panel(Markdown(buffer)), refresh_per_second=12, screen=false)` to update a bordered AI response panel in place while tokens arrive, avoiding Glow-style scrollback rewrite hacks. Set `renderer = "streamdown"` for an external streaming renderer, or `renderer = "cat"` for plain text.

### Context-Aware Generation

1. **Select text** in the terminal (error message, file listing, log snippet, etc.)
2. Press `Alt+Shift+X` (or `Ctrl+Shift+A`) → the selected text is sent as context alongside your prompt
3. AI generates commands/answers that take the context into account

### Recalling Results

Press `Ctrl+Shift+X` to browse commands from previous prompts grouped by query. Useful when you generated several options and want to try another one without re-querying.

### Prompt History

Press `Alt+Shift+H` to pick a previous prompt, edit it, and submit explicitly. Press `Alt+Shift+R` to repeat the most recent prompt immediately with the current selected context. History is persisted to a file across WezTerm restarts.

## Configuration

All options with their defaults:

```lua
ai.apply_to_config(config, {
  -- Provider: "anthropic" or "openai"
  provider = "anthropic",

  -- Authentication per provider: "api_key" (default), "oauth"/"subscription", or "auto"
  auth_type = {
    anthropic = "api_key",
    openai = "api_key",
  },

  -- API keys (only the active provider's key is required in api_key mode)
  api_key = {
    anthropic = nil,
    openai = nil,
  },

  -- API endpoints (override for proxies or compatible APIs)
  api_url = {
    anthropic = "https://api.anthropic.com/v1/messages",
    openai = "https://api.openai.com/v1/responses",
  },

  -- OAuth/subscription endpoints used in oauth/subscription mode
  subscription_api_url = {
    anthropic = "https://api.anthropic.com/v1/messages",
    openai = "https://chatgpt.com/backend-api/codex/responses",
  },

  -- Optional OAuth token overrides; defaults read common CLI credential files
  oauth = {
    anthropic = {
      access_token = nil,
      credentials_path = nil, -- $CLAUDE_CONFIG_DIR/.credentials.json or ~/.claude/.credentials.json
    },
    openai = {
      access_token = nil,
      account_id = nil,
      credentials_path = nil, -- $CODEX_HOME/auth.json or ~/.codex/auth.json
    },
  },

  -- Models
  model = {
    anthropic = "claude-haiku-4-5",
    openai = "gpt-5.5",
  },

  -- Generation parameters
  max_tokens = 4000,              -- max tokens for command generation
  chat_max_tokens = 16000,        -- max tokens for streaming ask
  temperature = 0.1,
  command_count = 5,              -- number of command variants to generate

  -- Python backend executable; nil auto-detects:
  -- $WEZTERM_AI_COMMANDER_BACKEND_PYTHON,
  -- ~/.local/share/ai-commander.wezterm/venv/bin/python,
  -- then python/python3.
  backend_python = nil,

  -- Streaming ask renderer ('rich', 'streamdown', 'cat', or command path)
  renderer = "rich",
  chat_pane_size = 0.8,           -- split pane size (0.0-1.0)

  -- Conversation continuity for ask mode
  conversation_continuity = false, -- true to persist chat context across split panes
  conversation_state_file = wezterm.home_dir .. "/.wezterm_ai_conversation_state.json",
  max_conversation_messages = 12,  -- in-pane and persisted history window

  -- System prompts (see plugin/config.lua for full defaults)
  system_prompt = "...",          -- persona for command generation
  chat_system_prompt = "...",     -- persona for streaming ask

  -- Results recall
  max_results_history = 5,        -- how many result sets to keep in memory

  -- Prompt history (persisted to disk)
  history_file = wezterm.home_dir .. "/.wezterm_ai_prompt_history.txt",
  max_history = 100,
})
```


### OAuth / Subscription Credentials

AI Commander can use existing CLI subscription logins when you choose OAuth mode:

```lua
ai.apply_to_config(config, {
  provider = "anthropic",
  auth_type = { anthropic = "oauth" },
})
```

For Claude, OAuth mode checks `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_AUTH_TOKEN`, then `$CLAUDE_CONFIG_DIR/.credentials.json` or `~/.claude/.credentials.json`. Claude Code can create a long-lived subscription token with `claude setup-token`.

```lua
ai.apply_to_config(config, {
  provider = "openai",
  auth_type = { openai = "oauth" },
})
```

For Codex/OpenAI, OAuth mode checks `CODEX_AUTH_TOKEN`, `OPENAI_AUTH_TOKEN`, `CHATGPT_AUTH_TOKEN`, then `$CODEX_HOME/auth.json` or `~/.codex/auth.json`. In OAuth mode the default OpenAI endpoint switches to the Codex subscription Responses endpoint. If you want regular OpenAI API billing, leave `auth_type.openai = "api_key"`.

### OpenAI API Shape

OpenAI uses the Responses API (`https://api.openai.com/v1/responses`) for both blocking command generation and streaming ask mode. The OpenAI provider sends the system prompt as `instructions`, user text as `input`, output limits as `max_output_tokens`, requests low reasoning effort for GPT-5/o-series models such as `gpt-5.5`, and parses `response.output_text.delta` events while streaming.


### Provider Health Check

Run `ai.check_provider(w, p)` from a keybinding to print diagnostics into the current pane. It checks:

- active provider and config validation warnings
- credential resolution for the selected auth mode
- Python backend, `requests`, and Rich availability
- renderer availability when configured; raw markdown fallback otherwise

The helper returns the same report table it prints, so advanced configs can call it programmatically.

### Conversation Continuity

`Ctrl+Shift+A` always keeps message context inside the opened chat pane, so follow-up questions can refer to prior answers. Set `conversation_continuity = true` only when you also want that chat context persisted across newly opened ask panes:

```lua
ai.apply_to_config(config, {
  conversation_continuity = true,
  conversation_state_file = wezterm.home_dir .. "/.wezterm_ai_conversation_state.json",
})
```

The plugin stores a compact local message history for both OpenAI and Anthropic ask mode. This avoids unsupported subscription parameters such as `previous_response_id` and keeps the same behavior across providers. Full chat transcripts stay in memory unless you call `/save`.

### Config Validation

`ai.apply_to_config` logs warnings with `wezterm.log_warn` when the active provider has suspicious settings, such as a missing model, a non-Responses OpenAI endpoint, invalid auth mode, ignored API keys in OAuth mode, invalid token limits, or missing conversation state path. `ai.check_provider(w, p)` includes the same warnings in its report.

## Adding a New Provider

Provider requests are executed by `plugin/backend.py`. Lua provider modules under `plugin/providers/` are still used for config/auth diagnostics, but a new provider also needs backend support.

To add a provider:

1. Add default `api_url`, `subscription_api_url` if needed, and `model` entries in `plugin/config.lua`.
2. Add auth lookup rules in `plugin/auth.lua` and matching credential resolution in `plugin/backend.py`.
3. Register Lua diagnostic metadata in `plugin/provider.lua` / `plugin/providers/<name>.lua`.
4. Implement request-body construction, response extraction, and SSE delta parsing in `plugin/backend.py`.

The backend deliberately avoids shell pipelines; new providers should use Python `requests`, `json`, and in-process SSE parsing rather than `curl`, `jq`, `grep`, or `sed`.


## Suggested Improvements

These are good follow-up improvements for the plugin once OAuth and Responses support are stable:

- **Credential refresh** — refresh expired Claude/Codex OAuth tokens automatically when the local CLI credential file includes refresh metadata.
- **Structured command responses** — ask providers for JSON command/description output instead of parsing free-form `##` description lines.
- **Conversation reset UI** — add a helper to clear or switch ask-mode conversation state without deleting the state file manually.

## Updating the Plugin

WezTerm [caches plugins locally](https://wezterm.org/config/plugins.html). After the plugin is updated upstream, you need to pull the new version:

**Option 1** — from the WezTerm Debug Overlay (`Ctrl+Shift+L`):

```lua
wezterm.plugin.update_all()
wezterm.reload_configuration()
```

**Option 2** — delete the cached copy and restart WezTerm:

```bash
# macOS
rm -rf ~/Library/Application\ Support/wezterm/plugins/*ai-commander*

# Linux
rm -rf ~/.local/share/wezterm/plugins/*ai-commander*
```

WezTerm will re-fetch the plugin from the repository on next start.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| *"credentials not configured"* | Set `api_key.<provider>` for API-key mode or `auth_type.<provider> = "oauth"` with Claude Code/Codex credentials |
| *"Unsupported provider"* | Check that a matching file exists in `plugin/providers/` |
| *"Failed to connect to API"* | Check internet, API key validity, firewall rules |
| Keybindings not working | Ensure `config.keys` entries are present; check for conflicts |
| Keybindings not working on macOS | Plain `CTRL+<key>` can conflict with terminal control characters or IME; use `CTRL+SHIFT` combos instead |
| Plugin not updating | Clear the plugin cache (see [Updating the Plugin](#updating-the-plugin)) |
| No commands generated | Rephrase the prompt to be more specific |
| OpenAI says response is incomplete with no assistant text | Increase `max_tokens`/`chat_max_tokens`; GPT-5 reasoning tokens count against `max_output_tokens` |
| No syntax highlighting | Install [bat](https://github.com/sharkdp/bat) |
| Streaming ask shows raw text | Install backend dependencies in the venv, or set `renderer = "cat"` intentionally |
| Renderer command not found | Ensure the external renderer is in your PATH, or set `renderer` to the full path |

## Security

- API keys are stored in your WezTerm config and sent to the provider's API
- Prompts and selected context are sent to the AI provider for processing
- Generated commands are **never executed automatically** — you always choose
- Do not commit API keys to version control

## License

[MIT](LICENSE)
