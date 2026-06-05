package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local actions = {}
local timers = {}
local provider_called_after_waiting = false
local sent_text = ''

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
        time = {
            call_after = function(_, callback)
                timers[#timers + 1] = callback
            end,
        },
    }
end

package.preload['config'] = function()
    return {
        get = function()
            return {
                command_count = 2,
                system_prompt = 'system',
                provider = 'openai',
                max_tokens = 100,
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
        call = function(_, _, _, callback)
            provider_called_after_waiting = actions[#actions] and actions[#actions].title == 'AI Commander · Generating Commands'
            callback('printf ok\n## Print ok\nprintf nope\n## Print nope')
        end,
        check = function()
            return { message = 'ok' }
        end,
    }
end

local ui = require('ui')

local stale_pane = {
    send_text = function()
        error('pane id stale not found in mux')
    end,
}

local mux_pane = {
    send_text = function(_, text)
        sent_text = sent_text .. text
    end,
}

local window = {
    active_pane = function() return stale_pane end,
    mux_window = function()
        return {
            active_pane = function() return mux_pane end,
        }
    end,
    get_selection_text_for_pane = function(_, pane)
        assert_equal(pane, mux_pane, 'selection reads mux active pane, not overlay pane')
        return 'ctx'
    end,
    perform_action = function(_, action, pane)
        assert_equal(pane, mux_pane, 'actions target mux active pane')
        actions[#actions + 1] = action
    end,
}

ui.show_prompt(window, stale_pane)
assert_equal(actions[1].kind, 'PromptInputLine', 'first action opens prompt input')
assert_truthy(actions[1].description:find('AI Commander', 1, true), 'prompt input has branded description')
assert_truthy(actions[1].description:find('selected context: on', 1, true), 'prompt input shows context state')
assert_truthy(actions[1].prompt:find('❯', 1, true), 'prompt input has fancy prompt marker')
assert_truthy(not actions[1].description:find('\n', 1, true), 'prompt input is compact single-line UI')

actions[1].action(window, stale_pane, 'print hello')
assert_equal(actions[2].kind, 'InputSelector', 'prompt callback shows waiting selector')
assert_equal(actions[2].title, 'AI Commander · Generating Commands', 'waiting selector title')
assert_truthy(actions[2].description:find('Waiting for provider response', 1, true), 'waiting selector description')
assert_equal(#timers, 1, 'provider call is delayed so waiting UI can render')

timers[1]()
assert_truthy(provider_called_after_waiting, 'provider starts after waiting selector is visible')
assert_equal(actions[3].kind, 'InputSelector', 'provider callback replaces waiting selector with command selector')
assert_equal(actions[3].title, 'AI Commander · Choose Command', 'command selector title')
assert_truthy(actions[3].description:find('multiline commands show', 1, true), 'command selector explains badges')
assert_equal(#actions[3].choices, 2, 'command selector has parsed choices')
assert_truthy(not actions[3].choices[1].label:find('1%.', 1), 'choice label does not duplicate selector numbering')

actions[3].action(window, stale_pane, '1')
assert_equal(sent_text, 'printf ok', 'selector pastes chosen command')

ui.show_last_results(window, stale_pane)
assert_equal(actions[4].title, 'AI Commander · Previous Results', 'previous results selector title')
actions[4].action(window, stale_pane, '2')
assert_equal(sent_text, 'printf okprintf nope', 'previous results selector uses mux active pane')

print('ok')
