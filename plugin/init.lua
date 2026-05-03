local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

-- Default configuration
local default_config = {
    provider = 'anthropic', -- 'anthropic' or 'openai'
    api_key = {
        anthropic = nil,    -- Anthropic API key
        openai = nil,       -- OpenAI API key
    },
    api_url = {
        anthropic = 'https://api.anthropic.com/v1/messages',
        openai = 'https://api.openai.com/v1/chat/completions',
    },
    model = {
        anthropic = 'claude-sonnet-4-6',
        openai = 'gpt-4o',
    },
    max_tokens = 4000,
    temperature = 0.1,
    command_count = 5, -- Number of commands to generate (default: 5)
    history_file = wezterm.home_dir .. '/.wezterm_ai_prompt_history.txt',
    max_history = 100,
    system_prompt = table.concat({
        'You are an expert DevOps/SRE engineer with deep hands-on experience in:',
        '- Linux/Unix system administration, shell scripting (bash/sh/zsh), and coreutils',
        '- Containerization and orchestration: Docker, Docker Compose, Kubernetes (kubectl, helm, kustomize)',
        '- Cloud platforms and their CLIs: AWS (aws), GCP (gcloud), Azure (az)',
        '- Infrastructure as Code: Terraform, Ansible, Pulumi',
        '- CI/CD: Git, GitHub Actions, GitLab CI, Jenkins',
        '- Observability: Prometheus, Grafana, Loki, journalctl, dmesg',
        '- Networking: curl, wget, netstat, ss, tcpdump, nmap, dig, nslookup, iptables',
        '- Text processing: jq, yq, sed, awk, grep, ripgrep, xargs, cut, tr, sort, uniq',
        '- Package managers: apt, yum/dnf, apk, brew, pip, npm',
        '',
        'Your goal is to produce safe, idiomatic, production-aware terminal commands.',
        'Always prefer non-destructive and idempotent approaches.',
        'When a command is potentially destructive or irreversible, warn the user inline.',
    }, '\n'),
}

-- Active configuration (will be merged with user config)
local config = default_config

-- In-memory storage for last AI results (survives across calls, not across WezTerm restarts)
-- Each entry: { prompt = "...", commands = { {cmd=..., desc=...}, ... } }
local last_results = {}
local max_results_history = 5

-- Function to load prompt history from file
local function load_prompt_history()
    local history = {}
    local file = io.open(config.history_file, 'r')
    if file then
        for line in file:lines() do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                table.insert(history, trimmed)
            end
        end
        file:close()
    end
    return history
end

-- Function to save prompt to history file
local function save_prompt_to_history(prompt)
    local history = load_prompt_history()

    -- Remove if already exists (move to front)
    for i, item in ipairs(history) do
        if item == prompt then
            table.remove(history, i)
            break
        end
    end

    -- Add to front
    table.insert(history, 1, prompt)

    -- Keep only max_history items
    while #history > config.max_history do
        table.remove(history)
    end

    -- Save to file
    local file = io.open(config.history_file, 'w')
    if file then
        for _, item in ipairs(history) do
            file:write(item .. '\n')
        end
        file:close()
    end
end

