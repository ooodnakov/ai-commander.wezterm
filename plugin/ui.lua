local wezterm = require 'wezterm'
local act = wezterm.action
local cfg = require 'config'
local history = require 'history'
local provider = require 'provider'

local M = {}

local function with_context(text, context)
    if not context or context == '' then
        return text
    end
    return text .. '\n\nContext:\n' .. context
end

local function active_pane_for(window, pane)
    if window then
        -- Prefer mux active pane. GUI active_pane() may point at an InputSelector/
        -- PromptInputLine overlay pane; send_text against that can fail with
        -- "pane id ... not found in mux" after switching panes.
        local ok_mux, mux_pane = pcall(function()
            local mux_window = window:mux_window()
            if mux_window then
                return mux_window:active_pane()
            end
        end)
        if ok_mux and mux_pane then return mux_pane end

        local ok_gui, active = pcall(function()
            return window:active_pane()
        end)
        if ok_gui and active then return active end
    end
    return pane
end

local function send_text(window, pane, text)
    local target = active_pane_for(window, pane)
    if not target then return false end

    local ok, err = pcall(function()
        target:send_text(text)
    end)
    if not ok then
        wezterm.log_warn('ai-commander: unable to send text to pane: ' .. tostring(err))
        return false
    end
    return true
end

local function perform_action(window, pane, action)
    local target = active_pane_for(window, pane)
    if not window or not target then return false end

    local ok, err = pcall(function()
        window:perform_action(action, target)
    end)
    if not ok then
        wezterm.log_warn('ai-commander: unable to perform action: ' .. tostring(err))
        return false
    end
    return true
end


local selection_text_for_pane

-- In-memory storage for last AI results (survives across calls, not across WezTerm restarts)
-- Each entry: { prompt = "...", commands = { {cmd=..., desc=...}, ... } }
local last_results = {}
local max_results_history = 5

-- Set max_results_history from external config
function M.set_max_results_history(value)
    max_results_history = value
end

local function highlight_bash(text)
    local path = os.tmpname() .. '_ai_commander_command.sh'
    local file = io.open(path, 'w')
    if not file then return text end
    file:write(text or '')
    file:close()

    local ok, success, stdout = pcall(wezterm.run_child_process, {
        'bat', '--style=plain', '--color=always', '--language=bash', path
    })
    os.remove(path)
    if ok and success and stdout and stdout ~= '' then
        return stdout:gsub('\n+$', '')
    end
    return text
end

