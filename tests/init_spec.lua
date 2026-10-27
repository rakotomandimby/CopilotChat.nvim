describe('CopilotChat module', function()
  it('should be able to load', function()
    assert.has_no.errors(function()
      require('CopilotChat')
    end)
  end)

  it('should be able to set up', function()
    assert.has_no.errors(function()
      require('CopilotChat').setup({})
    end)
    assert.is_not_nil(require('CopilotChat').chat)
  end)
end)

describe('CopilotChat model picker pricing', function()
  local chat = require('CopilotChat')
  local client = require('CopilotChat.client')
  local curl = require('CopilotChat.utils.curl')
  local log = require('plenary.log')
  local original_models, original_select, original_input, original_echo, original_warn, original_model, original_auth
  local original_post

  before_each(function()
    original_models = client.models
    original_select = vim.ui.select
    original_input = vim.ui.input
    original_echo = vim.api.nvim_echo
    original_warn = log.warn
    original_model = chat.config.model
    original_auth = client.authenticate
    original_post = curl.post
    client.models = function()
      return {
        auto = { id = 'auto', name = 'Auto (Copilot)', provider = 'copilot' },
        cheap = { id = 'cheap', name = 'Cheap', provider = 'z', output_credits = 0 },
        expensive = { id = 'expensive', name = 'Expensive', provider = 'a', output_credits = 1000 },
        priced = {
          id = 'priced',
          name = 'Priced',
          provider = 'copilot',
          streaming = true,
          tools = true,
          input_credits = 100,
          output_credits = 500,
        },
        ['priced:low'] = {
          id = 'priced:low',
          request_model = 'priced',
          name = 'Priced (low)',
          provider = 'copilot',
          reasoning_effort = 'low',
          reasoning_effort_index = 1,
          input_credits = 100,
          output_credits = 900,
        },
        ['priced:high'] = {
          id = 'priced:high',
          request_model = 'priced',
          name = 'Priced (high)',
          provider = 'copilot',
          reasoning_effort = 'high',
          reasoning_effort_index = 2,
          input_credits = 100,
          output_credits = 0,
        },
        sibling = { id = 'sibling', name = 'Sibling', provider = 'copilot', output_credits = 500 },
        ['sibling:high'] = {
          id = 'sibling:high',
          request_model = 'sibling',
          name = 'Sibling (high)',
          provider = 'copilot',
          reasoning_effort = 'high',
          reasoning_effort_index = 1,
          output_credits = 500,
        },
        partial = { id = 'partial', name = 'Partial', provider = 'other', input_credits = 0, output_credits = 0.125 },
        zpartial = { id = 'zpartial', name = 'Missing output', provider = 'other', input_credits = 10 },
        invalid = { id = 'invalid', name = 'Invalid', provider = 'other', input_credits = 'bad', output_credits = -1 },
      }
    end
    chat.config.model = 'priced'
  end)

  after_each(function()
    client.models = original_models
    vim.ui.select = original_select
    vim.ui.input = original_input
    vim.api.nvim_echo = original_echo
    log.warn = original_warn
    chat.config.model = original_model
    client.authenticate = original_auth
    curl.post = original_post
  end)

  it('renders rates in a custom picker and preserves selection and cancellation', function()
    local labels, choose, choices = {}, nil, nil
    local warnings = {}
    log.warn = function(message)
      table.insert(warnings, message)
    end
    vim.ui.select = function(items, opts, callback)
      choices, choose = items, callback
      for _, item in ipairs(items) do
        labels[item.id] = opts.format_item(item)
      end
    end

    chat.select_model()

    assert.same(
      {
        'auto',
        'cheap',
        'partial',
        'priced',
        'priced:low',
        'priced:high',
        'sibling',
        'sibling:high',
        'expensive',
        'invalid',
        'zpartial',
      },
      vim.tbl_map(function(item)
        return item.id
      end, choices)
    )
    assert.equals('1. Auto (Copilot) [?/?, copilot]', labels.auto)
    assert.equals('2. Cheap [?/0, z]', labels.cheap)
    assert.equals('3. Partial [0/0.125, other]', labels.partial)
    assert.equals('* 4. Priced [100/500, copilot, streaming, tools]', labels.priced)
    assert.equals('      4a. Low', labels['priced:low'])
    assert.equals('      4b. High', labels['priced:high'])
    assert.equals('5. Sibling [?/500, copilot]', labels.sibling)
    assert.equals('      5a. High', labels['sibling:high'])
    assert.equals('6. Expensive [?/1000, a]', labels.expensive)
    assert.equals('7. Invalid [?/?, other]', labels.invalid)
    assert.equals('8. Missing output [10/?, other]', labels.zpartial)
    assert.equals(2, #warnings)
    choose(nil)
    assert.equals('priced', chat.config.model)
    for _, item in ipairs(choices) do
      if item.id == 'priced:high' then
        choose(item)
      end
    end
    assert.equals('priced:high', chat.config.model)
    chat.select_model()
    assert.equals('    * 4b. High', labels['priced:high'])
  end)

  it('renders rates in the built-in picker and selects an effort code', function()
    local displayed, on_input
    vim.ui.select = assert(loadstring('return function() end', '@/test/vim/ui.lua'))()
    vim.api.nvim_echo = function(chunks)
      displayed = chunks[1][1]
    end
    vim.ui.input = function(_, callback)
      on_input = callback
    end
    log.warn = function() end

    chat.select_model()

    assert.truthy(displayed:find('1. Auto (Copilot) [?/?, copilot]', 1, true))
    assert.truthy(displayed:find('Priced %[100/500, copilot, streaming, tools%]'))
    assert.truthy(displayed:find('4a. Low - 4b. High', 1, true))
    assert.truthy(displayed:find('5a. High', 1, true))
    assert.truthy(displayed:find('Partial %[0/0%.125, other%]'))
    assert.truthy(displayed:find('Missing output %[10/%?, other%]'))
    on_input('')
    assert.equals('priced', chat.config.model)
    on_input('4b')
    assert.equals('priced:high', chat.config.model)
    chat.select_model()
    assert.truthy(displayed:find('4a. Low - *4b. High', 1, true))
    on_input('5a')
    assert.equals('sibling:high', chat.config.model)
    on_input('2')
    assert.equals('cheap', chat.config.model)
    on_input('1')
    assert.equals('auto', chat.config.model)
  end)

  it('selects the correct model and effort with double-digit codes', function()
    local models = { auto = { id = 'auto', name = 'Auto (Copilot)', provider = 'copilot' } }
    for i = 1, 12 do
      local id = string.format('model-%02d', i)
      models[id] = { id = id, name = id, provider = 'copilot', output_credits = 13 - i }
    end
    models['model-04:high'] = {
      id = 'model-04:high',
      name = 'model-04 (high)',
      provider = 'copilot',
      request_model = 'model-04',
      reasoning_effort = 'high',
      reasoning_effort_index = 1,
      output_credits = 999,
    }
    client.models = function()
      return models
    end
    local displayed, on_input
    vim.ui.select = assert(loadstring('return function() end', '@/test/vim/ui.lua'))()
    vim.api.nvim_echo = function(chunks)
      displayed = chunks[1][1]
    end
    vim.ui.input = function(_, callback)
      on_input = callback
    end

    chat.select_model()

    local ten = assert(displayed:find('10. model-04', 1, true))
    local eleven = assert(displayed:find('11. model-03', 1, true))
    assert.is_true(ten < eleven)
    assert.truthy(displayed:find('10a. High', 1, true))
    on_input('10a')
    assert.equals('model-04:high', chat.config.model)

    local request
    client.authenticate = function()
      return {}
    end
    curl.post = function(_, opts)
      request = opts.body
      return { body = vim.json.encode({ choices = { { message = { content = 'ok' }, finish_reason = 'stop' } } }) }
    end
    local function send_selected()
      client:ask({
        headless = true,
        model = chat.config.model,
        system_prompt = '',
        history = {},
        tools = {},
        resources = {},
      })
    end
    send_selected()
    assert.equals('model-04', request.model)
    assert.equals('high', request.reasoning_effort)

    on_input('10')
    assert.equals('model-04', chat.config.model)
    send_selected()
    assert.equals('model-04', request.model)
    assert.is_nil(request.reasoning_effort)
    on_input('11')
    assert.equals('model-03', chat.config.model)
    on_input('1')
    assert.equals('auto', chat.config.model)
  end)

  it('keeps provider-qualified Auto models before priced models', function()
    local models = {
      auto = { id = 'auto', name = 'Auto', provider = 'copilot' },
      ['auto:other'] = { id = 'auto:other', name = 'Other Auto', provider = 'other', output_credits = 1 },
      cheap = { id = 'cheap', name = 'Cheap', provider = 'copilot', output_credits = 0 },
    }
    client.models = function()
      return models
    end
    local choices, choose
    vim.ui.select = function(items, _, callback)
      choices, choose = items, callback
    end

    chat.select_model()
    assert.equals('auto', choices[1].id)
    assert.equals('auto:other', choices[2].id)
    assert.equals('cheap', choices[3].id)
    choose(choices[2])
    assert.equals('auto:other', chat.config.model)

    models.auto = nil
    chat.select_model()
    assert.equals('auto:other', choices[1].id)
    assert.equals('cheap', choices[2].id)
  end)

  it('keeps codes unique for duplicate effort indexes and standalone variants', function()
    client.models = function()
      return {
        model = { id = 'model', name = 'Model', provider = 'copilot', output_credits = 10 },
        ['model:low'] = {
          id = 'model:low',
          name = 'Model (low)',
          provider = 'copilot',
          request_model = 'model',
          reasoning_effort = 'low',
          reasoning_effort_index = 1,
        },
        ['model:medium'] = {
          id = 'model:medium',
          name = 'Model (medium)',
          provider = 'copilot',
          request_model = 'model',
          reasoning_effort = 'medium',
          reasoning_effort_index = 1,
        },
        hidden = { id = 'hidden', name = 'Hidden', provider = 'copilot', picker = false, output_credits = 15 },
        ['hidden:high'] = {
          id = 'hidden:high',
          name = 'Hidden (high)',
          provider = 'copilot',
          request_model = 'hidden',
          reasoning_effort = 'high',
          reasoning_effort_index = 1,
          output_credits = 15,
        },
      }
    end
    local labels, choose, choices = {}, nil, nil
    local warnings = {}
    log.warn = function(message)
      table.insert(warnings, message)
    end
    vim.ui.select = function(items, opts, callback)
      choices, choose = items, callback
      for _, item in ipairs(items) do
        labels[item.id] = opts.format_item(item)
      end
    end

    chat.select_model()

    assert.equals('      1a. Low', labels['model:low'])
    assert.equals('      1b. Medium', labels['model:medium'])
    assert.equals('2. Hidden (high) [?/15, copilot]', labels['hidden:high'])
    assert.equals(1, #warnings)
    for _, item in ipairs(choices) do
      choose(item)
      assert.equals(item.id, chat.config.model)
    end
  end)
end)
