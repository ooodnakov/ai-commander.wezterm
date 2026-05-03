# AI Commander for WezTerm

Integrates with AI providers (Anthropic Claude and OpenAI GPT) to generate and select bash commands based on natural language prompts.

![Example Usage](./example.gif)

## Features

- **Command Generation**: Generate multiple bash command options from natural language descriptions
- **Interactive Selection**: Choose from generated commands using a styled selection menu with descriptions
- **Context-Aware Generation**: Select text in the terminal to provide context for command generation
- **Results Recall**: Recall previous AI-generated commands with `Ctrl+Shift+X` — no need to re-query
- **Prompt History**: Access and reuse previous prompts with `Alt+Shift+H`
- **Quick Command Generation**: Generate commands on-the-fly with `Alt+Shift+X`
- **Word Deletion**: Enhanced text editing with `Alt+Backspace` for word deletion

## Prerequisites

1. **API Key**: Get your API key from:
   - [Anthropic Console](https://console.anthropic.com/) for Claude
   - [OpenAI Platform](https://platform.openai.com/) for GPT
2. **WezTerm**: Recent version with Lua plugin support

## Installation

1. Add the plugin to your `.wezterm.lua` configuration:
   ```lua
   local wezterm = require 'wezterm'
   local config = wezterm.config_builder()

   -- Load AI Commander plugin
   local ai_plugin = wezterm.plugin.require("https://github.com/dimao/ai-commander.wezterm")

   -- Apply AI Commander configuration with your API key
   -- This also registers all default keybindings automatically
   ai_plugin.apply_to_config(config, {
     provider = "anthropic",  -- "anthropic" or "openai"
     api_key = {
       anthropic = "your-anthropic-api-key-here",  -- Replace with your actual API key
       openai = "your-openai-api-key-here"        -- Replace with your actual API key
     }
   })

   return config
   ```

## Usage

The plugin automatically registers the following keybindings via `apply_to_config`:

| Keybinding | Action |
|---|---|
| **Alt+Shift+X** | New AI prompt — generate commands from natural language |
| **Ctrl+Shift+X** | Recall last results — browse and select from previous AI results |
| **Alt+Shift+H** | Prompt history — reuse a previous prompt |
| **Alt+Backspace** | Word deletion (sends Ctrl+W) |

### Workflow

#### Basic Command Generation
1. Press `Alt+Shift+X` to open the command generation prompt
2. Enter a natural language description of what you want to do (e.g., "find all PDF files in current directory")
3. The AI will generate multiple bash command options (configurable, default: 5)
4. Select the command you want to use from the interactive menu
5. The selected command will be inserted into your terminal

#### Context-Aware Command Generation
1. **Select text** in your terminal (drag to highlight text like file paths, error messages, log entries, etc.)
2. Press `Alt+Shift+X` to open the command generation prompt
3. The prompt description will indicate that selected text will be used as context
4. Enter your command request (e.g., "fix this error" or "process these files")
5. The AI will generate commands that take the selected text into account
6. Select and execute the appropriate command

**Example Use Cases:**
- Select an error message and ask "how to fix this"
- Select file paths and ask "delete these files"
- Select log entries and ask "parse this data"
- Select directory listing and ask "find largest files"

### Recall Previous Results

After generating commands, you can recall them without re-querying the AI:

1. Press `Ctrl+Shift+X` to open the results recall panel
2. Browse commands from your recent prompts, grouped by prompt text
3. Select a command to insert it into the terminal
4. Results are stored in memory (up to 5 recent prompts by default)

This is useful when you generated several options, executed one, and want to go back and try another.

### Prompt History

Access your previous prompts with `Alt+Shift+H`:
1. Press `Alt+Shift+H` to see your prompt history
2. Select a previous prompt from the list
3. The AI will regenerate commands for that prompt

## Configuration

You can customize the plugin by passing configuration options to `apply_to_config`:

```lua
ai_plugin.apply_to_config(config, {
  provider = "anthropic",  -- "anthropic" or "openai" (default: "anthropic")
  api_key = {
    anthropic = "your-anthropic-api-key-here",  -- Your Anthropic API key
    openai = "your-openai-api-key-here"        -- Your OpenAI API key
  },
  max_tokens = 4000,  -- Maximum response length
  temperature = 0.1,  -- Response creativity (0.0-1.0)
  command_count = 5,  -- Number of commands to generate (default: 5)
  max_results_history = 5,  -- Number of recent result sets to keep for recall (default: 5)
  history_file = wezterm.home_dir .. '/.wezterm_ai_prompt_history.txt',  -- History file location
  max_history = 100,  -- Maximum number of history items
})
```

### Provider-specific Options

The plugin automatically uses the correct API endpoint and model for each provider:

**Anthropic (Claude):**
- API URL: `https://api.anthropic.com/v1/messages`
- Default model: `claude-3-5-sonnet-20241022`

**OpenAI (GPT):**
- API URL: `https://api.openai.com/v1/chat/completions`
- Default model: `gpt-4`

You can override these by setting custom values:
```lua
ai_plugin.apply_to_config(config, {
  provider = "openai",
  model = {
    anthropic = "claude-3-5-sonnet-20241022",
    openai = "gpt-4o"  -- Use GPT-4o instead of GPT-4
  },
  api_url = {
    anthropic = "https://api.anthropic.com/v1/messages",
    openai = "https://api.openai.com/v1/chat/completions"
  },
  -- ... other options
})
```

## How It Works

1. **Prompt Processing**: Your natural language input is enhanced with a specific instruction to generate bash commands
2. **AI Generation**: The selected AI provider (Claude or GPT) generates 3-5 different command options based on your description
3. **Command Parsing**: The response is parsed to extract individual commands
4. **Selection Interface**: If multiple commands are generated, you get an interactive menu to choose from
5. **History Management**: Prompts are automatically saved to a history file for reuse

## Configuration Summary

- `provider`: Choose between "anthropic" (Claude) or "openai" (GPT)
- `api_key`: Your API keys for the respective providers
- `command_count`: Number of commands to generate (default: 5)
- `max_results_history`: Number of recent result sets to keep for recall via Ctrl+Shift+X (default: 5)
- `max_tokens`, `temperature`: Control AI response behavior
- `history_file`, `max_history`: Manage prompt history storage

## Files

- `~/.wezterm_ai_prompt_history.txt`: Stores your prompt history (automatically managed)

## Troubleshooting

1. **"[provider] API key not configured"**
   - Ensure you've set the appropriate `api_key.[provider]` parameter in your plugin configuration
   - Check that your API key is valid and properly formatted
   - Make sure the provider matches your configured API key

2. **"Failed to connect to API"**
   - Check your internet connection
   - Verify your API key is valid for the selected provider
   - Check if there are any firewall restrictions

3. **Keybindings not working**
   - Ensure `apply_to_config` is called before `return config` in your `.wezterm.lua`
   - Check for conflicts with other keybindings in your config
   - If you define `config.keys = { ... }` **after** `apply_to_config`, it will overwrite the plugin's keybindings; use `table.insert` instead, or define your keys before calling the plugin

4. **Plugin not loading**
   - Ensure the plugin directory structure is correct
   - Check WezTerm's configuration file syntax
   - Look for error messages in WezTerm's debug output

5. **No commands generated**
   - Try rephrasing your prompt to be more specific
   - Ensure your prompt describes a task that can be accomplished with bash commands

## Security Notes

- Your API keys are stored in your WezTerm configuration and sent to the respective AI provider's servers (Anthropic or OpenAI)
- Prompts are processed by the selected AI provider's API to generate commands
- Consider the sensitivity of information you share with the AI
- Generated commands are not automatically executed - you choose when to run them
- Keep your API keys secure and don't commit them to version control

## License

MIT
