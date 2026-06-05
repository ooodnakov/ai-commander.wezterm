package.path = './?.lua;./?/init.lua;' .. package.path

local factory = require('plugin.providers.openai')

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end

local provider = factory({ headers = { { 'Authorization', 'Bearer test' } } }, 'gpt-5.5', 123, 0.2)

assert_equal(provider.model, 'gpt-5.5', 'model')
assert_equal(provider.max_tokens, 123, 'max tokens')
assert_equal(provider.headers[1][1], 'Content-Type', 'content type header')
assert_equal(provider.headers[2][2], 'Bearer test', 'auth header')

local body = provider.build_body('sys', {
    { role = 'user', content = { { type = 'input_text', text = 'hi' }, { text = ' there' } } },
    { role = 'assistant', content = 'ok' },
})
assert_equal(body.model, 'gpt-5.5', 'body model')
assert_equal(body.instructions, 'sys', 'instructions')
assert_equal(body.input[1].role, 'user', 'first role')
assert_equal(body.input[1].content, 'hi there', 'flattened content')
assert_equal(body.input[2].content, 'ok', 'string content')
assert_equal(body.max_output_tokens, 123, 'body max tokens')
assert_equal(body.temperature, 0.2, 'temperature')
assert_equal(body.stream, false, 'blocking stream flag')
assert_equal(body.store, false, 'blocking store flag')
assert_equal(body.reasoning.effort, 'low', 'gpt-5 reasoning effort')
assert(provider.body_template:find('reasoning: { effort: "low" }', 1, true), 'gpt-5 streaming body uses low reasoning')

local text = provider.extract_response({ output_text = 'top' })
assert_equal(text, 'top', 'top-level output_text')

text = provider.extract_response({
    output = {
        { type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'nested' } } },
    },
})
assert_equal(text, 'nested', 'nested output_text')

text = provider.extract_response({
    output = {
        { content = { { output_text = 'alt' } } },
    },
})
assert_equal(text, 'alt', 'alternate output_text field')

local missing, err = provider.extract_response({
    output = {
        { type = 'message', content = { { type = 'refusal', refusal = 'no' } } },
    },
})
assert_equal(missing, nil, 'refusal text')
assert_equal(err, 'Error: OpenAI refused: no', 'refusal error')

missing, err = provider.extract_response({
    status = 'incomplete',
    incomplete_details = { reason = 'max_output_tokens' },
    usage = { output_tokens_details = { reasoning_tokens = 4096 } },
    output = { { type = 'reasoning', status = 'completed' } },
})
assert_equal(missing, nil, 'incomplete text')
assert_equal(
    err,
    'Error: OpenAI response incomplete: max_output_tokens; no assistant text (reasoning tokens used: 4096). Increase max_tokens/chat_max_tokens or lower reasoning effort.',
    'incomplete error'
)

local non_reasoning = factory({ headers = {} }, 'gpt-4.1', 20, 0.1)
local non_reasoning_body = non_reasoning.build_body('sys', { { role = 'user', content = 'hi' } })
assert_equal(non_reasoning_body.reasoning, nil, 'non-reasoning model omits reasoning')
assert(not non_reasoning.body_template:find('reasoning:', 1, true), 'non-reasoning streaming body omits reasoning')

print('ok')
