package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local last_args = nil
local encoded_config = nil
local json_depth = 0

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end

local function assert_truthy(value, label)
    if not value then error(label, 2) end
end

local function shell_quote_arg(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function encode_json(value)
    if json_depth == 0 then encoded_config = value end
    if type(value) ~= 'table' then return '"' .. tostring(value) .. '"' end

    json_depth = json_depth + 1
    local parts = {}
    for key, item in pairs(value) do
        local encoded
        if type(item) == 'string' then
            encoded = '"' .. item:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
        elseif type(item) == 'table' then
            encoded = encode_json(item)
        else
            encoded = tostring(item)
        end
        parts[#parts + 1] = '"' .. tostring(key) .. '":' .. encoded
    end
    json_depth = json_depth - 1
    return '{' .. table.concat(parts, ',') .. '}'
end

package.preload['wezterm'] = function()
    return {
        home_dir = '/tmp',
        json_encode = encode_json,
        shell_quote_arg = shell_quote_arg,
        log_error = function() end,
        run_child_process = function(args)
            last_args = args
            return true, 'printf ok\n## Print ok', ''
        end,
    }
end

package.preload['auth'] = function()
    return {
        resolve = function()
            return {
                type = 'oauth',
                headers = { { 'Authorization', 'Bearer test' } },
            }
        end,
    }
end

local original_debug = debug
debug = nil

local provider = require('provider')
debug = original_debug

local callback_text = nil
provider.call({
    provider = 'openai',
    api_url = { openai = 'https://api.openai.com/v1/responses' },
    subscription_api_url = { openai = 'https://chatgpt.com/backend-api/codex/responses' },
    model = { openai = 'gpt-5.5' },
    max_tokens = 200,
    temperature = 0.1,
}, 'sys', 'prompt', function(text)
    callback_text = text
end)

assert_equal(callback_text, 'printf ok\n## Print ok', 'backend stdout is streamed to callback')
assert_truthy(type(last_args) == 'table', 'provider calls backend with argv table')

local function has_arg(value)
    for _, arg in ipairs(last_args) do
        if arg == value then return true end
    end
    return false
end

local joined_args = table.concat(last_args, ' ')
assert_truthy(joined_args:find('python', 1, true), 'provider spawns Python')
assert_truthy(joined_args:find('backend.py', 1, true), 'provider invokes backend.py')
assert_truthy(joined_args:find(' generate ', 1, true) or last_args[3] == 'generate', 'provider uses backend generate command')
assert_truthy(joined_args:find('--config', 1, true), 'provider passes config temp file')
assert_truthy(joined_args:find('--system', 1, true), 'provider passes system temp file')
assert_truthy(joined_args:find('--prompt', 1, true), 'provider passes prompt temp file')
assert_truthy(not has_arg('curl'), 'provider core path does not require curl')
assert_truthy(not has_arg('bash'), 'provider core path does not require bash')
assert_truthy(not has_arg('jq'), 'provider core path does not require jq')
assert_truthy(not has_arg('|'), 'provider core path does not build shell pipeline')

assert_truthy(encoded_config, 'provider writes backend config')
assert_equal(encoded_config.provider, 'openai', 'backend config provider')
assert_equal(encoded_config.model.openai, 'gpt-5.5', 'backend config model')
assert_equal(encoded_config.max_tokens, 200, 'backend config max tokens')
assert_equal(encoded_config.temperature, 0.1, 'backend config temperature')

print('ok')
