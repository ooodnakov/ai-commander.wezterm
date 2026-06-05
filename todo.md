# AI Commander TODO

## Chat pane

- Add slash commands: `/clear`, `/context`, `/model`, `/provider`, `/save`, and `/copy`.
- Make `Ctrl+C` cancel the active response while keeping the chat pane alive.
- Show startup status: provider, model, renderer, selected-context size, and history message count.
- Keep a per-chat transcript file that can be saved or reopened.

## Prompt and context UX

- Make prompt history editable before submit instead of immediately rerunning old prompts.
- Add a separate repeat-last-prompt action for current selected context.
- Add commands to refresh or drop selected-pane context inside chat.
- Include useful shell context: current working directory, git branch, prompt line, and optionally recent terminal output.

## Command handling

- Extract commands from chat responses and support `/insert N`, `/copy N`, and `/run N`.
- Flag destructive commands and require confirmation before inserting or running them.
- Keep generated command recall separate from chat transcript recall.

## Diagnostics

- Add `WEZTERM_AI_COMMANDER_DEBUG=1` to save request bodies, response events, renderer command, and history JSON.
- Add provider/model health details to the existing check command.
