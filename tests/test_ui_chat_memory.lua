package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local split_script = nil

local function assert_truthy(value, label)
    if not value then error(label, 2) end
end

local function shell_quote_arg(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

package.preload['wezterm'] = function()
    return {
        home_dir = '/tmp',
        action = {},
        action_callback = function(fn) return fn end,
        shell_quote_arg = shell_quote_arg,
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
                conversation_continuity = false,
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
        build_stream_cmd = function()
            return 'printf "%s\\n" "$HISTORY_JSON"'
        end,
        check = function()
            return { message = 'ok' }
        end,
    }
end

local ui = require('ui')

local pane = {
    split = function(_, opts)
        split_script = opts.args[2]
        return {}
    end,
    send_text = function() end,
}

local window = {
    active_pane = function() return pane end,
    get_selection_text_for_pane = function() return '' end,
}

ui.show_ask_inline(window, pane)
assert_truthy(split_script, 'ask chat writes a script for the split pane')

local cmd = 'printf %s ' .. shell_quote_arg('first\nsecond\n/q\n') .. ' | bash ' .. shell_quote_arg(split_script)
local handle = assert(io.popen(cmd, 'r'))
local output = handle:read('*a')
local ok = handle:close()
assert_truthy(ok, 'generated chat script exits successfully')

assert_truthy(output:find('%[%]', 1, false), 'first turn sees empty history')
assert_truthy(output:find('"role":"user","content":"first"', 1, true), 'second turn sees previous user message')
assert_truthy(output:find('"role":"assistant","content":"[]', 1, true), 'second turn sees previous assistant message')

print('ok')
