local wezterm = require 'wezterm'

local M = {}

-- Call AI API (supports both Anthropic and OpenAI)
-- Reads provider settings from the config table passed as parameter
function M.call(config, system_message, user_message, callback)
    local provider = config.provider or 'anthropic'
    local api_key = config.api_key[provider]

    if not api_key or api_key == "" then
        callback("Error: " ..
            provider .. " API key not configured. Please set api_key." .. provider .. " in your .wezterm.lua config.")
        return
    end

    local request_body, curl_args

    if provider == 'anthropic' then
        -- Create JSON request body for Anthropic API
        request_body = {
            model = config.model.anthropic,
            max_tokens = config.max_tokens,
            temperature = config.temperature,
            system = system_message,
            messages = {
                {
                    role = "user",
                    content = user_message
                }
            }
        }

        local json_body = wezterm.json_encode(request_body)

        -- Build curl arguments for Anthropic API
        curl_args = {
            "curl",
            "-s",
            "--max-time", "30",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "x-api-key: " .. api_key,
            "-H", "anthropic-version: 2023-06-01",
            config.api_url.anthropic,
            "-d", json_body
        }
    elseif provider == 'openai' then
        -- Create JSON request body for OpenAI API
        request_body = {
            model = config.model.openai,
            max_tokens = config.max_tokens,
            temperature = config.temperature,
            messages = {
                {
                    role = "system",
                    content = system_message
                },
                {
                    role = "user",
                    content = user_message
                }
            }
        }

        local json_body = wezterm.json_encode(request_body)

        -- Build curl arguments for OpenAI API
        curl_args = {
            "curl",
            "-s",
            "--max-time", "30",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "Authorization: Bearer " .. api_key,
            config.api_url.openai,
            "-d", json_body
        }
    else
        callback("Error: Unsupported provider: " .. provider)
        return
    end

    -- Make the HTTP request using wezterm.run_child_process
    local success, stdout, stderr = wezterm.run_child_process(curl_args)

    if not success then
        wezterm.log_error("HTTP request failed: " .. (stderr or "Unknown error"))
        callback("Error: HTTP request failed. " .. (stderr or "Unknown error"))
        return
    end

    -- Parse JSON response
    local ok, response = pcall(wezterm.json_parse, stdout)
    if not ok then
        callback("Error: Failed to parse API response: " .. stdout:sub(1, 1500))
        return
    end

    -- Handle API errors
    if response.error then
        local error_msg = "API error: " .. (response.error.message or "Unknown error")
        callback(error_msg)
        return
    end

    -- Extract content based on provider
    if provider == 'anthropic' then
        -- Anthropic API response format
        if response.content and #response.content > 0 and response.content[1].text then
            callback(response.content[1].text)
        else
            callback("Error: No content found in Anthropic API response")
        end
    elseif provider == 'openai' then
        -- OpenAI API response format
        if response.choices and #response.choices > 0 and response.choices[1].message and response.choices[1].message.content then
            callback(response.choices[1].message.content)
        else
            callback("Error: No content found in OpenAI API response")
        end
    end
end

return M
