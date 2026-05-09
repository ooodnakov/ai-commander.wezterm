return function(api_key, model, max_tokens, temperature)
    return {
        model = model,
        max_tokens = max_tokens,
        headers = {
            { "Content-Type", "application/json" },
            { "Authorization", "Bearer " .. api_key },
        },
        build_body = function(system_message, messages)
            local oai_messages = {{ role = "system", content = system_message }}
            for _, m in ipairs(messages) do
                table.insert(oai_messages, m)
            end
            return {
                model = model,
                max_tokens = max_tokens,
                temperature = temperature,
                messages = oai_messages,
            }
        end,
        extract_response = function(response)
            if response.choices and #response.choices > 0
                and response.choices[1].message and response.choices[1].message.content then
                return response.choices[1].message.content
            end
            return nil, "Error: No content found in OpenAI API response"
        end,
        stream_filter = table.concat({
            "grep --line-buffered '^data: '",
            "sed -u 's/^data: //'",
            "grep -v '^\\[DONE\\]$'",
            "jq --unbuffered -j '.choices[0].delta.content // empty'",
        }, ' | '),
        body_template = '\'{ model: $model, max_tokens: $max_tokens, temperature: 0.1, stream: true,'
            .. ' messages: [{ role: "system", content: $sys }, { role: "user", content: $msg }] }\'',
    }
end
