package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local split_opts = nil

local function assert_truthy(value, label)
    if not value then error(label, 2) end
end

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end

local function shell_quote_arg(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function encode_json(value)
    if type(value) ~= 'table' then return '"' .. tostring(value) .. '"' end

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
    return '{' .. table.concat(parts, ',') .. '}'
end

package.preload['wezterm'] = function()
    return {
        home_dir = '/tmp',
        action = {},
        action_callback = function(fn) return fn end,
        shell_quote_arg = shell_quote_arg,
        json_encode = encode_json,
        format = function() return '' end,
        log_warn = function() end,
        log_error = function() end,
        run_child_process = function() return false, '', '' end,
    }
end

package.preload['config'] = function()
    return {
        get = function()
            return {
                provider = 'openai',
                renderer = 'cat',
                chat_pane_size = 0.5,
                chat_system_prompt = 'chat system',
                chat_max_tokens = 1000,
                conversation_continuity = true,
                conversation_state_file = '/tmp/ai_state.json',
                max_conversation_messages = 12,
            }
        end,
        validate = function() return {} end,
    }
end

package.preload['history'] = function()
    return { save = function() end, load = function() return {} end }
end

package.preload['provider'] = function()
    return {
        resolve_backend = function()
            return 'python3', '/tmp/backend.py'
        end,
        write_temp_file = function(suffix, contents)
            local path = os.tmpname() .. suffix
            local file = assert(io.open(path, 'w'))
            file:write(contents or '')
            file:close()
            return path
        end,
        check = function()
            return { message = 'ok' }
        end,
    }
end

local ui = require('ui')

local pane = {
    split = function(_, opts)
        split_opts = opts
        assert_equal(opts.direction, 'Bottom', 'ask chat opens a bottom split')
        assert_equal(opts.size, 0.5, 'ask chat uses configured split size')
        return {}
    end,
    send_text = function() end,
}

local window = {
    active_pane = function() return pane end,
    get_selection_text_for_pane = function() return '' end,
}

local function arg_after(args, flag)
    for index, arg in ipairs(args) do
        if arg == flag then return args[index + 1] end
    end
end

ui.show_ask_inline(window, pane)
assert_truthy(split_opts, 'ask chat spawns a split pane')

local args = split_opts.args
local joined_args = table.concat(args, ' ')
assert_truthy(joined_args:find('python', 1, true), 'ask chat spawns Python')
assert_truthy(joined_args:find('backend.py', 1, true), 'ask chat invokes backend.py')
assert_truthy(joined_args:find(' chat ', 1, true) or args[3] == 'chat', 'ask chat uses backend chat command')
assert_truthy(not joined_args:find('bash', 1, true), 'ask chat memory does not require bash')
assert_truthy(not joined_args:find('jq', 1, true), 'ask chat memory does not require jq')
assert_truthy(not joined_args:find('curl', 1, true), 'ask chat memory does not require curl')
assert_truthy(not joined_args:find('|', 1, true), 'ask chat memory does not use a shell pipeline')

local config_file = assert(io.open(arg_after(args, '--config'), 'r'))
local config_json = config_file:read('*a')
config_file:close()
assert_truthy(config_json:find('"conversation_continuity":true', 1, true), 'backend receives continuity flag')
assert_truthy(config_json:find('"conversation_state_file":"/tmp/ai_state.json"', 1, true), 'backend receives memory state path')
assert_truthy(config_json:find('"max_conversation_messages":12', 1, true), 'backend receives memory window size')

local context_file = assert(io.open(arg_after(args, '--context'), 'r'))
local context = context_file:read('*a')
context_file:close()
assert_equal(context, '', 'backend receives empty context when nothing selected')

print('ok')
