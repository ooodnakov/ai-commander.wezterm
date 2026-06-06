package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local actions = {}
local timers = {}
local sent_text = ''
local provider_prompts = {}
local saved_prompts = {}

local function assert_truthy(value, label)
    if not value then error(label, 2) end
end

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end

local function make_action(kind)
    return function(opts)
        opts.kind = kind
        return opts
    end
end

package.preload['wezterm'] = function()
    return {
        action = {
            PromptInputLine = make_action('PromptInputLine'),
            InputSelector = make_action('InputSelector'),
        },
        action_callback = function(fn) return fn end,
        format = function(parts)
            local out = {}
            for _, part in ipairs(parts) do
                if type(part) == 'table' and part.Text then out[#out + 1] = part.Text end
            end
            return table.concat(out)
        end,
        run_child_process = function() return false, false, '' end,
        log_warn = function() end,
        log_error = function() end,
        time = { call_after = function(_, callback) timers[#timers + 1] = callback end },
        on = function() end,
    }
end

package.preload['config'] = function()
    return {
        get = function()
            return { command_count = 2, system_prompt = 'system', max_tokens = 100 }
        end,
        validate = function() return {} end,
    }
end

local history_items = { 'old destructive prompt' }
package.preload['history'] = function()
    return {
        load = function() return history_items end,
        save = function(prompt) saved_prompts[#saved_prompts + 1] = prompt end,
    }
end

package.preload['provider'] = function()
    return {
        call = function(_, _, prompt, callback)
            provider_prompts[#provider_prompts + 1] = prompt
            callback('rm -rf /tmp/ai-commander-test\n## Remove temp directory\nprintf safe\n## Print safe')
        end,
        check = function() return { message = 'ok' } end,
    }
end

local pane = {
    send_text = function(_, text) sent_text = sent_text .. text end,
    get_cursor_position = function() return { x = 12, y = 3 } end,
    get_text_from_region = function() return '❯ git status' end,
    get_lines_as_text = function() return '❯ git status' end,
    get_current_working_dir = function() return 'file:///tmp/project%20space' end,
    get_foreground_process_name = function() return '/bin/zsh' end,
}

local window = {
    mux_window = function() return { active_pane = function() return pane end } end,
    active_pane = function() return pane end,
    get_selection_text_for_pane = function() return 'selected error text' end,
    perform_action = function(_, action) actions[#actions + 1] = action end,
}

local ui = require('ui')

ui.show_history(window, pane)
assert_equal(actions[1].title, 'AI Commander · Prompt History', 'history opens selector')
actions[1].action(window, pane, '1')
assert_equal(actions[2].kind, 'PromptInputLine', 'history selection opens editable prompt')
assert_equal(actions[2].initial_value, 'old destructive prompt', 'history prompt is seeded')
assert_equal(#provider_prompts, 0, 'history selection does not call provider before submit')

actions[2].action(window, pane, 'edited prompt')
assert_equal(actions[3].title, 'AI Commander · Generating Commands', 'edited history submit shows waiting selector')
assert_equal(#timers, 1, 'edited history submit schedules provider')
timers[1]()
assert_truthy(provider_prompts[1]:find('Task: edited prompt', 1, true), 'edited prompt is sent to provider')
assert_truthy(provider_prompts[1]:find('Selected terminal text:\nselected error text', 1, true), 'selected context is included')
assert_truthy(provider_prompts[1]:find('Current working directory: /tmp/project space', 1, true), 'cwd shell context is included')
assert_truthy(provider_prompts[1]:find('Foreground process/shell: zsh', 1, true), 'foreground shell context is included')
assert_truthy(provider_prompts[1]:find('Stripped current command line: git status', 1, true), 'current command line context is included')
assert_equal(saved_prompts[1], 'edited prompt', 'edited history prompt is saved')

assert_equal(actions[4].title, 'AI Commander · Choose Command', 'generated commands open selector')
actions[4].action(window, pane, '1')
assert_equal(actions[5].title, 'AI Commander · Confirm Dangerous Command', 'dangerous command requires confirmation')
assert_equal(sent_text, '', 'dangerous command is not inserted before confirmation')
actions[5].action(window, pane, 'cancel')
assert_equal(sent_text, '', 'dangerous command cancel keeps pane unchanged')
actions[5].action(window, pane, 'insert')
assert_equal(sent_text, 'rm -rf /tmp/ai-commander-test', 'dangerous command inserts only after explicit confirmation')

ui.repeat_last_prompt(window, pane)
assert_equal(actions[6].title, 'AI Commander · Generating Commands', 'repeat-last skips edit UI')
assert_equal(#timers, 2, 'repeat-last schedules provider with current context')
timers[2]()
assert_truthy(provider_prompts[2]:find('Task: old destructive prompt', 1, true), 'repeat-last uses most recent history prompt')
assert_equal(#saved_prompts, 1, 'repeat-last does not duplicate history entry')

print('ok')
