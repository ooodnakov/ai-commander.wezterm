# AI Commander for WezTerm

A WezTerm plugin that generates terminal commands from natural language using AI providers (Anthropic Claude or OpenAI GPT).

![Example Usage](./example.gif)

## Features

- **Command Generation** — describe what you want in plain English, get ready-to-run commands
- **Multiple Options** — generates several command variants to choose from (default: 5)
- **Context-Aware** — select text in the terminal (error messages, file paths, logs) and use it as context
- **Results Recall** — browse and reuse previously generated commands without re-querying the API
- **Prompt History** — access and re-run previous prompts from a persistent history file
- **Syntax Highlighting** — commands are highlighted via `bat` (if installed) in the selection menu

## Prerequisites

- **WezTerm** — recent version with Lua plugin support
- **API Key** from [Anthropic](https://console.anthropic.com/) or [OpenAI](https://platform.openai.com/)
- **bat** (optional) — for syntax highlighting in the command selector

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
  { key = 'H', mods = 'ALT|SHIFT',  action = wezterm.action_callback(function(w, p) ai.show_history(w, p) end) },
}

return config
```

## Usage

| Function              | Suggested Keybinding | Description                                    |
|-----------------------|----------------------|------------------------------------------------|
| `show_prompt(w, p)`       | `Alt+Shift+X`       | Open prompt input, generate commands from text |
| `show_last_results(w, p)` | `Ctrl+Shift+X`      | Recall previously generated commands           |
| `show_history(w, p)`      | `Alt+Shift+H`       | Browse and re-run previous prompts             |

### Basic Workflow

1. Press `Alt+Shift+X` → type what you need (e.g. *"find all PDF files modified today"*)
2. AI generates several command options
3. Pick one from the interactive selector (press `/` to filter)
4. The command is inserted into your terminal

### Context-Aware Generation

1. **Select text** in the terminal (error message, file listing, log snippet, etc.)
2. Press `Alt+Shift+X` → the selected text is sent as context alongside your prompt
3. AI generates commands that take the context into account

### Recalling Results

Press `Ctrl+Shift+X` to browse commands from previous prompts grouped by query. Useful when you generated several options and want to try another one without re-querying.

### Prompt History

Press `Alt+Shift+H` to pick a previous prompt and re-run it. History is persisted to a file across WezTerm restarts.

## Configuration

All options with their defaults:

```lua
ai.apply_to_config(config, {
  -- Provider: "anthropic" or "openai"
  provider = "anthropic",

  -- API keys (only the active provider's key is required)
  api_key = {
    anthropic = nil,
    openai = nil,
  },

  -- API endpoints (override for proxies or compatible APIs)
  api_url = {
    anthropic = "https://api.anthropic.com/v1/messages",
    openai = "https://api.openai.com/v1/chat/completions",
  },

  -- Models
  model = {
    anthropic = "claude-haiku-4-5",
    openai = "gpt-4o",
  },

  -- Generation parameters
  max_tokens = 4000,
  temperature = 0.1,
  command_count = 5,            -- number of command variants to generate

  -- System prompt (defines AI persona and behavior)
  system_prompt = "...",        -- see plugin/config.lua for the full default

  -- Results recall
  max_results_history = 5,      -- how many result sets to keep in memory

  -- Prompt history (persisted to disk)
  history_file = wezterm.home_dir .. "/.wezterm_ai_prompt_history.txt",
  max_history = 100,
})
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| *"API key not configured"* | Set `api_key.anthropic` or `api_key.openai` matching your `provider` |
| *"Failed to connect to API"* | Check internet, API key validity, firewall rules |
| Keybindings not working | Ensure `config.keys` entries are present; check for conflicts |
| No commands generated | Rephrase the prompt to be more specific |
| No syntax highlighting | Install [bat](https://github.com/sharkdp/bat) |

## Security

- API keys are stored in your WezTerm config and sent to the provider's API
- Prompts and selected context are sent to the AI provider for processing
- Generated commands are **never executed automatically** — you always choose
- Do not commit API keys to version control

## License

[MIT](LICENSE)
