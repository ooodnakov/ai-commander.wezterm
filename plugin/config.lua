local wezterm = require 'wezterm'

local M = {}

-- Default configuration
local config = {
    provider = 'anthropic', -- 'anthropic' or 'openai'
    -- Authentication mode per provider: 'api_key' (default), 'oauth'/'subscription', or 'auto'
    auth_type = {
        anthropic = 'api_key',
        openai = 'api_key',
    },
    api_key = {
        anthropic = nil,    -- Anthropic API key
        openai = nil,       -- OpenAI API key
    },
    api_url = {
        anthropic = 'https://api.anthropic.com/v1/messages',
        openai = 'https://api.openai.com/v1/responses',
    },
    -- OAuth/subscription endpoints. Used when auth_type.<provider> is 'oauth' or 'subscription'.
    subscription_api_url = {
        anthropic = 'https://api.anthropic.com/v1/messages',
        openai = 'https://chatgpt.com/backend-api/codex/responses',
    },
    -- Optional OAuth token overrides. If omitted, the plugin checks common CLI locations.
    oauth = {
        anthropic = {
            access_token = nil,
            credentials_path = nil, -- defaults to $CLAUDE_CONFIG_DIR/.credentials.json or ~/.claude/.credentials.json
        },
        openai = {
            access_token = nil,
            account_id = nil,
            credentials_path = nil, -- defaults to $CODEX_HOME/auth.json or ~/.codex/auth.json
        },
    },
    model = {
        anthropic = 'claude-haiku-4-5',
        openai = 'gpt-5.5',
    },
    max_tokens = 4000,
    chat_max_tokens = 16000,
    backend_python = nil, -- Python executable for plugin/backend.py; nil auto-detects python/python3
    renderer = 'rich', -- Python Rich markdown renderer; set to 'cat' for plain text
    chat_pane_size = 0.8, -- fraction of pane given to the AI response (0.0-1.0)
    conversation_continuity = false, -- keep ask-mode context across turns
    conversation_state_file = wezterm.home_dir .. '/.wezterm_ai_conversation_state.json',
    max_conversation_messages = 12, -- Claude continuity keeps this many recent messages
    temperature = 0.1,
    command_count = 5, -- Number of commands to generate (default: 5)
    history_file = wezterm.home_dir .. '/.wezterm_ai_prompt_history.txt',
    max_history = 100,
    chat_system_prompt = table.concat({
        'You are a helpful assistant running inside a terminal.',
        'Answer questions clearly and concisely using markdown formatting.',
        'Use code blocks with language tags for any code or commands.',
        'Keep explanations practical and actionable.',
    }, '\n'),
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

-- Return the active configuration table
function M.get()
    return config
end

local function shallow_merge(default_value, user_value)
    if type(default_value) == 'table' and type(user_value) == 'table' then
        local merged = {}
        for k, v in pairs(default_value) do merged[k] = v end
        for k, v in pairs(user_value) do merged[k] = v end
        return merged
    end
    return user_value
end

local function add_warning(warnings, message)
    table.insert(warnings, message)
end

function M.validate(current)
    current = current or config
    local warnings = {}
    local provider = current.provider or 'anthropic'

    if provider ~= 'anthropic' and provider ~= 'openai' then
        add_warning(warnings, 'Unsupported provider "' .. tostring(provider) .. '"; expected "anthropic" or "openai".')
    end

    local api_url = current.api_url and current.api_url[provider]
    if not api_url or api_url == '' then
        add_warning(warnings, 'api_url.' .. provider .. ' is not configured.')
    end

    local model = current.model and current.model[provider]
    if not model or model == '' then
        add_warning(warnings, 'model.' .. provider .. ' is not configured.')
    elseif provider == 'anthropic' and not tostring(model):match('^claude') then
        add_warning(warnings, 'model.anthropic usually starts with "claude"; current value is "' .. tostring(model) .. '".')
    elseif provider == 'openai' and not (tostring(model):match('^gpt') or tostring(model):match('^o%d') or tostring(model):match('^chatgpt')) then
        add_warning(warnings, 'model.openai should be an OpenAI Responses-capable model; current value is "' .. tostring(model) .. '".')
    end

    local auth_type = (current.auth_type and current.auth_type[provider]) or 'api_key'
    if auth_type ~= 'api_key' and auth_type ~= 'oauth' and auth_type ~= 'subscription' and auth_type ~= 'auto' and auth_type ~= 'codex' then
        add_warning(warnings, 'auth_type.' .. provider .. ' is "' .. tostring(auth_type) .. '", expected api_key, oauth, subscription, auto, or codex.')
    end

    if provider == 'openai' then
        if api_url and not tostring(api_url):match('/responses$') then
            add_warning(warnings, 'api_url.openai should point at the Responses API (/v1/responses).')
        end
    end

    if (auth_type == 'oauth' or auth_type == 'subscription' or auth_type == 'codex') then
        if not (current.subscription_api_url and current.subscription_api_url[provider]) then
            add_warning(warnings, 'subscription_api_url.' .. provider .. ' is required for OAuth/subscription mode.')
        end
        if current.api_key and current.api_key[provider] then
            add_warning(warnings, 'api_key.' .. provider .. ' is configured but ignored while auth_type.' .. provider .. ' is ' .. auth_type .. '.')
        end
    end

    local chat_max = tonumber(current.chat_max_tokens) or 0
    local max_tok = tonumber(current.max_tokens) or 0
    if chat_max <= 0 then
        add_warning(warnings, 'chat_max_tokens should be greater than zero.')
    elseif max_tok > chat_max then
        add_warning(warnings, 'max_tokens is greater than chat_max_tokens; ask mode may allow fewer tokens than command generation.')
    end

    if current.conversation_continuity and not current.conversation_state_file then
        add_warning(warnings, 'conversation_state_file is required when conversation_continuity is enabled.')
    end

    if not current.renderer or current.renderer == '' then
        add_warning(warnings, 'renderer is empty; set it to "rich", "streamdown", "cat", or a command path.')
    end

    return warnings
end

-- Merge user configuration with defaults
function M.apply(plugin_config)
    if plugin_config then
        for key, value in pairs(plugin_config) do
            config[key] = shallow_merge(config[key], value)
        end
    end

    for _, warning in ipairs(M.validate(config)) do
        wezterm.log_warn('ai-commander config: ' .. warning)
    end
end

return M
