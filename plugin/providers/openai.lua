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

local function extract_responses_text(response)
    if type(response) ~= 'table' then return nil end
    if response.output_text then return response.output_text end

    if response.output then
        local parts = {}
        for _, item in ipairs(response.output) do
            if item.content then
                for _, content in ipairs(item.content) do
                    local text = content.text or content.output_text
                    if text then table.insert(parts, text) end
                end
            end
        end
        if #parts > 0 then return table.concat(parts, '') end
    end

    return nil
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
            return {
                model = model,
                instructions = system_message,
                input = input,
                max_output_tokens = max_tokens,
                temperature = temperature,
            }
        end,
        extract_response = function(response)
            local text = extract_responses_text(response)
            if text then return text end
            return nil, 'Error: No content found in OpenAI Responses API response'
        end,
        stream_filter = table.concat({
            "grep --line-buffered '^data: '",
            "sed -u 's/^data: //'",
            "grep -v '^\\[DONE\\]$'",
            "jq --unbuffered -j 'select(.type == \"response.output_text.delta\") | .delta // empty'",
        }, ' | '),
        conversation_mode = 'previous_response_id',
        body_template = '\'{ model: $model, instructions: $sys, input: [{ role: "user", content: $msg }],'
            .. ' max_output_tokens: $max_tokens, temperature: $temperature, stream: true }'
            .. ' + (if $previous_response_id == "" then {} else { previous_response_id: $previous_response_id } end)\'' ,
    }
end
