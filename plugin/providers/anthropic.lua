local function normalize_content(content)
    if type(content) == 'string' then return content end
    if type(content) == 'table' then return content end
    return tostring(content)
end

return function(auth, model, max_tokens, temperature)
    local headers = {
        { 'Content-Type', 'application/json' },
        { 'anthropic-version', '2023-06-01' },
    }
    for _, h in ipairs(auth.headers) do table.insert(headers, h) end

    return {
        model = model,
        max_tokens = max_tokens,
        headers = headers,
        build_body = function(system_message, messages)
            local anthropic_messages = {}
            for _, m in ipairs(messages) do
                table.insert(anthropic_messages, {
                    role = m.role,
                    content = normalize_content(m.content),
                })
            end
            return {
                model = model,
                max_tokens = max_tokens,
                temperature = temperature,
                system = system_message,
                messages = anthropic_messages,
            }
        end,
        extract_response = function(response)
            if response.content and #response.content > 0 then
                local parts = {}
                for _, block in ipairs(response.content) do
                    if block.text then table.insert(parts, block.text) end
                end
                if #parts > 0 then return table.concat(parts, '') end
            end
            return nil, 'Error: No content found in Anthropic Messages API response'
        end,
        stream_filter = table.concat({
            "grep --line-buffered '^data: '",
            "sed -u 's/^data: //'",
            "jq --unbuffered -j 'select(.type == \"content_block_delta\") | .delta.text // empty'",
        }, ' | '),
        conversation_mode = 'messages',
        body_template = '\'{ model: $model, max_tokens: $max_tokens, temperature: $temperature, stream: true,'
            .. ' system: $sys, messages: ($history + [{ role: "user", content: $msg }]) }\'' ,
    }
end
