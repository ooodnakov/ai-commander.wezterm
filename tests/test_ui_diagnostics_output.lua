package.path = './plugin/?.lua;./plugin/?/init.lua;./?.lua;./?/init.lua;' .. package.path

local sent_text = ''
local injected_output = ''
local toasts = {}

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
        action = {
            PromptInputLine = function(opts) return opts end,
            InputSelector = function(opts) return opts end,
        },
        action_callback = function(fn) return fn end,
        format = function(parts)
            local out = {}
            for _, part in ipairs(parts or {}) do
                if type(part) == 'table' and part.Text then out[#out + 1] = part.Text end
            end
            return table.concat(out)
        end,
        run_child_process = function() return false, false, '' end,
        log_warn = function() end,
        log_error = function() end,
        time = { call_after = function(_, callback) callback() end },
        on = function() end,
    }
end

package.preload['config'] = function()
    return {
        get = function() return {} end,
        validate = function() return {} end,
    }
end

package.preload['history'] = function()
    return { load = function() return {} end, save = function() end }
end

package.preload['provider'] = function()
    return {
        check = function()
            return { message = 'OK provider\nOK backend' }
        end,
        setup_backend = function()
            return { message = 'OK setup\nRequirement already satisfied: rich' }
        end,
    }
end

local pane = {
    send_text = function(_, text) sent_text = sent_text .. text end,
    inject_output = function(_, text) injected_output = injected_output .. text end,
}

local window = {
    mux_window = function() return { active_pane = function() return pane end } end,
    active_pane = function() return pane end,
    toast_notification = function(_, title, message)
        toasts[#toasts + 1] = title .. ':' .. message
    end,
}

local ui = require('ui')

ui.check_provider(window, pane)
ui.setup_backend(window, pane)

assert_equal(sent_text, '', 'diagnostics do not send output as terminal input')
assert_truthy(injected_output:find('# AI Commander Provider Check', 1, true), 'provider check uses pane output')
assert_truthy(injected_output:find('OK provider\r\nOK backend', 1, true), 'provider output is CRLF-normalized')
assert_truthy(injected_output:find('# AI Commander Backend Setup', 1, true), 'backend setup uses pane output')
assert_truthy(injected_output:find('Requirement already satisfied: rich', 1, true), 'setup output is displayed')
assert_equal(#toasts, 0, 'inject_output-capable pane does not warn')

print('ok')
