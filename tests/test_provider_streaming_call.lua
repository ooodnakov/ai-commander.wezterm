package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local last_body = nil
local last_args = nil

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end

local function unescape_json_string(value)
    return (value or ''):gsub('\\n', '\n'):gsub('\\"', '"')
end

package.preload['wezterm'] = function()
    return {
        json_encode = function(value)
            last_body = value
            return '{}'
        end,
        json_parse = function(raw)
            if raw:find('response.output_text.delta', 1, true) then
                return {
                    type = 'response.output_text.delta',
                    delta = unescape_json_string(raw:match('"delta"%s*:%s*"(.-)"')),
                }
            end
            if raw:find('response.completed', 1, true) then
                return { type = 'response.completed', response = { output = {} } }
            end
            error('unexpected json_parse input: ' .. tostring(raw))
        end,
        shell_quote_arg = function(value)
            return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
        end,
        log_error = function() end,
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

local provider = require('provider')

package.loaded['wezterm'].run_child_process = function(args)
    last_args = args
    return true, table.concat({
        'data: {"type":"response.output_text.delta","delta":"printf ok"}',
        'data: {"type":"response.output_text.delta","delta":"\\n## Print ok"}',
        'data: {"type":"response.completed","response":{"status":"completed","output":[]}}',
        'data: [DONE]',
    }, '\n'), ''
end

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

assert_equal(last_body.stream, true, 'codex subscription calls stream')
assert_equal(last_body.store, false, 'codex subscription disables response storage')
assert_equal(last_body.max_output_tokens, nil, 'codex subscription omits public max_output_tokens')
assert_equal(last_body.temperature, nil, 'codex subscription omits public temperature')
assert_equal(last_body.reasoning, nil, 'codex subscription omits public reasoning')
assert_equal(callback_text, 'printf ok\n## Print ok', 'streamed delta text')

local has_no_buffer = false
for _, arg in ipairs(last_args) do
    if arg == '-N' then has_no_buffer = true end
end
assert_equal(has_no_buffer, true, 'curl disables buffering for stream')

local stream_cmd = provider.build_stream_cmd({
    provider = 'openai',
    api_url = { openai = 'https://api.openai.com/v1/responses' },
    subscription_api_url = { openai = 'https://chatgpt.com/backend-api/codex/responses' },
    model = { openai = 'gpt-5.5' },
    max_tokens = 200,
    temperature = 0.1,
}, 'sys')

assert_equal(stream_cmd:find('max_output_tokens', 1, true), nil, 'ask mode omits public max_output_tokens')
assert_equal(stream_cmd:find('temperature', 1, true), nil, 'ask mode omits public temperature')
assert_equal(stream_cmd:find('previous_response_id', 1, true), nil, 'ask mode does not use unsupported previous_response_id')
assert(stream_cmd:find('input: ($history +', 1, true), 'ask mode sends accumulated chat history')
assert(stream_cmd:find('store: false', 1, true), 'ask mode disables response storage')

print('ok')
