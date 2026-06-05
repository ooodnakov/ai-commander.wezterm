package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local split_script = nil
local stream_opts = nil

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
                renderer = 'streamdown',
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
        build_stream_cmd = function(_, _, opts)
            stream_opts = opts
            return 'printf %s "$QUESTION"'
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
        assert_truthy(opts.direction == 'Bottom', 'ask chat opens a bottom split')
        assert_truthy(opts.size == 0.5, 'ask chat uses configured split size')
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

local file = assert(io.open(split_script, 'r'))
local script = file:read('*a')
file:close()

assert_truthy(script:find('while true; do', 1, true), 'ask chat remains interactive')
assert_truthy(script:find('Ask AI>', 1, true), 'ask chat prompts inside the split pane')
assert_truthy(script:find('Renderer: %s', 1, true), 'ask chat prints the selected renderer')
assert_truthy(script:find('| streamdown', 1, true), 'ask chat pipes responses through streamdown')
assert_truthy(stream_opts and stream_opts.capture_events == true, 'ask chat captures stream events for state')
assert_truthy(script:find('jq -n -c', 1, true), 'ask chat updates history without waiting for stdin')
assert_truthy(script:find('HISTORY_JSON="$UPDATED_HISTORY"', 1, true), 'ask chat keeps history in the split pane')
assert_truthy(script:find('messages: $messages', 1, true), 'ask chat can persist messages when continuity is enabled')
assert_truthy(not script:find('TogglePaneZoomState', 1, true), 'ask chat does not zoom over existing panes')
assert_truthy(os.execute('bash -n ' .. shell_quote_arg(split_script)), 'generated ask chat script has valid bash syntax')

print('ok')
