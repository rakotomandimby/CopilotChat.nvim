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
  local log = require('plenary.log')
  local original_models, original_select, original_input, original_echo, original_warn, original_model

  before_each(function()
    original_models = client.models
    original_select = vim.ui.select
    original_input = vim.ui.input
    original_echo = vim.api.nvim_echo
    original_warn = log.warn
    original_model = chat.config.model
    client.models = function()
      return {
        auto = { id = 'auto', name = 'Auto (Copilot)', provider = 'copilot' },
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
          output_credits = 500,
        },
        ['priced:high'] = {
          id = 'priced:high',
          request_model = 'priced',
          name = 'Priced (high)',
          provider = 'copilot',
          reasoning_effort = 'high',
          reasoning_effort_index = 2,
          input_credits = 100,
          output_credits = 500,
        },
        partial = { id = 'partial', name = 'Partial', provider = 'other', input_credits = 0, output_credits = 0.125 },
        zpartial = { id = 'zpartial', name = 'Missing output', provider = 'other', input_credits = 10 },
        invalid = { id = 'invalid', name = 'Invalid', provider = 'other', input_credits = 'bad' },
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

    assert.equals('1. Auto (Copilot) [?/?, copilot]', labels.auto)
    assert.equals('* 2. Priced [100/500, copilot, streaming, tools]', labels.priced)
    assert.equals('      2a. Low', labels['priced:low'])
    assert.equals('      2b. High', labels['priced:high'])
    assert.equals('4. Partial [0/0.125, other]', labels.partial)
    assert.equals('5. Missing output [10/?, other]', labels.zpartial)
    assert.equals('3. Invalid [?/?, other]', labels.invalid)
    assert.equals(1, #warnings)
    choose(nil)
    assert.equals('priced', chat.config.model)
    for _, item in ipairs(choices) do
      if item.id == 'priced:high' then
        choose(item)
      end
    end
    assert.equals('priced:high', chat.config.model)
    chat.select_model()
    assert.equals('    * 2b. High', labels['priced:high'])
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

    assert.truthy(displayed:find('Auto %(Copilot%) %[%?/%?, copilot%]'))
    assert.truthy(displayed:find('Priced %[100/500, copilot, streaming, tools%]'))
    assert.truthy(displayed:find('2a. Low - 2b. High', 1, true))
    assert.truthy(displayed:find('Partial %[0/0%.125, other%]'))
    assert.truthy(displayed:find('Missing output %[10/%?, other%]'))
    on_input('')
    assert.equals('priced', chat.config.model)
    on_input('2b')
    assert.equals('priced:high', chat.config.model)
    chat.select_model()
    assert.truthy(displayed:find('2a. Low - *2b. High', 1, true))
  end)
end)
