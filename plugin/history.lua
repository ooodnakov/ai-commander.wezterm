local cfg = require 'config'

local M = {}

-- Load prompt history from file
function M.load()
    local config = cfg.get()
    local history = {}
    local file = io.open(config.history_file, 'r')
    if file then
        for line in file:lines() do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                table.insert(history, trimmed)
            end
        end
        file:close()
    end
    return history
end

-- Save prompt to history file (most recent first, deduplicated)
function M.save(prompt)
    local config = cfg.get()
    local history = M.load()

    -- Remove if already exists (move to front)
    for i, item in ipairs(history) do
        if item == prompt then
            table.remove(history, i)
            break
        end
    end

    -- Add to front
    table.insert(history, 1, prompt)

    -- Keep only max_history items
    while #history > config.max_history do
        table.remove(history)
    end

    -- Save to file
    local file = io.open(config.history_file, 'w')
    if file then
        for _, item in ipairs(history) do
            file:write(item .. '\n')
        end
        file:close()
    end
end

return M
