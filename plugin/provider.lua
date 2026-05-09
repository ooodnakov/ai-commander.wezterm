-- Provider abstraction for AI Commander.
--
-- Built-in providers live in plugin/providers/*.lua and are auto-discovered.
-- To add a new provider, create a file in plugin/providers/ that returns a
-- factory function with this signature:
--
--   return function(api_key, model, max_tokens, temperature)
--       return {
--           model            = model,
--           max_tokens       = max_tokens,
--           headers          = { { "Header-Name", "value" }, ... },
--           build_body       = function(system_message, messages) return { ... } end,
--           extract_response = function(response) return text_or_nil, err_string end,
--           stream_filter    = "grep ... | sed ... | jq ...",
--           body_template    = "'{ jq template with $model, $max_tokens, $sys, $msg }'",
--       }
--   end
--
-- Then add default api_url and model entries in config.lua.

local wezterm = require 'wezterm'

local M = {}

-- Provider modules: to add a new provider, create plugin/providers/<name>.lua
-- and add a require line here.
local providers = {
    anthropic = require('providers.anthropic'),
    openai = require('providers.openai'),
}

-- Resolve provider details from config, returns (details, api_url) or (nil, error_string)
local function resolve(config, opts)
    local name = config.provider or 'anthropic'
    local api_key = config.api_key[name]

    if not api_key or api_key == "" then
        return nil, "Error: " .. name
            .. " API key not configured. Please set api_key." .. name .. " in your .wezterm.lua config."
    end

    local factory = providers[name]
    if not factory then
        local available = {}
        for k, _ in pairs(providers) do table.insert(available, k) end
        return nil, "Error: Unsupported provider: " .. name
            .. ". Available: " .. table.concat(available, ", ")
    end

    local max_tokens = (opts and opts.max_tokens) or config.max_tokens
    local details = factory(api_key, config.model[name], max_tokens, config.temperature)
    return details, config.api_url[name]
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

    local curl_args = { "curl", "-s", "--max-time", "120", "-X", "POST" }
    for _, h in ipairs(details.headers) do
        table.insert(curl_args, "-H")
        table.insert(curl_args, h[1] .. ": " .. h[2])
    end
    table.insert(curl_args, api_url)
    table.insert(curl_args, "-d")
    table.insert(curl_args, json_body)

    local success, stdout, stderr = wezterm.run_child_process(curl_args)

    if not success then
        wezterm.log_error("HTTP request failed: " .. (stderr or "Unknown error"))
        callback("Error: HTTP request failed. " .. (stderr or "Unknown error"))
        return
    end

    local ok, response = pcall(wezterm.json_parse, stdout)
    if not ok then
        callback("Error: Failed to parse API response: " .. stdout:sub(1, 1500))
        return
    end

    if response.error then
        callback("API error: " .. (response.error.message or "Unknown error"))
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
-- Expects $QUESTION to be set in the calling script.
-- Returns: curl ... | sse_filter
function M.build_stream_cmd(config, system_prompt, opts)
    local details, api_url = resolve(config, opts)
    if not details then
        return 'echo ' .. wezterm.shell_quote_arg(api_url)
    end

    local header_lines = {}
    for _, h in ipairs(details.headers) do
        table.insert(header_lines, '  -H "' .. h[1] .. ': ' .. h[2] .. '" \\')
    end

    local jq_body = 'jq -n'
        .. ' --arg sys ' .. wezterm.shell_quote_arg(system_prompt)
        .. ' --arg msg "$QUESTION"'
        .. ' --arg model ' .. wezterm.shell_quote_arg(details.model)
        .. ' --argjson max_tokens ' .. tostring(details.max_tokens)
        .. ' ' .. details.body_template

    return table.concat({
        'curl -sN --max-time 120 -X POST \\',
        table.concat(header_lines, '\n'),
        '  ' .. wezterm.shell_quote_arg(api_url) .. ' \\',
        '  -d "$(' .. jq_body .. ')" \\',
        '  | ' .. details.stream_filter,
    }, '\n')
end

return M
