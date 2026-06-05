local wezterm = require 'wezterm'

local M = {}

local function expand_path(path)
    if not path or path == '' then return nil end
    path = path:gsub('^~', wezterm.home_dir)
    path = path:gsub('%$([A-Z_][A-Z0-9_]*)', function(name)
        return os.getenv(name) or ''
    end)
    return path
end

local function read_json_file(path)
    path = expand_path(path)
    if not path then return nil end

    local file = io.open(path, 'r')
    if not file then return nil end
    local contents = file:read('*a')
    file:close()

    if not contents or contents == '' then return nil end
    local ok, parsed = pcall(wezterm.json_parse, contents)
    if ok then return parsed end
    return nil
end

local function get_path(tbl, path)
    local value = tbl
    for part in path:gmatch('[^%.]+') do
        if type(value) ~= 'table' then return nil end
        value = value[part]
    end
    if value == '' then return nil end
    return value
end

local function first_path(tbl, paths)
    for _, path in ipairs(paths) do
        local value = get_path(tbl, path)
        if value then return value end
    end
    return nil
end

local function first_env(names)
    for _, name in ipairs(names) do
        local value = os.getenv(name)
        if value and value ~= '' then return value end
    end
    return nil
end

local function default_claude_credentials_path()
    local config_dir = os.getenv('CLAUDE_CONFIG_DIR')
    if config_dir and config_dir ~= '' then
        return config_dir .. '/.credentials.json'
    end
    return wezterm.home_dir .. '/.claude/.credentials.json'
end

local function default_codex_auth_path()
    local codex_home = os.getenv('CODEX_HOME')
    if codex_home and codex_home ~= '' then
        return codex_home .. '/auth.json'
    end
    return wezterm.home_dir .. '/.codex/auth.json'
end

local function resolve_api_key(config, name)
    local configured = config.api_key and config.api_key[name]
    if configured and configured ~= '' then
        return configured, 'config api_key.' .. name
    end

    if name == 'anthropic' then
        return first_env({ 'ANTHROPIC_API_KEY' }), 'ANTHROPIC_API_KEY'
    elseif name == 'openai' then
        local env_key = first_env({ 'OPENAI_API_KEY' })
        if env_key then return env_key, 'OPENAI_API_KEY' end

        local auth_json = read_json_file(default_codex_auth_path())
        local codex_key = auth_json and first_path(auth_json, { 'OPENAI_API_KEY', 'api_key', 'apiKey' })
        if codex_key then return codex_key, 'Codex auth.json OPENAI_API_KEY' end
    end

    return nil, nil
end

local function resolve_oauth(config, name)
    local oauth = (config.oauth and config.oauth[name]) or {}
    local explicit = oauth.access_token or oauth.token
    if explicit and explicit ~= '' then
        return explicit, oauth.account_id, 'config oauth.' .. name .. '.access_token'
    end

    if name == 'anthropic' then
        local env_token = first_env({ 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_AUTH_TOKEN' })
        if env_token then return env_token, nil, 'CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_AUTH_TOKEN' end

        local credentials_path = oauth.credentials_path or default_claude_credentials_path()
        local credentials = read_json_file(credentials_path)
        local token = credentials and first_path(credentials, {
            'claudeAiOauth.accessToken',
            'claudeAiOauth.access_token',
            'accessToken',
            'access_token',
        })
        if token then return token, nil, credentials_path end
    elseif name == 'openai' then
        local env_token = first_env({ 'CODEX_AUTH_TOKEN', 'OPENAI_AUTH_TOKEN', 'CHATGPT_AUTH_TOKEN' })
        if env_token then return env_token, oauth.account_id, 'CODEX_AUTH_TOKEN/OPENAI_AUTH_TOKEN' end

        local auth_path = oauth.credentials_path or oauth.auth_path or default_codex_auth_path()
        local auth_json = read_json_file(auth_path)
        local token = auth_json and first_path(auth_json, {
            'access_token',
            'accessToken',
            'tokens.access_token',
            'tokens.accessToken',
            'tokens.access',
            'chatgpt.access_token',
            'chatgpt.accessToken',
        })
        local account_id = oauth.account_id or (auth_json and first_path(auth_json, {
            'account_id',
            'accountId',
            'chatgpt_account_id',
            'chatgptAccountId',
            'chatgpt.account_id',
            'chatgpt.accountId',
            'tokens.account_id',
            'tokens.accountId',
        }))
        if token then return token, account_id, auth_path end
    end

    return nil, nil, nil
end

function M.resolve(config, name)
    local configured_type = config.auth_type and config.auth_type[name]
    local auth_type = configured_type or 'api_key'

    if auth_type == 'auto' or auth_type == 'api_key' then
        local api_key, source = resolve_api_key(config, name)
        if api_key then
            if name == 'anthropic' then
                return {
                    type = 'api_key',
                    source = source,
                    headers = {
                        { 'x-api-key', api_key },
                    },
                }
            end
            return {
                type = 'api_key',
                source = source,
                headers = {
                    { 'Authorization', 'Bearer ' .. api_key },
                },
            }
        end
    end

    if auth_type == 'auto' or auth_type == 'oauth' or auth_type == 'subscription' or auth_type == 'codex' then
        local token, account_id, source = resolve_oauth(config, name)
        if token then
            local headers = {
                { 'Authorization', 'Bearer ' .. token },
            }
            if name == 'openai' then
                table.insert(headers, { 'User-Agent', 'codex-cli' })
                if account_id then
                    table.insert(headers, { 'ChatGPT-Account-Id', account_id })
                end
            end
            return {
                type = 'oauth',
                source = source,
                account_id = account_id,
                headers = headers,
            }
        end
    end

    local hint = 'Please set api_key.' .. name .. ' or configure auth_type.' .. name .. ' = "oauth" with a supported token.'
    if name == 'anthropic' then
        hint = hint .. ' Claude OAuth can use CLAUDE_CODE_OAUTH_TOKEN or ~/.claude/.credentials.json.'
    elseif name == 'openai' then
        hint = hint .. ' Codex OAuth can use CODEX_AUTH_TOKEN/OPENAI_AUTH_TOKEN or ~/.codex/auth.json.'
    end

    return nil, 'Error: ' .. name .. ' credentials not configured. ' .. hint
end

return M
