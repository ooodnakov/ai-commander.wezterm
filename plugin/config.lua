local wezterm = require 'wezterm'

local M = {}

-- Default configuration
local config = {
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
        anthropic = 'claude-haiku-4-5',
        openai = 'gpt-4o',
    },
    max_tokens = 4000,
    chat_max_tokens = 16000,
    renderer = 'sd', -- streaming markdown renderer command (streamdown); set to 'cat' for plain text
    chat_pane_size = 0.8, -- fraction of pane given to the AI response (0.0-1.0)
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

-- Merge user configuration with defaults
function M.apply(plugin_config)
    if plugin_config then
        for key, value in pairs(plugin_config) do
            config[key] = value
        end
    end
end

return M
