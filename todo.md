# AI Commander TODO

## Chat pane

- Add context-window safeguards: warn/truncate when selected text or history gets too large.
- Add `/load` or equivalent flow to reopen saved chat transcripts.

## Command generation

- Include recent terminal output as optional command-generation context.

## Chat command handling

- Extract commands from chat responses and support `/insert N`, `/copy N`, and `/run N`.
- Reuse destructive-command confirmation for chat command insert/run.
