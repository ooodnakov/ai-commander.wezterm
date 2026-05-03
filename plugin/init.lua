-- AI Commander for WezTerm
-- Entry point: loads submodules and re-exports the public API

local cfg = require 'plugin.config'
local ui = require 'plugin.ui'

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

return M
