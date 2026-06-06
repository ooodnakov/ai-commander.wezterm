-- Provider abstraction for AI Commander.
--
-- Built-in providers live in plugin/providers/*.lua and are auto-discovered.
-- To add a new provider, create a file in plugin/providers/ that returns a
-- factory function with this signature:
--
--   return function(auth, model, max_tokens, temperature)
--       return {
--           model             = model,
--           max_tokens        = max_tokens,
--           headers           = { { "Header-Name", "value" }, ... },
--           -- Lua-side provider metadata used for config diagnostics.
--           -- Runtime API calls are handled by plugin/backend.py.
--       }
--   end
--
-- Then add default api_url and model entries in config.lua.

local wezterm = require 'wezterm'
local auth = require 'auth'

local M = {}

-- Provider modules: to add a new provider, create plugin/providers/<name>.lua
-- and add a require line here.
local providers = {
    anthropic = require('providers.anthropic'),
    openai = require('providers.openai'),
}

local function command_available(command)
    if not command or command == '' then return false end
    local ok, success = pcall(wezterm.run_child_process, { command, '--version' })
    return ok and success
end


local function file_exists(path)
    local f = io.open(path, 'r')
    if not f then return false end
    f:close()
    return true
end


local function append_output_lines(add, status, prefix, output)
    local any = false
    for line in ((output or '') .. '\n'):gmatch("([^\r\n]*)\r?\n") do
        if line ~= '' then
            add(status, prefix .. line)
            any = true
        end
    end
    return any
end

local function renderer_command(renderer)
    if not renderer or renderer == '' then return nil end
    return tostring(renderer):match('^(%S+)')
end

local function default_state_dir()
    local explicit = os.getenv('WEZTERM_AI_COMMANDER_STATE_DIR')
    if explicit and explicit ~= '' then return explicit end
    local xdg = os.getenv('XDG_STATE_HOME')
    if xdg and xdg ~= '' then return xdg .. '/ai-commander.wezterm' end
    if wezterm.home_dir then return wezterm.home_dir .. '/.local/state/ai-commander.wezterm' end
    return '.'
end

local function default_venv_path()
    if wezterm.home_dir then return wezterm.home_dir .. '/.local/share/ai-commander.wezterm/venv' end
    return './venv'
end

local function debug_dir()
    local explicit = os.getenv('WEZTERM_AI_COMMANDER_DEBUG_DIR')
    if explicit and explicit ~= '' then return explicit end
    return default_state_dir() .. '/debug'
end

local function readable(path)
    local file = io.open(path, 'r')
    if not file then return false end
    file:close()
    return true
end

local function search_module_path(module)
    if package.searchpath then
        local ok, path = pcall(package.searchpath, module, package.path)
        if ok and path then return path end
    end

    local module_path = module:gsub('%.', '/')
    for template in tostring(package.path or ''):gmatch('[^;]+') do
        local candidate = template:gsub('%?', module_path)
        if readable(candidate) then return candidate end
    end

    return nil
end

local function plugin_dir()
    local path = search_module_path('provider')
    if not path then return '.' end
    return path:match('^(.*)[/\\][^/\\]+$') or '.'
end

local function backend_path()
    return plugin_dir() .. '/backend.py'
end

local function write_temp_file(suffix, contents)
    local path = os.tmpname() .. suffix
    local file, err = io.open(path, 'w')
    if not file then
        return nil, 'Error: Failed to create temp file: ' .. tostring(err)
    end
    file:write(contents or '')
    file:close()
    return path
end

local function default_backend_python_candidates(config)
    local candidates = {}
    if config and config.backend_python and config.backend_python ~= '' then
        table.insert(candidates, tostring(config.backend_python))
    end

    local env_python = os.getenv('WEZTERM_AI_COMMANDER_BACKEND_PYTHON')
    if env_python and env_python ~= '' then
        table.insert(candidates, env_python)
    end

    table.insert(candidates, default_venv_path() .. '/bin/python')

    table.insert(candidates, 'python')
    table.insert(candidates, 'python3')
    return candidates
end

function M.resolve_backend(config)
    local candidates = default_backend_python_candidates(config)
    for _, candidate in ipairs(candidates) do
        local ok, success = pcall(wezterm.run_child_process, { candidate, '--version' })
        if ok and success then
            return candidate, backend_path()
        end
    end

    return nil, 'Error: Python backend requires python. Set backend_python, install ~/.local/share/ai-commander.wezterm/venv, or install python/python3.'
end

function M.write_temp_file(suffix, contents)
    return write_temp_file(suffix, contents)
end

-- Resolve provider details from config, returns (details, api_url, credential) or (nil, error_string)
local function resolve(config, opts)
    local name = config.provider or 'anthropic'
    local factory = providers[name]
    if not factory then
        local available = {}
        for k, _ in pairs(providers) do table.insert(available, k) end
        return nil, "Error: Unsupported provider: " .. name
            .. ". Available: " .. table.concat(available, ", ")
    end

    local credential, credential_err = auth.resolve(config, name)
    if not credential then
        return nil, credential_err
    end

    local max_tokens = (opts and opts.max_tokens) or config.max_tokens
    local details = factory(credential, config.model[name], max_tokens, config.temperature)

    local api_url = config.api_url[name]
    if credential.type == 'oauth' and config.subscription_api_url and config.subscription_api_url[name] then
        api_url = config.subscription_api_url[name]
    end

    return details, api_url, credential
end


-- Blocking backend call via wezterm.run_child_process (for command generation)
function M.call(config, system_message, user_message, callback, opts)
    local python, backend_or_err = M.resolve_backend(config)
    if not python then
        callback(backend_or_err)
        return
    end

    local backend_config = config or {}
    if opts and opts.max_tokens then
        backend_config = {}
        for key, value in pairs(config or {}) do backend_config[key] = value end
        backend_config.max_tokens = opts.max_tokens
    end

    local config_file, config_err = write_temp_file('_ai_commander_config.json', wezterm.json_encode(backend_config))
    if not config_file then
        callback('Error: Failed to write backend config: ' .. tostring(config_err))
        return
    end

    local system_file, system_err = write_temp_file('_ai_commander_system.txt', system_message or '')
    if not system_file then
        os.remove(config_file)
        callback('Error: Failed to write backend system prompt: ' .. tostring(system_err))
        return
    end

    local prompt_file, prompt_err = write_temp_file('_ai_commander_prompt.txt', user_message or '')
    if not prompt_file then
        os.remove(config_file)
        os.remove(system_file)
        callback('Error: Failed to write backend prompt: ' .. tostring(prompt_err))
        return
    end

    local success, stdout, stderr = wezterm.run_child_process({
        python, backend_or_err, 'generate',
        '--config', config_file,
        '--system', system_file,
        '--prompt', prompt_file,
    })

    os.remove(config_file)
    os.remove(system_file)
    os.remove(prompt_file)

    if success then
        callback(stdout or '')
        return
    end

    local message = stderr
    if not message or message == '' then message = stdout end
    if not message or message == '' then message = 'backend exited unsuccessfully' end
    wezterm.log_error('AI backend generate failed: ' .. tostring(message))
    callback('Error: AI backend generate failed. ' .. tostring(message))
end


function M.setup_backend(config, opts)
    local python = (config and config.setup_python and tostring(config.setup_python)) or 'python3'
    local backend = backend_path()
    if not file_exists(backend) then
        return {
            ok = false,
            message = 'Python backend not found: ' .. backend,
        }
    end

    local args = { python, backend, 'setup', '--venv', default_venv_path() }
    if opts and opts.no_install then table.insert(args, '--no-install') end
    if opts and opts.recreate then table.insert(args, '--recreate') end
    local child_ok, success, stdout, stderr = pcall(wezterm.run_child_process, args)
    local output = table.concat({ stdout or '', stderr or '' }, '\n')
    if not child_ok then
        return { ok = false, message = 'Backend setup could not start: ' .. tostring(success) }
    end
    return {
        ok = success and true or false,
        message = output ~= '' and output or 'backend setup produced no output',
        command = table.concat(args, ' '),
    }
end


function M.check(config, validation_warnings)
    local name = config.provider or 'anthropic'
    local lines = {}
    local ok = true

    local function add(status, message)
        table.insert(lines, status .. ' ' .. message)
        if status == '❌' then ok = false end
    end

    add('ℹ️', 'Provider: ' .. name)
    local model = config.model and config.model[name] or nil
    local auth_mode = config.auth_type and config.auth_type[name] or 'api_key'
    add('ℹ️', 'Model: ' .. tostring(model or '(unset)'))
    add('ℹ️', 'Token limits: max=' .. tostring(config.max_tokens or '(unset)') .. ', chat=' .. tostring(config.chat_max_tokens or '(unset)'))
    add('ℹ️', 'Configured auth mode: ' .. tostring(auth_mode))
    if os.getenv('WEZTERM_AI_COMMANDER_DEBUG') == '1' then
        add('ℹ️', 'Debug dir: ' .. debug_dir())
    end

    for _, warning in ipairs(validation_warnings or {}) do
        add('⚠️', warning)
    end

    local details, api_url, credential = resolve(config, { max_tokens = 1 })
    if details then
        add('✅', 'Credentials resolved with ' .. credential.type .. ' auth')
        add('ℹ️', 'Endpoint: ' .. tostring(api_url))
    else
        add('❌', api_url)
    end

    local python, backend_or_err = M.resolve_backend(config)
    if python then
        add('✅', 'Python backend interpreter found: ' .. python)
    else
        add('❌', backend_or_err)
    end

    local backend = python and backend_or_err or backend_path()
    if file_exists(backend) then
        add('✅', 'Python backend found: ' .. backend)
    else
        add('❌', 'Python backend not found: ' .. backend)
    end

    if python and file_exists(backend) then
        local temp_config, temp_err = write_temp_file('_ai_commander_config.json', wezterm.json_encode(config or {}))
        if temp_config then
            local child_ok, success, stdout, stderr = pcall(wezterm.run_child_process, {
                python, backend, 'check', '--config', temp_config,
            })
            os.remove(temp_config)

            local output = table.concat({ stdout or '', stderr or '' }, '\n')
            if child_ok and success then
                add('✅', 'Backend check passed')
                if not append_output_lines(add, 'ℹ️', 'backend: ', output) then
                    add('ℹ️', 'backend: no diagnostic output')
                end
            elseif child_ok then
                add('❌', 'Backend check failed')
                if not append_output_lines(add, 'ℹ️', 'backend: ', output) then
                    add('ℹ️', 'backend: no diagnostic output')
                end
            else
                add('❌', 'Backend check could not start: ' .. tostring(success))
            end
        else
            add('❌', 'Backend check could not write temp config: ' .. tostring(temp_err))
        end
    else
        add('ℹ️', 'requests/rich dependencies and endpoint reachability are checked by backend when Python backend is available')
    end

    local renderer = renderer_command(config.renderer)
    if not renderer or renderer == 'rich' then
        add('ℹ️', 'renderer: Python Rich markdown (requires backend dependencies)')
    elseif renderer == 'streamdown' then
        add('ℹ️', 'renderer optional: streamdown; raw markdown fallback remains available')
    elseif renderer == 'cat' then
        add('✅', 'renderer is cat')
    elseif command_available(renderer) then
        add('✅', 'renderer is available: ' .. renderer)
    else
        add('⚠️', 'configured renderer not found: ' .. tostring(renderer) .. ' (raw markdown fallback remains available)')
    end

    return {
        ok = ok,
        lines = lines,
        message = table.concat(lines, '\n'),
    }
end

return M
