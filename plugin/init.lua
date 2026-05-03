-- AI Commander for WezTerm
-- Entry point: loads submodules and re-exports the public API

-- Resolve the plugin directory from this file's location
local this_dir = debug.getinfo(1, 'S').source:match('@?(.*/)') or './'

-- Cached dofile loader to ensure each module is loaded only once (singleton)
local _loaded = {}
local function load_module(name)
    if not _loaded[name] then
        _loaded[name] = dofile(this_dir .. name .. '.lua')
    end
    return _loaded[name]
end

-- Store the loader globally so submodules can use it
_G._ai_commander_load = load_module

local cfg = load_module('config')
local ui = load_module('ui')

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