local function formatted(parts)
    local ok, result = pcall(wezterm.format, parts)
    if ok and result then return result end

    local texts = {}
    for _, part in ipairs(parts) do
        if type(part) == 'table' and part.Text then texts[#texts + 1] = part.Text end
    end
    return table.concat(texts)
end

local function truncate_text(text, limit)
    text = tostring(text or ''):gsub('%s+', ' ')
    if #text <= limit then return text end
    return text:sub(1, limit - 1) .. '…'
end

local function danger_badge(entry)
    local haystack = ((entry.cmd or '') .. '\n' .. (entry.desc or '')):lower()
    if haystack:find('rm%s+%-rf') or haystack:find('delete') or haystack:find('drop%s+') or haystack:find('kill%s+') then
        return '  ⚠'
    end
    return ''
end

-- Helper to build a styled label for a command entry
local function build_command_label(entry)
    local first_line = entry.cmd:match("^([^\n]*)")
    local is_multiline = entry.cmd:find("\n") ~= nil
    local highlighted = highlight_bash(first_line)
    local multiline = is_multiline and '  ↵' or ''
    local badge = danger_badge(entry)

    if entry.desc then
        return formatted {
            { Text = highlighted },
            { Foreground = { AnsiColor = 'Aqua' } },
            { Text = multiline },
            { Foreground = { AnsiColor = 'Yellow' } },
            { Text = badge },
            'ResetAttributes',
            { Foreground = { AnsiColor = 'Silver' } },
            { Text = '  │ ' },
            { Attribute = { Italic = true } },
            { Text = truncate_text(entry.desc, 96) },
        }
    end

    return formatted {
        { Text = highlighted },
        { Foreground = { AnsiColor = 'Aqua' } },
        { Text = multiline },
        { Foreground = { AnsiColor = 'Yellow' } },
        { Text = badge },
    }
end

local function show_generating_selector(user_prompt, context, window, pane)
    local label = formatted {
        { Foreground = { AnsiColor = 'Fuchsia' } },
        { Attribute = { Intensity = 'Bold' } },
        { Text = '⏳ Generating commands' },
        'ResetAttributes',
        { Foreground = { AnsiColor = 'Silver' } },
        { Text = '  │ ' .. truncate_text(user_prompt, 72) },
    }

    local context_hint = context and context ~= '' and 'selected context included' or 'no selected context'
    perform_action(
        window,
        pane,
        act.InputSelector {
            action = wezterm.action_callback(function() end),
            title = 'AI Commander · Generating Commands',
            choices = {
                { id = '__waiting__', label = label },
            },
            description = 'Waiting for provider response… ' .. context_hint .. '. The command selector will replace this panel.',
        }
    )
end

local function schedule_after_ui(callback)
    if wezterm.time and wezterm.time.call_after then
        wezterm.time.call_after(0.05, callback)
    else
        callback()
    end
end

local function window_theme(window)
    if not window then return nil end

    local ok, effective = pcall(function()
        return window:effective_config()
    end)
    if not ok or not effective or not effective.colors then return nil end

    local colors = effective.colors
    local ansi = colors.ansi or {}
    local brights = colors.brights or {}
    return {
        foreground = colors.foreground,
        background = colors.background,
        accent = brights[6] or ansi[6] or colors.cursor_bg,
        accent2 = brights[7] or ansi[7] or colors.cursor_border,
        muted = brights[1] or ansi[1],
        success = brights[3] or ansi[3],
        warning = brights[4] or ansi[4],
    }
end

local function config_with_theme(config, window)
    local themed = {}
    for key, value in pairs(config or {}) do
        themed[key] = value
    end
    themed.theme = window_theme(window)
    return themed
end

local completion_status = nil
local completion_status_registered = false

local function completion_status_ttl(state)
    if state == 'working' then return 120 end
    return 3
end

local function completion_indicator_parts(status)
    if not status then return nil end
    if status.expires_at and os.time() > status.expires_at then
        completion_status = nil
        return nil
    end

    return {
        { Foreground = { AnsiColor = status.color } },
        { Attribute = { Intensity = 'Bold' } },
        { Text = status.icon .. ' ' .. status.label },
        'ResetAttributes',
        { Foreground = { AnsiColor = 'Silver' } },
        { Text = '  │  ' .. truncate_text(status.prefix or '', 48) },
    }
end

local function render_completion_indicator(window)
    local parts = completion_indicator_parts(completion_status)
    if not parts or not window then return false end

    local ok = pcall(function()
        window:set_right_status(formatted(parts))
    end)
    return ok
end

function M.setup_completion_indicator()
    if completion_status_registered then return end
    completion_status_registered = true

    if not wezterm.on then return end
    wezterm.on('update-status', function(window)
        render_completion_indicator(window)
    end)
end

local function set_completion_indicator(window, state, prefix)
    if not window then return end

    local icon = state == 'done' and '✓' or (state == 'empty' and '∅' or '󰚩')
    local color = state == 'done' and 'Green' or (state == 'empty' and 'Yellow' or 'Aqua')
    local label = state == 'done' and 'AI completion inserted'
        or (state == 'empty' and 'AI found no completion' or 'AI completing command…')

    completion_status = {
        icon = icon,
        color = color,
        label = label,
        prefix = prefix,
        expires_at = os.time() + completion_status_ttl(state),
    }

    if not render_completion_indicator(window) then
        pcall(function()
            window:toast_notification('AI Commander', label, nil, 1500)
        end)
    end
end

local function last_line(text)
    local value = tostring(text or ''):gsub('\r', '')
    return value:match('.*\n([^\n]*)$') or value
end

local function strip_common_prompt(line)
    line = last_line(line)
    local stripped = line:match('^%s*❯%s*(.*)$')
    if stripped then return stripped end

    stripped = line:match('^%s*[>$#%%λ]%s*(.*)$')
    if stripped then return stripped end

    stripped = line:match('^.*[%]%)}][%s]*[>$#%%]%s+(.*)$')
    if stripped then return stripped end

    stripped = line:match('^.*[%w_.%-]+@[%w_.%-]+.-[>$#%%]%s+(.*)$')
    if stripped then return stripped end

    return line:gsub('^%s+', '')
end

local function split_lines(text)
    local lines = {}
    local value = tostring(text or '')
    for line in (value .. '\n'):gmatch('([^\n]*)\n') do
        table.insert(lines, line)
        if #lines > 200 then break end
    end
    if #lines > 0 and lines[#lines] == '' and value:sub(-1) ~= '\n' then
        table.remove(lines)
    end
    return lines
end

local continuation_prompts = {
    ['>'] = true,
    quote = true,
    dquote = true,
    bquote = true,
    cmdsubst = true,
    heredoc = true,
    ['for'] = true,
    ['while'] = true,
    ['until'] = true,
    ['if'] = true,
    ['then'] = true,
    ['else'] = true,
    ['case'] = true,
    select = true,
    ['function'] = true,
    brace = true,
    pipe = true,
}

local function is_continuation_prompt(line)
    local prompt = tostring(line or ''):match('^%s*([%w_%-]*)>%s+')
    if prompt == nil then return false end
    if prompt == '' then return true end
    prompt = prompt:gsub('%-', '_')
    return continuation_prompts[prompt] or false
end

local function line_continues(stripped)
    local value = tostring(stripped or ''):match('^%s*(.-)%s*$') or ''
    return value:match('\\$')
        or value:match('|$')
        or value:match('&&$')
        or value:match('%|%|$')
        or value:match('%($')
        or value:match('%{$')
        or value:match('%[$')
        or value:match('%f[%w]do$')
        or value:match('%f[%w]then$')
end

local function multiline_command_prefix(target, current_raw, current_prefix)
    local ok_recent, recent = pcall(function()
        return target:get_lines_as_text(12)
    end)
    if not ok_recent or not recent or recent == '' then
        return current_prefix, current_raw
    end

    local lines = split_lines(recent)
    if current_raw and current_raw ~= '' then
        if #lines == 0 or last_line(lines[#lines]) ~= last_line(current_raw) then
            table.insert(lines, current_raw)
        else
            lines[#lines] = current_raw
        end
    end
    if #lines == 0 then return current_prefix, current_raw end

    local current_is_continuation = is_continuation_prompt(current_raw)
    if not current_is_continuation then
        local previous = lines[#lines - 1]
        if not previous or not line_continues(strip_common_prompt(previous)) then
            return current_prefix, current_raw
        end
    end

    local collected = { current_prefix or '' }
    for index = #lines - 1, 1, -1 do
        local raw = lines[index]
        local stripped = strip_common_prompt(raw)
        if stripped == '' then break end
        table.insert(collected, 1, stripped)
        if not is_continuation_prompt(raw) then
            break
        end
    end

    return table.concat(collected, '\n'), table.concat(lines, '\n')
end


local function current_command_prefix(window, pane)
    local target = active_pane_for(window, pane)
    if not target then return nil, nil end

    local ok_cursor, cursor = pcall(function()
        return target:get_cursor_position()
    end)
    if ok_cursor and cursor and cursor.y then
        local end_x = cursor.x or 0
        if end_x < 1 then end_x = 1 end
        local ok_region, text = pcall(function()
            return target:get_text_from_region(0, cursor.y, end_x, cursor.y)
        end)
        if ok_region and text and text ~= '' then
            local raw = last_line(text)
            local prefix = strip_common_prompt(raw)
            return multiline_command_prefix(target, raw, prefix)
        end
    end

    local ok_line, text = pcall(function()
        return target:get_lines_as_text(1)
    end)
    if ok_line and text and text ~= '' then
        local raw = last_line(text)
        local prefix = strip_common_prompt(raw)
        return multiline_command_prefix(target, raw, prefix)
    end

    return nil, nil
end

local function sanitize_completion(response, prefix, raw_line)
    local text = tostring(response or ''):gsub('\r', '')
    text = text:gsub('^```[^\n]*\n', ''):gsub('\n```%s*$', '')
    local inline = text:match('^%s*`([^`]+)`%s*$')
    if inline then text = inline end
    text = text:gsub('^\n+', ''):gsub('\n+$', '')

    local trimmed = text:match('^%s*(.-)%s*$') or ''
    if trimmed:match('^Error:') then return '' end
    if prefix and prefix ~= '' and text:sub(1, #prefix) == prefix then
        return text:sub(#prefix + 1)
    end
    if raw_line and raw_line ~= '' and text:sub(1, #raw_line) == raw_line then
        return text:sub(#raw_line + 1)
    end
    return text
end

local completion_system_prompt = table.concat({
    'You complete partially typed shell commands, including multiline commands.',
    'Return only the exact suffix to append at the cursor on the current line.',
    'Use prior lines only as context; do not repeat existing lines unless no shorter suffix is possible.',
    'Do not include markdown, quotes, explanations, or trailing newline.',
    'Prefer safe, boring, idiomatic shell completions.',
    'If there is no useful safe completion, return an empty response.',
}, '\n')


-- Process a prompt with optional context: call AI, parse response, show selector
local function process_prompt_with_context(user_prompt, context, window, pane)
    local config = config_with_theme(cfg.get(), window)
    history.save(user_prompt)

    local api_prompt = table.concat({
        'Task: ' .. user_prompt,
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

    api_prompt = with_context(api_prompt, context)

    provider.call(config, config.system_prompt, api_prompt, function(response)
        -- Parse response into command + description pairs.
        -- Description lines start with "## ". Everything between descriptions is the command.
        local commands = {}
        local current_lines = {}

        for line in (response .. "\n"):gmatch("([^\r\n]*)\r?\n") do
            local desc_match = line:match("^##%s+(.*)")
            if desc_match then
                if #current_lines > 0 then
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
                if #current_lines > 0 or not line:match("^%s*$") then
                    table.insert(current_lines, line)
                end
            end
        end

        while #current_lines > 0 and current_lines[#current_lines]:match("^%s*$") do
            table.remove(current_lines)
        end
        if #current_lines > 0 then
            local cmd = table.concat(current_lines, "\n")
            table.insert(commands, { cmd = cmd, desc = nil })
        end

        if #commands == 0 then
            send_text(window, pane, "# Error: No commands generated")
            return
        end

        table.insert(last_results, 1, { prompt = user_prompt, commands = commands })
        while #last_results > max_results_history do
            table.remove(last_results)
        end

        if #commands == 1 then
            send_text(window, pane, commands[1].cmd)
            return
        end

        local choices = {}
        for idx, entry in ipairs(commands) do
            table.insert(choices, {
                id = tostring(idx),
                label = build_command_label(entry),
            })
        end

        perform_action(
            window,
            pane,
            act.InputSelector {
                action = wezterm.action_callback(function(window, pane, id, label)
                    if id then
                        local selected = commands[tonumber(id)]
                        if selected then
                            send_text(window, pane, selected.cmd)
                        end
                    end
                end),
                title = 'AI Commander · Choose Command',
                choices = choices,
                description = 'Pick a command to paste into the pane. Press / to filter; multiline commands show ↵.',
            }
        )
    end)
end

-- Show prompt history and re-run selected prompt
function M.show_history(window, pane)
    local hist = history.load()

    if #hist == 0 then
        send_text(window, pane, "# No prompt history available")
        return
    end

    local choices = {}
    for i, hist_prompt in ipairs(hist) do
        table.insert(choices, {
            id = tostring(i),
            label = formatted {
                { Foreground = { AnsiColor = 'Fuchsia' } },
                { Attribute = { Intensity = 'Bold' } },
                { Text = '❯ ' },
                'ResetAttributes',
                { Text = truncate_text(hist_prompt, 110) },
            },
        })
    end

    perform_action(
        window,
        pane,
        act.InputSelector {
            action = wezterm.action_callback(function(window, pane, id, label)
                if id then
                    local selected_prompt = hist[tonumber(id)]
                    if selected_prompt then
                        local selection = selection_text_for_pane(window, pane)
                        show_generating_selector(selected_prompt, selection, window, pane)
                        schedule_after_ui(function()
                            process_prompt_with_context(selected_prompt, selection, window, pane)
                        end)
                    end
                end
            end),
            title = 'AI Commander · Prompt History',
            choices = choices,
            description = 'Choose a previous prompt to regenerate. Waiting panel stays visible while AI works.',
        }
    )
end

-- Show last AI results grouped by prompt
function M.show_last_results(window, pane)
    if #last_results == 0 then
        M.show_prompt(window, pane)
        return
    end

    local choices = {}
    local choice_map = {}
    local choice_id = 0

    for _, result in ipairs(last_results) do
        local header_label = formatted {
            { Foreground = { AnsiColor = 'Yellow' } },
            { Attribute = { Intensity = 'Bold' } },
            { Text = '── ' .. truncate_text(result.prompt, 96) .. ' ──' },
        }
        table.insert(choices, {
            id = '__header__',
            label = header_label,
        })

        for _, entry in ipairs(result.commands) do
            choice_id = choice_id + 1
            local id_str = tostring(choice_id)
            choice_map[id_str] = { cmd = entry.cmd }
            table.insert(choices, {
                id = id_str,
                label = '  ' .. build_command_label(entry),
            })
        end
    end

    perform_action(
        window,
        pane,
        act.InputSelector {
            action = wezterm.action_callback(function(window, pane, id, label)
                if id and id ~= '__header__' then
                    local mapping = choice_map[id]
                    if mapping then
                        send_text(window, pane, mapping.cmd)
                    end
                end
            end),
            title = 'AI Commander · Previous Results',
            choices = choices,
            description = 'Pick a previously generated command. Press / to filter.',
        }
    )
end

selection_text_for_pane = function(window, pane)
    if not window or not pane then return nil end

    local target = active_pane_for(window, pane)
    if not target then return nil end

    local ok, selection = pcall(function()
        return window:get_selection_text_for_pane(target)
    end)
    if not ok then
        wezterm.log_warn('ai-commander: unable to read pane selection: ' .. tostring(selection))
        return nil
    end

    if selection == '' then return nil end
    return selection
end

function M.complete_current_command(window, pane)
    local target = active_pane_for(window, pane)
    if not target then return end

    local prefix, raw_line = current_command_prefix(window, target)
    if not prefix or prefix == '' then return end

    local cwd = ''
    local ok_cwd, cwd_value = pcall(function()
        return target:get_current_working_dir()
    end)
    if ok_cwd and cwd_value then cwd = tostring(cwd_value) end

    local process_name = ''
    local ok_process, process_value = pcall(function()
        return target:get_foreground_process_name()
    end)
    if ok_process and process_value then process_name = tostring(process_value) end

    local prompt = table.concat({
        'Current terminal command block, including prompt if visible:',
        raw_line or '',
        '',
        'Editable command prefix (may be multiline):',
        prefix,
        '',
        'Current working directory:',
        cwd,
        '',
        'Foreground process:',
        process_name,
        '',
        'Return only the suffix to append at the cursor on the current line.',
    }, '\n')

    local config = config_with_theme(cfg.get(), window)
    set_completion_indicator(window, 'working', prefix)
    schedule_after_ui(function()
        provider.call(config, completion_system_prompt, prompt, function(response)
            local completion = sanitize_completion(response, prefix, raw_line)
            if completion and completion ~= '' then
                send_text(window, target, completion)
                set_completion_indicator(window, 'done', prefix .. completion)
            else
                set_completion_indicator(window, 'empty', prefix)
            end
        end, { max_tokens = 160 })
    end)
end

-- Show prompt input and process the entered prompt
function M.show_prompt(window, pane)
    local selection = selection_text_for_pane(window, pane)
    local context_text = (selection and selection ~= '') and 'selected context: on' or 'selected context: off'
    local context_description = formatted {
        { Foreground = { AnsiColor = 'Fuchsia' } },
        { Attribute = { Intensity = 'Bold' } },
        { Text = 'AI Commander · Command Prompt' },
        'ResetAttributes',
        { Foreground = { AnsiColor = 'Silver' } },
        { Text = '  │  ' },
        { Foreground = { AnsiColor = 'Aqua' } },
        { Text = context_text },
        { Foreground = { AnsiColor = 'Silver' } },
        { Text = '  │  describe shell task' },
    }

    perform_action(
        window,
        pane,
        act.PromptInputLine {
            description = context_description,
            prompt = formatted {
                { Foreground = { AnsiColor = 'Fuchsia' } },
                { Attribute = { Intensity = 'Bold' } },
                { Text = '❯ ' },
            },
            action = wezterm.action_callback(function(window, pane, line)
                if not line or line == '' then
                    return
                end

                show_generating_selector(line, selection, window, pane)
                schedule_after_ui(function()
                    process_prompt_with_context(line, selection, window, pane)
                end)
            end),
        }
    )
end

local function chat_backend_args(config, context)
    local python, backend_or_err = provider.resolve_backend(config)
    if not python then return nil, backend_or_err end

    local configfile, config_err = provider.write_temp_file('_ai_commander_config.json', wezterm.json_encode(config or {}))
    if not configfile then return nil, config_err end

    local contextfile, context_err = provider.write_temp_file('_ai_commander_context.txt', context or '')
    if not contextfile then
        os.remove(configfile)
        return nil, context_err
    end

    return {
        python, backend_or_err, 'chat',
        '--config', configfile,
        '--context', contextfile,
        '--delete-input-files',
    }
end

-- Run backend chat in a real split pane without zooming over the existing layout
local function run_chat_backend(pane, window, config, context)
    local target = active_pane_for(window, pane)
    if not target then return nil end

    local args, err = chat_backend_args(config, context)
    if not args then return err end

    local ok, new_pane = pcall(function()
        return target:split {
            direction = 'Bottom',
            args = args,
            size = config.chat_pane_size,
        }
    end)
    if not ok then
        os.remove(args[5])
        os.remove(args[7])
        wezterm.log_warn('ai-commander: unable to split pane: ' .. tostring(new_pane))
        return 'unable to split pane: ' .. tostring(new_pane)
    end
    return nil
end

-- Open an interactive AI chat in a real split pane
function M.show_ask_inline(window, pane)
    local selection = selection_text_for_pane(window, pane)
    local ok, err = pcall(function()
        local config = config_with_theme(cfg.get(), window)
        return run_chat_backend(pane, window, config, selection)
    end)
    if ok and err then
        wezterm.log_error('ai-commander show_ask_inline: ' .. tostring(err))
        send_text(window, pane, '# Error: ' .. tostring(err) .. '\n')
        return
    end
    if not ok then
        wezterm.log_error('ai-commander show_ask_inline: ' .. tostring(err))
        send_text(window, pane, '# Error: ' .. tostring(err) .. '\n')
    end
end


-- Run provider diagnostics and print the report into the current pane
function M.check_provider(window, pane)
    local config = cfg.get()
    local warnings = cfg.validate(config)
    local report = provider.check(config, warnings)
    if pane then
        send_text(window, pane, '\n# AI Commander Provider Check\n' .. report.message .. '\n')
    end
    return report
end

return M