-- Function to call AI API (supports both Anthropic and OpenAI)
local function call_ai_api(system_message, user_message, callback)
    local provider = config.provider or 'anthropic'
    local api_key = config.api_key[provider]

    if not api_key or api_key == "" then
        callback("Error: " ..
            provider .. " API key not configured. Please set api_key." .. provider .. " in your .wezterm.lua config.")
        return
    end

    local request_body, curl_args

    if provider == 'anthropic' then
        -- Create JSON request body for Anthropic API
        request_body = {
            model = config.model.anthropic,
            max_tokens = config.max_tokens,
            temperature = config.temperature,
            system = system_message,
            messages = {
                {
                    role = "user",
                    content = user_message
                }
            }
        }

        local json_body = wezterm.json_encode(request_body)

        -- Build curl arguments for Anthropic API
        curl_args = {
            "curl",
            "-s",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "x-api-key: " .. api_key,
            "-H", "anthropic-version: 2023-06-01",
            config.api_url.anthropic,
            "-d", json_body
        }
    elseif provider == 'openai' then
        -- Create JSON request body for OpenAI API
        request_body = {
            model = config.model.openai,
            max_tokens = config.max_tokens,
            temperature = config.temperature,
            messages = {
                {
                    role = "system",
                    content = system_message
                },
                {
                    role = "user",
                    content = user_message
                }
            }
        }

        local json_body = wezterm.json_encode(request_body)

        -- Build curl arguments for OpenAI API
        curl_args = {
            "curl",
            "-s",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "Authorization: Bearer " .. api_key,
            config.api_url.openai,
            "-d", json_body
        }
    else
        callback("Error: Unsupported provider: " .. provider)
        return
    end

    -- Make the HTTP request using wezterm.run_child_process
    local success, stdout, stderr = wezterm.run_child_process(curl_args)

    if not success then
        wezterm.log_error("HTTP request failed: " .. (stderr or "Unknown error"))
        callback("Error: HTTP request failed. " .. (stderr or "Unknown error"))
        return
    end

    -- Parse JSON response
    local ok, response = pcall(wezterm.json_parse, stdout)
    if not ok then
        callback("Error: Failed to parse API response: " .. stdout:sub(1, 1500))
        return
    end

    -- Handle API errors
    if response.error then
        local error_msg = "API error: " .. (response.error.message or "Unknown error")
        callback(error_msg)
        return
    end

    -- Extract content based on provider
    if provider == 'anthropic' then
        -- Anthropic API response format
        if response.content and #response.content > 0 and response.content[1].text then
            callback(response.content[1].text)
        else
            callback("Error: No content found in Anthropic API response")
        end
    elseif provider == 'openai' then
        -- OpenAI API response format
        if response.choices and #response.choices > 0 and response.choices[1].message and response.choices[1].message.content then
            callback(response.choices[1].message.content)
        else
            callback("Error: No content found in OpenAI API response")
        end
    end
end

-- Function to process a prompt with optional context
local function process_prompt_with_context(prompt, context, window, pane)
    save_prompt_to_history(prompt)

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

    call_ai_api(config.system_prompt, api_prompt, function(response)
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

-- Function to process a prompt (backward compatibility)
local function process_prompt(prompt, window, pane)
    process_prompt_with_context(prompt, nil, window, pane)
end

function M.apply_to_config(wezterm_config, plugin_config)
    -- Merge user configuration with defaults
    if plugin_config then
        for key, value in pairs(plugin_config) do
            if key == 'max_results_history' then
                max_results_history = value
            else
                config[key] = value
            end
        end
    end
end

-- Expose function for showing prompt history
function M.show_history(window, pane)
    local history = load_prompt_history()

    if #history == 0 then
        pane:send_text("# No prompt history available")
        return
    end

    -- Create choices for history selection
    local choices = {}
    for i, prompt in ipairs(history) do
        table.insert(choices, {
            id = tostring(i),
            label = prompt
        })
    end

    window:perform_action(
        act.InputSelector {
            action = wezterm.action_callback(function(window, pane, id, label)
                if id then
                    local selected_prompt = history[tonumber(id)]
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

-- Helper to build a styled label for a command entry
local function build_command_label(entry)
    local first_line = entry.cmd:match("^([^\n]*)")
    local is_multiline = entry.cmd:find("\n") ~= nil
    local label

    if entry.desc then
        label = wezterm.format {
            { Foreground = { AnsiColor = 'Green' } },
            { Attribute = { Intensity = 'Bold' } },
            { Text = first_line .. (is_multiline and ' ...' or '') },
            'ResetAttributes',
            { Foreground = { AnsiColor = 'Fuchsia' } },
            { Text = '  \u{2502} ' },
            { Foreground = { AnsiColor = 'Silver' } },
            { Attribute = { Italic = true } },
            { Text = entry.desc },
        }
    else
        label = wezterm.format {
            { Foreground = { AnsiColor = 'Green' } },
            { Attribute = { Intensity = 'Bold' } },
            { Text = first_line .. (is_multiline and ' ...' or '') },
        }
    end
    return label
end

-- Expose function for showing last AI results
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

-- Expose function for showing prompt input
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
