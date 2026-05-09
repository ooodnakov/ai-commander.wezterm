return function(api_key, model, max_tokens, temperature)
    return {
        model = model,
        max_tokens = max_tokens,
        headers = {
            { "Content-Type", "application/json" },
            { "x-api-key", api_key },
            { "anthropic-version", "2023-06-01" },
        },
        build_body = function(system_message, messages)
            return {
                model = model,
                max_tokens = max_tokens,
                temperature = temperature,
                system = system_message,
                messages = messages,
            }
        end,
        extract_response = function(response)
            if response.content and #response.content > 0 and response.content[1].text then
                return response.content[1].text
            end
            return nil, "Error: No content found in Anthropic API response"
        end,
        stream_filter = table.concat({
            "grep --line-buffered '^data: '",
            "sed -u 's/^data: //'",
            "jq --unbuffered -j 'select(.type == \"content_block_delta\") | .delta.text // empty'",
        }, ' | '),
        body_template = '\'{ model: $model, max_tokens: $max_tokens, temperature: 0.1, stream: true,'
            .. ' system: $sys, messages: [{ role: "user", content: $msg }] }\'',
    }
end
