package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local calls = {}

local function assert_truthy(value, label)
    if not value then error(label, 2) end
end

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end

package.preload['wezterm'] = function()
    return {
        home_dir = '/tmp',
        json_encode = function() return '{"provider":"openai"}' end,
        log_error = function() end,
        run_child_process = function(args)
            calls[#calls + 1] = args
            if args[2] and tostring(args[2]):find('backend.py', 1, true) and args[3] == 'check' then
                return true, 'INFO model: gpt-5.5\nINFO tokens: max=1 chat=16000\nOK dependency: requests 2.x', ''
            end
            return true, 'Python 3.12', ''
        end,
    }
end

package.preload['auth'] = function()
    return {
        resolve = function()
            return {
                type = 'oauth',
                headers = { { 'Authorization', 'Bearer should-not-print' } },
            }
        end,
    }
end

local provider = require('provider')
local report = provider.check({
    provider = 'openai',
    auth_type = { openai = 'oauth' },
    api_url = { openai = 'https://api.openai.com/v1/responses' },
    subscription_api_url = { openai = 'https://chatgpt.com/backend-api/codex/responses' },
    model = { openai = 'gpt-5.5' },
    max_tokens = 4000,
    chat_max_tokens = 16000,
    renderer = 'cat',
    temperature = 0.1,
}, {})

assert_truthy(report.ok, 'diagnostic report ok')
assert_truthy(report.message:find('Model: gpt-5.5', 1, true), 'provider check includes active model')
assert_truthy(report.message:find('Token limits: max=4000, chat=16000', 1, true), 'provider check includes token limits')
assert_truthy(not report.message:find('should-not-print', 1, true), 'provider check does not print auth token')

for _, args in ipairs(calls) do
    for _, arg in ipairs(args) do
        assert_truthy(arg ~= 'setup', 'check_provider does not auto-run setup')
        assert_truthy(arg ~= 'pip', 'check_provider does not auto-run pip')
    end
end

calls = {}
local setup = provider.setup_backend({}, { no_install = true })
assert_truthy(setup.message, 'setup_backend returns output')
assert_equal(calls[1][3], 'setup', 'setup_backend invokes explicit backend setup')
assert_truthy(setup.command:find('setup', 1, true), 'setup command recorded')
assert_truthy(setup.command:find('%-%-no%-install'), 'no-install passed')

print('ok')
