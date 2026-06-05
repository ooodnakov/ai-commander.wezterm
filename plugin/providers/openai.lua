local function as_text(content)
    if type(content) == 'string' then return content end
    if type(content) == 'table' then
        local parts = {}
        for _, part in ipairs(content) do
            if type(part) == 'string' then
                table.insert(parts, part)
            elseif type(part) == 'table' and part.text then
                table.insert(parts, part.text)
            end
        end
        if #parts > 0 then return table.concat(parts, '') end
    end
    return nil
end

local function non_empty_string(value)
    return type(value) == 'string' and value:match('%S') ~= nil
end

local function append_text(parts, value)
    if non_empty_string(value) then table.insert(parts, value) end
end

local function reasoning_effort_for_model(model)
    if type(model) ~= 'string' then return nil end
    if model:match('^gpt%-5') or model:match('^o%d') then return 'low' end
    return nil
end


local function extract_responses_text(response)
    if type(response) ~= 'table' then return nil end
    if non_empty_string(response.output_text) then return response.output_text end

    if type(response.output) ~= 'table' then return nil end

    local parts = {}
    for _, item in ipairs(response.output) do
        if type(item) == 'table' and (item.type == nil or item.type == 'message') and type(item.content) == 'table' then
            for _, content in ipairs(item.content) do
                if type(content) == 'string' then
                    append_text(parts, content)
                elseif type(content) == 'table' and (content.type == nil or content.type == 'output_text') then
                    append_text(parts, content.text or content.output_text)
                end
            end
        end
    end

    if #parts > 0 then return table.concat(parts, '') end
    return nil
end

local function extract_refusal(response)
    if type(response) ~= 'table' or type(response.output) ~= 'table' then return nil end

    for _, item in ipairs(response.output) do
        if type(item) == 'table' and (item.type == nil or item.type == 'message') and type(item.content) == 'table' then
            for _, content in ipairs(item.content) do
                if type(content) == 'table' and content.type == 'refusal' and non_empty_string(content.refusal) then
                    return content.refusal
                end
            end
        end
    end

    return nil
end

local function output_item_summary(response)
    if type(response) ~= 'table' or type(response.output) ~= 'table' then return nil end

    local items = {}
    for _, item in ipairs(response.output) do
        if type(item) == 'table' then
            local label = tostring(item.type or 'unknown')
            if item.status then label = label .. '/' .. tostring(item.status) end
            table.insert(items, label)
        end
    end

    if #items > 0 then return table.concat(items, ', ') end
    return nil
end

local function reasoning_tokens(response)
    local usage = type(response) == 'table' and response.usage
    local details = type(usage) == 'table' and usage.output_tokens_details
    local tokens = type(details) == 'table' and details.reasoning_tokens
    if tokens ~= nil then return tostring(tokens) end
    return nil
end

local function no_text_error(response)
    if type(response) ~= 'table' then return 'Error: OpenAI response was not a JSON object' end

    if type(response.error) == 'table' then
        return 'API error: ' .. tostring(response.error.message or response.error.code or 'Unknown error')
    end

    local refusal = extract_refusal(response)
    if refusal then return 'Error: OpenAI refused: ' .. refusal end

    if response.status == 'incomplete' then
        local details = type(response.incomplete_details) == 'table' and response.incomplete_details or {}
        local reason = tostring(details.reason or 'unknown reason')
        local message = 'Error: OpenAI response incomplete: ' .. reason .. '; no assistant text'
        if reason == 'max_output_tokens' then
            local tokens = reasoning_tokens(response)
            if tokens then
                message = message .. ' (reasoning tokens used: ' .. tokens .. ')'
            end
            message = message .. '. Increase max_tokens/chat_max_tokens or lower reasoning effort.'
        end
        return message
    end

    if response.status and response.status ~= 'completed' then
        return 'Error: OpenAI response status ' .. tostring(response.status) .. '; no assistant text'
    end

    local summary = output_item_summary(response)
    if summary then return 'Error: OpenAI returned no assistant text; output items: ' .. summary end

    return 'Error: No content found in OpenAI Responses API response'
end

return function(auth, model, max_tokens, temperature)
    local headers = {
        { 'Content-Type', 'application/json' },
    }
    for _, h in ipairs(auth.headers) do table.insert(headers, h) end

    return {
        model = model,
        max_tokens = max_tokens,
        headers = headers,
        build_body = function(system_message, messages)
            local input = {}
            for _, m in ipairs(messages) do
                table.insert(input, { role = m.role, content = as_text(m.content) or m.content })
            end
            local body = {
                model = model,
                instructions = system_message,
                input = input,
                max_output_tokens = max_tokens,
                temperature = temperature,
                stream = false,
                store = false,
            }
            local reasoning_effort = reasoning_effort_for_model(model)
            if reasoning_effort then body.reasoning = { effort = reasoning_effort } end
            return body
        end,
        extract_response = function(response)
            local text = extract_responses_text(response)
            if text then return text end
            return nil, no_text_error(response)
        end,
        stream_filter = table.concat({
            "grep --line-buffered '^data: '",
            "sed -u 's/^data: //'",
            "grep -v '^\\[DONE\\]$'",
            "jq --unbuffered -j 'select(.type == \"response.output_text.delta\") | .delta // empty'",
        }, ' | '),
        conversation_mode = 'previous_response_id',
        body_template = '\'{ model: $model, instructions: $sys, input: [{ role: "user", content: $msg }],'
            .. ' max_output_tokens: $max_tokens, temperature: $temperature, stream: true'
            .. (reasoning_effort_for_model(model) and ', reasoning: { effort: "low" }' or '')
            .. ' } + (if $previous_response_id == "" then {} else { previous_response_id: $previous_response_id } end)\'' ,
    }
end
