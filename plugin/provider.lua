-- Provider abstraction for AI Commander.
--
-- Built-in providers live in plugin/providers/*.lua and are auto-discovered.
-- To add a new provider, create a file in plugin/providers/ that returns a
-- factory function with this signature:
--
--   return function(auth, model, max_tokens, temperature)
--       return {
--           model             = model,
--           max_tokens        = max_tokens,
--           headers           = { { "Header-Name", "value" }, ... },
--           build_body        = function(system_message, messages) return { ... } end,
--           extract_response  = function(response) return text_or_nil, err_string end,
--           stream_filter     = "grep ... | sed ... | jq ...",
--           body_template     = "'{ jq template with $model, $max_tokens, $sys, $msg }'",
--           conversation_mode = "previous_response_id" or "messages" or nil,
--       }
--   end
--
-- Then add default api_url and model entries in config.lua.

local wezterm = require 'wezterm'
local auth = require 'auth'

local M = {}

-- Provider modules: to add a new provider, create plugin/providers/<name>.lua
-- and add a require line here.
local providers = {
    anthropic = require('providers.anthropic'),
    openai = require('providers.openai'),
}

local function command_available(command)
    local success = wezterm.run_child_process({ 'sh', '-lc', 'command -v ' .. wezterm.shell_quote_arg(command) .. ' >/dev/null 2>&1' })
    return success
end

local function renderer_command(renderer)
    if not renderer or renderer == '' then return nil end
    return tostring(renderer):match('^(%S+)')
end

-- Resolve provider details from config, returns (details, api_url, credential) or (nil, error_string)
local function resolve(config, opts)
    local name = config.provider or 'anthropic'
    local factory = providers[name]
    if not factory then
        local available = {}
        for k, _ in pairs(providers) do table.insert(available, k) end
        return nil, "Error: Unsupported provider: " .. name
            .. ". Available: " .. table.concat(available, ", ")
    end

    local credential, credential_err = auth.resolve(config, name)
    if not credential then
        return nil, credential_err
    end

    local max_tokens = (opts and opts.max_tokens) or config.max_tokens
    local details = factory(credential, config.model[name], max_tokens, config.temperature)

    local api_url = config.api_url[name]
    if credential.type == 'oauth' and config.subscription_api_url and config.subscription_api_url[name] then
        api_url = config.subscription_api_url[name]
    end

    return details, api_url, credential
end

local function append_headers(curl_args, headers)
    for _, h in ipairs(headers) do
        table.insert(curl_args, '-H')
        table.insert(curl_args, h[1] .. ': ' .. h[2])
    end
end

-- Blocking API call via wezterm.run_child_process (for command generation)
function M.call(config, system_message, user_message, callback, opts)
    local details, api_url = resolve(config, opts)
    if not details then
        callback(api_url)
        return
    end

    local messages = {{ role = "user", content = user_message }}
    local body = details.build_body(system_message, messages)
    local json_body = wezterm.json_encode(body)

    local curl_args = { 'curl', '-s', '--max-time', '120', '-X', 'POST' }
    append_headers(curl_args, details.headers)
    table.insert(curl_args, api_url)
    table.insert(curl_args, '-d')
    table.insert(curl_args, json_body)

    local success, stdout, stderr = wezterm.run_child_process(curl_args)

    if not success then
        wezterm.log_error('HTTP request failed: ' .. (stderr or 'Unknown error'))
        callback('Error: HTTP request failed. ' .. (stderr or 'Unknown error'))
        return
    end

    local ok, response = pcall(wezterm.json_parse, stdout)
    if not ok then
        callback('Error: Failed to parse API response: ' .. stdout:sub(1, 1500))
        return
    end

    if response.error then
        callback('API error: ' .. (response.error.message or 'Unknown error'))
        return
    end

    local text, extract_err = details.extract_response(response)
    if text then
        callback(text)
    else
        callback(extract_err)
    end
end

-- Build a bash streaming curl pipeline string.
-- Expects $QUESTION, $PREVIOUS_RESPONSE_ID, and $HISTORY_JSON to be set in the calling script.
-- Returns: curl ... | optional tee | sse_filter
function M.build_stream_cmd(config, system_prompt, opts)
    opts = opts or {}
    local details, api_url = resolve(config, opts)
    if not details then
        return 'echo ' .. wezterm.shell_quote_arg(api_url)
    end

    local header_lines = {}
    for _, h in ipairs(details.headers) do
        table.insert(header_lines, '  -H ' .. wezterm.shell_quote_arg(h[1] .. ': ' .. h[2]) .. ' \\')
    end

    local jq_body = 'jq -n'
        .. ' --arg sys ' .. wezterm.shell_quote_arg(system_prompt)
        .. ' --arg msg "$QUESTION"'
        .. ' --arg model ' .. wezterm.shell_quote_arg(details.model)
        .. ' --arg previous_response_id "$PREVIOUS_RESPONSE_ID"'
        .. ' --argjson history "$HISTORY_JSON"'
        .. ' --argjson max_tokens ' .. tostring(details.max_tokens)
        .. ' --argjson temperature ' .. tostring(config.temperature or 0.1)
        .. ' ' .. details.body_template

    local capture = ''
    if opts.capture_events then
        capture = '  | tee "$EVENTS" \\\n'
    end

    return table.concat({
        'curl -sN --max-time 120 -X POST \\',
        table.concat(header_lines, '\n'),
        '  ' .. wezterm.shell_quote_arg(api_url) .. ' \\',
        '  -d "$(' .. jq_body .. ')" \\',
        capture .. '  | ' .. details.stream_filter,
    }, '\n')
end

function M.check(config, validation_warnings)
    local name = config.provider or 'anthropic'
    local lines = {}
    local ok = true

    local function add(status, message)
        table.insert(lines, status .. ' ' .. message)
        if status == '❌' then ok = false end
    end

    add('ℹ️', 'Provider: ' .. name)

    for _, warning in ipairs(validation_warnings or {}) do
        add('⚠️', warning)
    end

    local details, api_url, credential = resolve(config, { max_tokens = 1 })
    if details then
        add('✅', 'Credentials resolved with ' .. credential.type .. ' auth')
        add('ℹ️', 'Endpoint: ' .. tostring(api_url))
    else
        add('❌', api_url)
    end

    if command_available('curl') then
        add('✅', 'curl is available')
    else
        add('❌', 'curl is not available')
    end

    if command_available('jq') then
        add('✅', 'jq is available')
    else
        add('❌', 'jq is not available; streaming ask mode requires jq')
    end

    local renderer = renderer_command(config.renderer or 'sd')
    if renderer == 'cat' then
        add('✅', 'renderer is cat')
    elseif renderer and command_available(renderer) then
        add('✅', 'renderer is available: ' .. renderer)
    else
        add('⚠️', 'renderer not found: ' .. tostring(renderer) .. ' (set renderer = "cat" for plain text)')
    end

    if details and api_url and command_available('curl') then
        local success, stdout = wezterm.run_child_process({
            'curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}',
            '--connect-timeout', '5', '--max-time', '10', api_url,
        })
        if success then
            local code = tonumber(stdout)
            if code and code >= 200 and code < 500 then
                add('✅', 'endpoint is reachable (HTTP ' .. tostring(code) .. ')')
            elseif code and code >= 500 then
                add('⚠️', 'endpoint responded with server error HTTP ' .. tostring(code))
            else
                add('⚠️', 'endpoint returned unexpected HTTP status: ' .. tostring(stdout))
            end
        else
            add('❌', 'endpoint reachability check failed')
        end
    end

    return {
        ok = ok,
        lines = lines,
        message = table.concat(lines, '\n'),
    }
end

return M
