-- AI Commander for WezTerm
-- Entry point: loads submodules and re-exports the public API

local wezterm = require 'wezterm'

-- Find this plugin's directory and add it to package.path so submodules can be required
local plugin_dir
for _, plugin in ipairs(wezterm.plugin.list()) do
    if plugin.url:find('ai%-commander') then
        plugin_dir = plugin.plugin_dir
        break
    end
end
if plugin_dir then
    package.path = plugin_dir .. '/plugin/?.lua;' .. package.path
end

local cfg = require 'config'
local ui = require 'ui'

local M = {}

-- Apply plugin configuration and merge with defaults
-- @param wezterm_config  The WezTerm config builder table
-- @param plugin_config   User-provided plugin options
function M.apply_to_config(wezterm_config, plugin_config)
    if plugin_config then
        -- Extract ui-specific options before passing to config module
        if plugin_config.max_results_history then
            ui.set_max_results_history(plugin_config.max_results_history)
            plugin_config.max_results_history = nil
        end
        cfg.apply(plugin_config)
    end
end

-- Show prompt input for generating new commands
function M.show_prompt(window, pane)
    ui.show_prompt(window, pane)
end

-- Show prompt history and re-run a selected prompt
function M.show_history(window, pane)
    ui.show_history(window, pane)
end

-- Show last AI-generated results for recall
function M.show_last_results(window, pane)
    ui.show_last_results(window, pane)
end

-- Ask AI a quick question (single-line input, streamed response via sd)
function M.show_ask_inline(window, pane)
    ui.show_ask_inline(window, pane)
end


return M
