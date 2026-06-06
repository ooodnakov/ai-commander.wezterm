-- AI Commander for WezTerm
-- Entry point: loads submodules and re-exports the public API

local wezterm = require 'wezterm'

local function configured_plugin_url()
    local url = os.getenv('WEZTERM_AI_COMMANDER_PLUGIN_URL')
    if url and url ~= '' then return url end
    return 'https://github.com/ooodnakov/ai-commander.wezterm'
end

local plugin_dir
local plugin_url = configured_plugin_url()
for _, plugin in ipairs(wezterm.plugin.list()) do
    if plugin.url == plugin_url then
        plugin_dir = plugin.plugin_dir
        break
    end
end

if not plugin_dir then
    for _, plugin in ipairs(wezterm.plugin.list()) do
        if plugin.url:find('ai%-commander') then
            plugin_dir = plugin.plugin_dir
            break
        end
    end
end

if plugin_dir then
    package.path = plugin_dir .. '/plugin/?.lua;' .. plugin_dir .. '/plugin/?/init.lua;' .. package.path
end

for _, module in ipairs({
    'config',
    'ui',
    'history',
    'provider',
    'auth',
    'providers.openai',
    'providers.anthropic',
}) do
    package.loaded[module] = nil
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
    ui.setup_completion_indicator()
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

-- Open an interactive split-pane AI chat with streaming markdown rendering
function M.show_ask_inline(window, pane)
    ui.show_ask_inline(window, pane)
end

-- Complete the current shell command line in-place
function M.complete_current_command(window, pane)
    ui.complete_current_command(window, pane)
end

-- Validate provider configuration and local dependencies
function M.check_provider(window, pane)
    return ui.check_provider(window, pane)
end


return M
