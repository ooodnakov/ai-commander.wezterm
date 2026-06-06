package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local actions = {}
local timers = {}
local event_handlers = {}
local right_statuses = {}
local provider_called_after_waiting = false
local sent_text = ''
local completion_prompt = nil
local completion_mode = 'single'

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
        on = function(name, callback)
            event_handlers[name] = callback
        end,
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
        call = function(_, system, prompt, callback)
            if system:find('partially typed shell commands', 1, true) then
                completion_prompt = prompt
                if completion_mode == 'multi' then
                    callback(' --decorate')
                elseif completion_mode == 'middle' then
                    callback('ckout main')
                elseif completion_mode == 'error' then
                    callback('Error: provider timeout')
                else
                    callback(' status')
                end
                return
            end
            provider_called_after_waiting = actions[#actions] and actions[#actions].title == 'AI Commander · Generating Commands'
            callback('printf ok\n## Print ok\nprintf nope\n## Print nope')
        end,
        check = function()
            return { message = 'ok' }
        end,
    }
end

local ui = require('ui')
ui.setup_completion_indicator()
assert_truthy(event_handlers['update-status'], 'completion status registers update-status overlay')


local stale_pane = {
    send_text = function()
        error('pane id stale not found in mux')
    end,
}

local mux_pane = {
    send_text = function(_, text)
        sent_text = sent_text .. text
    end,
    get_cursor_position = function()
        return { x = 9, y = 10 }
    end,
    get_text_from_region = function(_, start_x, start_y, end_x, end_y)
        assert_equal(start_y, 10, 'completion reads cursor row')
        assert_equal(end_y, 10, 'completion reads only cursor row')
        if start_x == 0 then
            assert_truthy(end_x >= 1, 'completion uses cursor column')
            if completion_mode == 'multi' then
                return '> --oneline'
            end
            return '❯ git'
        end
        if completion_mode == 'middle' then
            return 'ckout main'
        end
        return ''
    end,
    get_dimensions = function()
        return { cols = 80 }
    end,
    get_lines_as_text = function()
        if completion_mode == 'multi' then
            return '❯ git log \\\n> --oneline'
        end
        return '❯ git'
    end,
    get_current_working_dir = function()
        return 'file:///home/odnakov/src/ai-commander.wezterm'
    end,
    get_foreground_process_name = function()
        return 'zsh'
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
    get_right_status = function()
        return right_statuses[#right_statuses] or ''
    end,
    set_right_status = function(_, value)
        right_statuses[#right_statuses + 1] = value
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

ui.complete_current_command(window, stale_pane)
assert_equal(#timers, 2, 'completion provider call is delayed so indicator can render')
assert_truthy(right_statuses[#right_statuses]:find('AI completing command', 1, true), 'completion shows working indicator')
window:set_right_status('normal status overwrite')
event_handlers['update-status'](window, mux_pane)
timers[3]()
assert_truthy(right_statuses[#right_statuses]:find('AI completing command', 1, true), 'completion indicator survives status refresh')
assert_truthy(right_statuses[#right_statuses]:find('normal status overwrite', 1, true), 'completion composes with existing right status')
timers[2]()
assert_truthy(completion_prompt:find('Editable command prefix %(may be multiline%):\ngit'), 'completion prompt strips shell prompt')
assert_equal(sent_text, 'printf okprintf nope status', 'completion appends only suffix')
assert_truthy(right_statuses[#right_statuses]:find('AI completion inserted', 1, true), 'completion shows inserted indicator')

completion_mode = 'multi'
ui.complete_current_command(window, stale_pane)
assert_equal(#timers, 4, 'multiline completion provider call is delayed')
timers[4]()
assert_truthy(completion_prompt:find('Editable command prefix %(may be multiline%):\ngit log \\\n%-%-oneline'), 'multiline completion includes prior command lines')
assert_equal(sent_text, 'printf okprintf nope status --decorate', 'multiline completion appends suffix')

completion_mode = 'middle'
ui.complete_current_command(window, stale_pane)
assert_equal(#timers, 5, 'middle completion provider call is delayed')
timers[5]()
assert_truthy(completion_prompt:find('Existing right%-of%-cursor text %(do not repeat%):\nckout main'), 'completion prompt includes right-of-cursor text')
assert_equal(sent_text, 'printf okprintf nope status --decorate', 'middle completion avoids duplicating right-side text')
assert_truthy(right_statuses[#right_statuses]:find('AI found no completion', 1, true), 'middle duplicate completion reports empty indicator')

completion_mode = 'error'
ui.complete_current_command(window, stale_pane)
assert_equal(#timers, 6, 'error completion provider call is delayed')
timers[6]()
assert_equal(sent_text, 'printf okprintf nope status --decorate', 'error completion sends no text')
assert_truthy(right_statuses[#right_statuses]:find('AI completion failed', 1, true), 'completion error shows error indicator')

print('ok')
