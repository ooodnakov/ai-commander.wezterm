local wezterm = require 'wezterm'
local act = wezterm.action
local cfg = require 'config'
local history = require 'history'
local provider = require 'provider'

local M = {}

-- In-memory storage for last AI results (survives across calls, not across WezTerm restarts)
-- Each entry: { prompt = "...", commands = { {cmd=..., desc=...}, ... } }
local last_results = {}
local max_results_history = 5

-- Set max_results_history from external config
function M.set_max_results_history(value)
    max_results_history = value
end

-- Syntax-highlight a bash command string using bat (if available)
-- Returns the string with ANSI escape codes, or the original string as fallback
local function highlight_bash(text)
    local success, stdout, stderr = wezterm.run_child_process {
        'bash', '-c', 'printf %s ' .. wezterm.shell_quote_arg(text) .. ' | bat --language=bash --color=always --style=plain --paging=never 2>/dev/null',
    }
    if success and stdout and #stdout > 0 then
        -- Remove trailing newline that bat adds
        return stdout:gsub("[\r\n]+$", "")
    end
    return text
end

-- Helper to build a styled label for a command entry
local function build_command_label(entry)
    local first_line = entry.cmd:match("^([^\n]*)")
    local is_multiline = entry.cmd:find("\n") ~= nil
    local highlighted = highlight_bash(first_line)
    local label

    if entry.desc then
        label = highlighted
            .. (is_multiline and ' ...' or '')
            .. wezterm.format {
                'ResetAttributes',
                { Foreground = { AnsiColor = 'Silver' } },
                { Text = '  \u{2502} ' },
                { Attribute = { Italic = true } },
                { Text = entry.desc },
            }
    else
        label = highlighted .. (is_multiline and ' ...' or '')
    end
    return label
end

-- Process a prompt with optional context: call AI, parse response, show selector
local function process_prompt_with_context(prompt, context, window, pane)
    local config = cfg.get()
    history.save(prompt)

    local api_prompt = table.concat({
        'Task: ' .. prompt,
        '',
        'Generate ' .. config.command_count .. ' different command options to accomplish the task above.',
        '',
        'Rules:',
        '- Output each option as exactly two lines: the command on the first line, a short description on the second line',
        '- Separate each option with a blank line',
        '- No numbering, no markdown, no code fences, no other formatting',
        '- The description line must start with "## " and be a brief explanation (under 80 chars)',
        '- Use the most appropriate tool for the job (see your expertise above)',
        '- Prefer idempotent and non-destructive approaches where possible',
        '- If a command is potentially destructive or irreversible, note it in the description',
        '- Use realistic values instead of placeholder variables like <your-value> wherever possible',
        '- Commands must be ready to paste and run in a terminal without modification',
        '- Multi-line commands (heredocs, pipelines with backslash continuations) are allowed; they count as one option',
        '- IMPORTANT: the "## " description line must come AFTER the complete command (including all heredoc/continuation lines)',
        '',
        'Example output format:',
        'docker ps -a --format "table {{.ID}}\\t{{.Names}}\\t{{.Status}}"',
        '## List all containers with ID, name and status in a table',
        '',
        'kubectl apply -f - <<EOF',
        'apiVersion: v1',
        'kind: Pod',
        'metadata:',
        '  name: netshoot',
        'spec:',
        '  containers:',
        '  - name: netshoot',
        '    image: nicolaka/netshoot',
        '    command: ["sleep", "infinity"]',
        'EOF',
        '## Create a netshoot debugging pod via heredoc manifest',
    }, '\n')

    -- Add context if available
    if context and context ~= "" then
        api_prompt = api_prompt .. '\n\nContext (text selected in terminal):\n' .. context
    end

    provider.call(config, config.system_prompt, api_prompt, function(response)

        -- Parse response into command + description pairs
        -- Description lines start with "## ". Everything between descriptions is the command
        -- (which may span multiple lines for heredocs, pipelines, etc.)
        local commands = {}
        local current_lines = {}

        for line in (response .. "\n"):gmatch("([^\r\n]*)\r?\n") do
            local desc_match = line:match("^##%s+(.*)")
            if desc_match then
                -- This is a description line; everything accumulated so far is the command
                if #current_lines > 0 then
                    -- Join command lines, trim trailing blank lines
                    while #current_lines > 0 and current_lines[#current_lines]:match("^%s*$") do
                        table.remove(current_lines)
                    end
                    if #current_lines > 0 then
                        local cmd = table.concat(current_lines, "\n")
                        table.insert(commands, { cmd = cmd, desc = desc_match })
                    end
                end
                current_lines = {}
            else
                -- Accumulate command lines (skip leading blank lines between commands)
                if #current_lines > 0 or not line:match("^%s*$") then
                    table.insert(current_lines, line)
                end
            end
        end

        -- Handle trailing command without a description
        while #current_lines > 0 and current_lines[#current_lines]:match("^%s*$") do
            table.remove(current_lines)
        end
        if #current_lines > 0 then
            local cmd = table.concat(current_lines, "\n")
            table.insert(commands, { cmd = cmd, desc = nil })
        end

        if #commands == 0 then
            pane:send_text("# Error: No commands generated")
            return
        end

        -- Save results for later recall via show_last_results
        table.insert(last_results, 1, { prompt = prompt, commands = commands })
        while #last_results > max_results_history do
            table.remove(last_results)
        end

        if #commands == 1 then
            -- If only one command, send it without showing selector
            pane:send_text(commands[1].cmd)
            return
        end

        -- Build choices with styled labels: command + inline description
        local choices = {}
        for idx, entry in ipairs(commands) do
            table.insert(choices, {
                id = tostring(idx),
                label = build_command_label(entry),
            })
        end

        window:perform_action(
            act.InputSelector {
                action = wezterm.action_callback(function(window, pane, id, label)
                    if id then
                        local selected = commands[tonumber(id)]
                        if selected then
                            pane:send_text(selected.cmd)
                        end
                    end
                end),
                title = 'Select Command',
                choices = choices,
                description = 'Choose a command to execute (press / to filter):',
            },
            pane
        )
    end)
