describe('CopilotChat copilot provider models', function()
  local client = require('CopilotChat.client')
  local curl = require('CopilotChat.utils.curl')
  local providers = require('CopilotChat.config.providers')
  local log = require('plenary.log')

  local restores = {}

  --- Replace `tbl[key]` for the duration of a test, the original is restored in `after_each`.
  local function patch(tbl, key, value)
    local original = tbl[key]
    table.insert(restores, function()
      tbl[key] = original
    end)
    tbl[key] = value
  end

  before_each(function()
    patch(curl, 'get', function()
      return { body = { data = {} } }
    end)
    patch(curl, 'post', function()
      return { body = {} }
    end)
  end)

  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    restores = {}
  end)

  local function model(id, picker, supported_endpoints)
    return {
      id = id,
      name = id,
      version = '1',
      model_picker_enabled = picker,
      capabilities = {
        type = 'chat',
        tokenizer = 'o200k_base',
        limits = { max_prompt_tokens = 1000, max_output_tokens = 100 },
        supports = { streaming = true, tool_calls = true },
      },
      supported_endpoints = supported_endpoints,
    }
  end

  --- Model fixture with token prices; `extra` is deep merged into the model.
  local function priced(id, prices, extra)
    local item = model(id, true, {})
    item.billing = { token_prices = prices }
    return vim.tbl_deep_extend('force', item, extra or {})
  end

  --- Index a list of models by id.
  local function by_id(list)
    local out = {}
    for _, item in ipairs(list) do
      out[item.id] = item
    end
    return out
  end

  --- Serve `data` from the models endpoint.
  local function serve_models(...)
    local data = { ... }
    patch(curl, 'get', function()
      return { body = { data = data } }
    end)
  end

  --- Give the client authenticated headers so no token request is made.
  local function with_cached_auth()
    patch(client.provider_cache, 'copilot', {
      headers = { ['Authorization'] = 'Bearer test-token' },
      expires_at = os.time() + 3600,
    })
  end

  it('includes picker-disabled chat models with full metadata and auto', function()
    serve_models(
      model('gpt-5.4-mini', false, { '/chat/completions' }),
      model('gpt-5.4-responses', false, { '/responses' }),
      { id = 'embedding', capabilities = { type = 'embeddings' } }
    )

    local models = by_id(providers.copilot.get_models({}))

    assert.is_false(models['gpt-5.4-mini'].picker)
    assert.is_false(models['gpt-5.4-mini'].use_responses)
    assert.equals('o200k_base', models['gpt-5.4-mini'].tokenizer)
    assert.is_true(models['gpt-5.4-responses'].use_responses)
    assert.is_nil(models.embedding)
    assert.is_not_nil(models.auto)
  end)

  it('includes both picker-enabled and picker-disabled chat models', function()
    serve_models(
      model('gpt-5.4-mini', true, { '/responses' }),
      model('gpt-5.4-restricted', false, { '/chat/completions' })
    )

    local models = by_id(providers.copilot.get_models({}))

    assert.is_true(models['gpt-5.4-mini'].picker)
    assert.is_true(models['gpt-5.4-mini'].use_responses)
    assert.is_false(models['gpt-5.4-restricted'].picker)
    assert.is_false(models['gpt-5.4-restricted'].use_responses)
  end)

  it('uses the newer API version without mutating the caller headers', function()
    local disabled = priced('disabled', { batch_size = 1000000, default = { input_price = 1, output_price = 1 } }, {
      policy = { state = 'disabled' },
    })

    local captured_headers, policy_headers
    patch(curl, 'get', function(_, opts)
      captured_headers = opts.headers
      return { body = { data = { disabled } } }
    end)
    patch(curl, 'post', function(_, opts)
      policy_headers = opts.headers
      return { body = {} }
    end)

    local headers = { ['x-github-api-version'] = '2025-10-01', ['x-copilot-base-url'] = 'https://example.test' }
    providers.copilot.get_models(headers)

    assert.equals('2026-08-01', captured_headers['x-github-api-version'])
    assert.is_nil(captured_headers['x-copilot-base-url'])
    assert.equals('2025-10-01', headers['x-github-api-version'])
    assert.equals('2025-10-01', policy_headers['x-github-api-version'])
  end)

  it('normalizes default AI Credit rates and preserves them on reasoning variants', function()
    local with_rates = priced('priced', {
      batch_size = 100000,
      default = { input_price = 12.5, output_price = 0 },
      long_context = { input_price = 999, output_price = 999 },
    }, { capabilities = { supports = { reasoning_effort = { 'high' } } } })
    local partial = priced('partial', { batch_size = 1000000, default = { output_price = 0.125 } })
    local unpriced = model('unpriced', true, {})
    serve_models(with_rates, partial, unpriced)

    local models = by_id(providers.copilot.get_models({}))

    assert.equals(125, models.priced.input_credits)
    assert.equals(0, models.priced.output_credits)
    assert.equals(125, models['priced:high'].input_credits)
    assert.equals(0, models['priced:high'].output_credits)
    assert.is_nil(models.partial.input_credits)
    assert.equals(0.125, models.partial.output_credits)
    assert.is_nil(models.unpriced.input_credits)
    assert.is_nil(models.auto.output_credits)
  end)

  it('reports malformed pricing and leaves invalid rates unknown', function()
    local warnings = {}
    patch(log, 'warn', function(message)
      table.insert(warnings, message)
    end)

    serve_models(
      priced('invalid-rate', {
        batch_size = 1000000,
        default = { input_price = 'bad', output_price = 5 },
      }),
      priced('invalid-batch', {
        batch_size = 0,
        default = { input_price = 10, output_price = 20 },
      })
    )

    local models = by_id(providers.copilot.get_models({}))

    assert.is_nil(models['invalid-rate'].input_credits)
    assert.equals(5, models['invalid-rate'].output_credits)
    assert.is_nil(models['invalid-batch'].input_credits)
    assert.is_nil(models['invalid-batch'].output_credits)
    assert.equals(2, #warnings)
  end)

  it('returns the selected model and session token for auto', function()
    patch(curl, 'post', function()
      return { body = { selected_model = 'gpt-5.4-mini', session_token = 'session-token' } }
    end)

    local selected, headers = providers.copilot.resolve_model({}, 'auto')

    assert.equals('gpt-5.4-mini', selected)
    assert.same({ ['Copilot-Session-Token'] = 'session-token' }, headers)
  end)

  it('returns non-auto models unchanged without headers', function()
    local selected, headers = providers.copilot.resolve_model({}, 'gpt-5.4-mini')

    assert.equals('gpt-5.4-mini', selected)
    assert.is_nil(headers)
  end)

  it('provides auto fallback when all models are picker-disabled', function()
    -- Restricted accounts have model_picker_enabled=false for every model.
    -- The default config model (e.g. gpt-5-mini) is found in the cache but
    -- cannot be called directly; the client must fall back to auto mode,
    -- which resolves via /models/session and returns a session token.
    serve_models(model('gpt-5-mini', false, { '/chat/completions' }))
    patch(curl, 'post', function()
      return { body = { selected_model = 'gpt-5-mini', session_token = 'restricted-session-token' } }
    end)

    local models = by_id(providers.copilot.get_models({}))

    -- Every chat model is picker-disabled, but auto is still available
    assert.is_false(models['gpt-5-mini'].picker)
    assert.is_not_nil(models.auto)

    -- Auto resolution returns a session token that authorizes the request
    local selected, headers = providers.copilot.resolve_model({}, 'auto')
    assert.equals('gpt-5-mini', selected)
    assert.same({ ['Copilot-Session-Token'] = 'restricted-session-token' }, headers)
  end)

  it('returns a descriptive error when auto session endpoint fails', function()
    -- The real async curl.post returns (response, err); the mock must match.
    patch(curl, 'post', function()
      return { status = 403, body = '{"error":"forbidden"}' }, '{"error":"forbidden"}'
    end)

    local ok, err = pcall(providers.copilot.resolve_model, {}, 'auto')
    assert.is_false(ok)
    assert.truthy(string.find(err, '403'))
    assert.truthy(string.find(err, 'forbidden'))
  end)

  it('returns a descriptive error when auto returns no selected_model', function()
    patch(curl, 'post', function()
      return { body = {} }
    end)

    local ok, err = pcall(providers.copilot.resolve_model, {}, 'auto')
    assert.is_false(ok)
    assert.truthy(string.find(err, 'no selected_model'))
  end)

  it('generates reasoning effort variants when model supports reasoning_effort', function()
    local m = model('gpt-5.4', true, { '/responses' })
    m.capabilities.supports.reasoning_effort = { 'low', 'medium', 'high' }
    serve_models(m)

    local models = by_id(providers.copilot.get_models({}))

    assert.is_not_nil(models['gpt-5.4'])
    assert.is_nil(models['gpt-5.4'].reasoning_effort)
    assert.same({ 'low', 'medium', 'high' }, models['gpt-5.4'].reasoning_efforts)

    assert.is_not_nil(models['gpt-5.4:low'])
    assert.equals('low', models['gpt-5.4:low'].reasoning_effort)
    assert.equals('gpt-5.4', models['gpt-5.4:low'].request_model)

    assert.is_not_nil(models['gpt-5.4:medium'])
    assert.equals('medium', models['gpt-5.4:medium'].reasoning_effort)

    assert.is_not_nil(models['gpt-5.4:high'])
    assert.equals('high', models['gpt-5.4:high'].reasoning_effort)
  end)

  it('serializes reasoning effort in prepare_input for responses and chat APIs', function()
    local base_model = {
      id = 'gpt-5.4',
      request_model = 'gpt-5.4',
      streaming = false,
      use_responses = true,
    }

    -- With reasoning effort for Responses API
    local with_effort = vim.tbl_extend('force', base_model, { reasoning_effort = 'high' })
    local req = providers.copilot.prepare_input({}, { model = with_effort })
    assert.is_not_nil(req.reasoning)
    assert.equals('high', req.reasoning.effort)

    -- With invalid/arbitrary reasoning effort for Responses API
    local with_invalid = vim.tbl_extend('force', base_model, { reasoning_effort = 'invalid' })
    req = providers.copilot.prepare_input({}, { model = with_invalid })
    assert.is_not_nil(req.reasoning)
    assert.equals('invalid', req.reasoning.effort)

    -- Without reasoning effort for Responses API (default effort)
    local no_effort = vim.tbl_extend('force', base_model, { reasoning_effort = nil })
    req = providers.copilot.prepare_input({}, { model = no_effort })
    assert.is_nil(req.reasoning)

    -- With reasoning effort for Chat Completions API
    local chat_model = vim.tbl_extend('force', base_model, { use_responses = false, reasoning_effort = 'high' })
    req = providers.copilot.prepare_input({}, { model = chat_model })
    assert.equals('high', req.reasoning_effort)

    -- With invalid reasoning effort for Chat Completions API
    local chat_invalid = vim.tbl_extend('force', base_model, { use_responses = false, reasoning_effort = 'invalid' })
    req = providers.copilot.prepare_input({}, { model = chat_invalid })
    assert.equals('invalid', req.reasoning_effort)

    -- Without reasoning effort for Chat Completions API (default effort)
    local chat_no_effort = vim.tbl_extend('force', base_model, { use_responses = false, reasoning_effort = nil })
    req = providers.copilot.prepare_input({}, { model = chat_no_effort })
    assert.is_nil(req.reasoning_effort)
  end)

  it('allows setting custom or invalid reasoning effort and propagates API error', function()
    local m = model('gpt-5.4', true, { '/responses' })
    m.capabilities.supports.reasoning_effort = { 'low', 'medium', 'high' }
    m.capabilities.limits = {}
    serve_models(m)
    with_cached_auth()

    local captured_args = nil
    patch(curl, 'post', function(_, args)
      captured_args = args
      return {
        status = 400,
        body = '{"error":{"message":"Invalid reasoning effort: invalid. Supported values: low, medium, high"}}',
      },
        '{"error":{"message":"Invalid reasoning effort: invalid. Supported values: low, medium, high"}}'
    end)

    local ok, err = pcall(function()
      client:ask({
        headless = true,
        model = 'gpt-5.4:invalid',
        history = {},
      })
    end)

    assert.is_false(ok)
    assert.truthy(string.find(err, '400'))
    assert.truthy(string.find(err, 'Invalid reasoning effort: invalid'))

    assert.is_not_nil(captured_args)
    assert.equals('gpt-5.4', captured_args.body.model)
    assert.equals('invalid', captured_args.body.reasoning.effort)
  end)

  it('sends no reasoning parameter when no effort is specified (model default)', function()
    local m = model('gpt-5.4', true, { '/responses' })
    m.capabilities.supports.reasoning_effort = { 'low', 'medium', 'high' }
    m.capabilities.limits = {}
    serve_models(m)
    with_cached_auth()

    local captured_args = nil
    patch(curl, 'post', function(_, args)
      captured_args = args
      return {
        status = 200,
        body = vim.json.encode({
          response = {
            output = { { content = 'Hello' } },
            status = 'completed',
          },
        }),
      }
    end)

    local resp = client:ask({
      headless = true,
      model = 'gpt-5.4',
      history = {},
    })

    assert.is_not_nil(resp)
    assert.is_not_nil(captured_args)
    assert.equals('gpt-5.4', captured_args.body.model)
    assert.is_nil(captured_args.body.reasoning)
  end)

  it('resolves model with reasoning effort from config and prompt colon syntax', function()
    local prompts = require('CopilotChat.prompts')
    local m = model('gpt-5.4', true, { '/responses' })
    m.capabilities.supports.reasoning_effort = { 'low', 'medium', 'high' }
    serve_models(m)
    with_cached_auth()

    -- Configured with model = 'gpt-5.4:high'
    local resolved, prompt = prompts.resolve_model('Hello', { model = 'gpt-5.4:high' })
    assert.equals('gpt-5.4:high', resolved)
    assert.equals('Hello', prompt)

    -- Overridden in prompt with $gpt-5.4:low
    resolved, prompt = prompts.resolve_model('Hello $gpt-5.4:low', { model = 'gpt-5.4:high' })
    assert.equals('gpt-5.4:low', resolved)
    assert.equals('Hello', vim.trim(prompt))

    -- Overridden in prompt with arbitrary/invalid effort $gpt-5.4:custom
    resolved, prompt = prompts.resolve_model('Hello $gpt-5.4:custom', { model = 'gpt-5.4' })
    assert.equals('gpt-5.4:custom', resolved)
    assert.equals('Hello', vim.trim(prompt))
  end)

  describe('get_info', function()
    --- Provide a fake GitHub token through the environment so no auth flow is started.
    local function with_env_token()
      local previous = { CODESPACES = vim.env.CODESPACES, GITHUB_TOKEN = vim.env.GITHUB_TOKEN }
      vim.uv.os_setenv('CODESPACES', '1')
      vim.uv.os_setenv('GITHUB_TOKEN', 'test-token')
      table.insert(restores, function()
        for name, value in pairs(previous) do
          if value == nil then
            vim.uv.os_unsetenv(name)
          else
            vim.uv.os_setenv(name, value)
          end
        end
      end)
    end

    --- Serve `body` from the user info endpoint and return the rendered info text.
    local function info_for(body)
      with_env_token()
      patch(curl, 'get', function()
        return { body = body }
      end)
      return table.concat(providers.copilot.get_info({}), '\n')
    end

    it('reports AI Credits (AIC) instead of premium requests and omits chat', function()
      local text = info_for({
        quota_snapshots = {
          premium_interactions = { entitlement = 20000, remaining = 19691, overage_permitted = false },
          chat = { unlimited = true },
          completions = { unlimited = true },
        },
        quota_reset_date = '2026-11-01',
      })

      assert.truthy(text:find('**AI Credits (AIC)**', 1, true))
      assert.truthy(text:find('Usage: 309 / 20000 (1.5%)', 1, true))
      assert.truthy(text:find('Remaining: 19691', 1, true))
      assert.truthy(text:find('Overage: Not Permitted', 1, true))
      assert.is_nil(text:find('Premium requests', 1, true))
      assert.is_nil(text:find('**Chat**', 1, true))
      assert.truthy(text:find('**Completions**', 1, true))
      assert.truthy(text:find('resets on: 2026-11-01', 1, true))
    end)

    it('prefers the ai_credits snapshot over the legacy key', function()
      local text = info_for({
        quota_snapshots = {
          ai_credits = { entitlement = 100, remaining = 40 },
          premium_interactions = { entitlement = 20000, remaining = 19691 },
        },
      })

      assert.truthy(text:find('Usage: 60 / 100 (60.0%)', 1, true))
      assert.is_nil(text:find('20000', 1, true))
    end)

    it('shows fractional credit amounts', function()
      local text = info_for({
        quota_snapshots = {
          ai_credits = { entitlement = 100, remaining = 87.5 },
        },
      })

      assert.truthy(text:find('Usage: 12.5 / 100 (12.5%)', 1, true))
      assert.truthy(text:find('Remaining: 87.5', 1, true))
    end)

    it('handles missing stats', function()
      assert.equals('No Copilot stats available.', info_for({}))
    end)
  end)
end)

