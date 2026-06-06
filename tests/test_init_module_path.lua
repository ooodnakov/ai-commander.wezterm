package.path = './?.lua;./?/init.lua;' .. package.path

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end

local local_url = 'file:///home/odnakov/src/ai-commander.wezterm'
assert_equal(os.getenv('WEZTERM_AI_COMMANDER_PLUGIN_URL'), local_url, 'local plugin env')

package.preload['wezterm'] = function()
    return {
        home_dir = '/tmp',
        action = {},
        plugin = {
            list = function()
                return {
                    {
                        url = 'https://github.com/ooodnakov/ai-commander.wezterm',
                        plugin_dir = '/stale/remote/cache',
                    },
                    {
                        url = local_url,
                        plugin_dir = '.',
                    },
                }
            end,
        },
        format = function() return '' end,
        action_callback = function(fn) return fn end,
        shell_quote_arg = function(value) return tostring(value) end,
        run_child_process = function() return false, '', '' end,
        log_warn = function() end,
    }
end

package.loaded['ui'] = { stale = true }
package.loaded['config'] = { stale = true }

local plugin = require('plugin.init')

assert_equal(type(plugin.show_prompt), 'function', 'plugin loaded')
assert_equal(type(plugin.repeat_last_prompt), 'function', 'repeat-last API exported')
assert_equal(package.loaded.ui.stale, nil, 'stale ui module cleared')
assert_equal(package.loaded.config.stale, nil, 'stale config module cleared')
assert(package.path:find('./plugin/?.lua', 1, true), 'configured local plugin path is prepended')
assert(not package.path:find('/stale/remote/cache/plugin/?.lua', 1, true), 'remote cache is ignored when local URL is configured')

print('ok')