end

-- Show prompt history and re-run selected prompt
function M.show_history(window, pane)
    local hist = history.load()

    if #hist == 0 then
        pane:send_text("# No prompt history available")
        return
    end

    -- Create choices for history selection
    local choices = {}
    for i, prompt in ipairs(hist) do
        table.insert(choices, {
            id = tostring(i),
            label = prompt
        })
    end

    window:perform_action(
        act.InputSelector {
            action = wezterm.action_callback(function(window, pane, id, label)
                if id then
                    local selected_prompt = hist[tonumber(id)]
                    if selected_prompt then
                        -- Get selected text as context, just like in show_prompt
                        local selection = window:get_selection_text_for_pane(pane)
                        process_prompt_with_context(selected_prompt, selection, window, pane)
                    end
                end
            end),
            title = 'Select Previous Prompt',
            choices = choices,
            description = 'Choose a prompt from history:',
        },
        pane
    )
end

-- Show last AI results grouped by prompt
function M.show_last_results(window, pane)
    if #last_results == 0 then
        -- No previous results, fall back to showing prompt
        M.show_prompt(window, pane)
        return
    end

    -- Build a flat list of choices grouped by prompt
    local choices = {}
    -- Flat lookup: map choice id -> { cmd, result_index }
    local choice_map = {}
    local choice_id = 0

    for ri, result in ipairs(last_results) do
        -- Add a header entry for the prompt
        local header_label = wezterm.format {
            { Foreground = { AnsiColor = 'Yellow' } },
            { Attribute = { Intensity = 'Bold' } },
            { Text = '\u{2500}\u{2500} ' .. result.prompt .. ' \u{2500}\u{2500}' },
        }
        table.insert(choices, {
            id = '__header__',
            label = header_label,
        })

        -- Add each command under this prompt
        for ci, entry in ipairs(result.commands) do
            choice_id = choice_id + 1
            local id_str = tostring(choice_id)
            choice_map[id_str] = { cmd = entry.cmd, result_index = ri }
            table.insert(choices, {
                id = id_str,
                label = '  ' .. build_command_label(entry),
            })
        end
    end

    window:perform_action(
        act.InputSelector {
            action = wezterm.action_callback(function(window, pane, id, label)
                if id and id ~= '__header__' then
                    local mapping = choice_map[id]
                    if mapping then
                        pane:send_text(mapping.cmd)
                    end
                end
            end),
            title = 'Previous AI Results',
            choices = choices,
            description = 'Select a command from previous results (press / to filter):',
        },
        pane
    )
end

-- Show prompt input and process the entered prompt
function M.show_prompt(window, pane)
    -- Get selected text as context
    local selection = window:get_selection_text_for_pane(pane)
    local context_description = ""

    if selection and selection ~= "" then
        context_description = "Enter prompt for command to generate (selected text will be used as context):"
    else
        context_description = "Enter prompt for command to generate:"
    end

    window:perform_action(
        act.PromptInputLine {
            description = context_description,
            action = wezterm.action_callback(function(window, pane, line)
                if not line then
                    return
                end

                process_prompt_with_context(line, selection, window, pane)
            end),
        },
        pane
    )
end

return M
