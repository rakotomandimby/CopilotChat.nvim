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

  local restores = {}

  --- Replace `tbl[key]` for the duration of a test, the original is restored in `after_each`.
  local function patch(tbl, key, value)
    local original = tbl[key]
    table.insert(restores, function()
      tbl[key] = original
    end)
    tbl[key] = value
  end

  --- Collect the warnings logged from now on.
  local function capture_warnings()
    local warnings = {}
    patch(log, 'warn', function(message)
      table.insert(warnings, message)
    end)
    return warnings
  end

  --- Stub `vim.ui.select` and record what the picker renders.
  ---@return { choices: table[]?, labels: table<string, string>, choose: fun(item: table?)? }
  local function capture_select()
    local state = { labels = {} }
    patch(vim.ui, 'select', function(items, opts, callback)
      state.choices, state.choose = items, callback
      for _, item in ipairs(items) do
        state.labels[item.id] = opts.format_item(item)
      end
    end)
    return state
  end

  --- Select the choice with the given id, like a user would in a custom picker.
  local function choose_id(state, id)
    for _, item in ipairs(state.choices) do
      if item.id == id then
        state.choose(item)
        return
      end
    end
    error('No choice with id ' .. id)
  end

  --- Stub the built-in `vim.ui.select` (inputlist based) together with its echo and input prompts.
  local function use_builtin_picker()
    local state = {}
    patch(vim.ui, 'select', assert(loadstring('return function() end', '@/test/vim/ui.lua'))())
    patch(vim.api, 'nvim_echo', function(chunks)
      state.text = chunks[1][1]
    end)
    patch(vim.ui, 'input', function(_, callback)
      state.on_input = callback
    end)

    return {
      displayed = function()
        return state.text
      end,
      input = function(code)
        state.on_input(code)
      end,
    }
  end

  before_each(function()
    patch(client, 'models', function()
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
    end)
    patch(chat.config, 'model', 'priced')
  end)

  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    restores = {}
  end)

  it('renders rates in a custom picker and preserves selection and cancellation', function()
    local warnings = capture_warnings()
    local state = capture_select()

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
      end, state.choices)
    )
    local labels = state.labels
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

    state.choose(nil)
    assert.equals('priced', chat.config.model)
    choose_id(state, 'priced:high')
    assert.equals('priced:high', chat.config.model)

    chat.select_model()
    assert.equals('    * 4b. High', state.labels['priced:high'])
  end)

  it('renders rates in the built-in picker and selects an effort code', function()
    local picker = use_builtin_picker()
    capture_warnings()

    chat.select_model()

    local displayed = picker.displayed()
    assert.truthy(displayed:find('1. Auto (Copilot) [?/?, copilot]', 1, true))
    assert.truthy(displayed:find('Priced %[100/500, copilot, streaming, tools%]'))
    assert.truthy(displayed:find('4a. Low - 4b. High', 1, true))
    assert.truthy(displayed:find('5a. High', 1, true))
    assert.truthy(displayed:find('Partial %[0/0%.125, other%]'))
    assert.truthy(displayed:find('Missing output %[10/%?, other%]'))
    picker.input('')
    assert.equals('priced', chat.config.model)
    picker.input('4b')
    assert.equals('priced:high', chat.config.model)
    chat.select_model()
    assert.truthy(picker.displayed():find('4a. Low - *4b. High', 1, true))
    picker.input('5a')
    assert.equals('sibling:high', chat.config.model)
    picker.input('2')
    assert.equals('cheap', chat.config.model)
    picker.input('1')
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
    patch(client, 'models', function()
      return models
    end)
    local picker = use_builtin_picker()

    chat.select_model()

    local displayed = picker.displayed()
    local ten = assert(displayed:find('10. model-04', 1, true))
    local eleven = assert(displayed:find('11. model-03', 1, true))
    assert.is_true(ten < eleven)
    assert.truthy(displayed:find('10a. High', 1, true))
    picker.input('10a')
    assert.equals('model-04:high', chat.config.model)

    local request
    patch(client, 'authenticate', function()
      return {}
    end)
    patch(curl, 'post', function(_, opts)
      request = opts.body
      return { body = vim.json.encode({ choices = { { message = { content = 'ok' }, finish_reason = 'stop' } } }) }
    end)
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

    picker.input('10')
    assert.equals('model-04', chat.config.model)
    send_selected()
    assert.equals('model-04', request.model)
    assert.is_nil(request.reasoning_effort)
    picker.input('11')
    assert.equals('model-03', chat.config.model)
    picker.input('1')
    assert.equals('auto', chat.config.model)
  end)

  it('keeps provider-qualified Auto models before priced models', function()
    local models = {
      auto = { id = 'auto', name = 'Auto', provider = 'copilot' },
      ['auto:other'] = { id = 'auto:other', name = 'Other Auto', provider = 'other', output_credits = 1 },
      cheap = { id = 'cheap', name = 'Cheap', provider = 'copilot', output_credits = 0 },
    }
    patch(client, 'models', function()
      return models
    end)
    local state = capture_select()

    chat.select_model()
    assert.equals('auto', state.choices[1].id)
    assert.equals('auto:other', state.choices[2].id)
    assert.equals('cheap', state.choices[3].id)
    state.choose(state.choices[2])
    assert.equals('auto:other', chat.config.model)

    models.auto = nil
    chat.select_model()
    assert.equals('auto:other', state.choices[1].id)
    assert.equals('cheap', state.choices[2].id)
  end)

  it('keeps codes unique for duplicate effort indexes and standalone variants', function()
    patch(client, 'models', function()
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
    end)
    local warnings = capture_warnings()
    local state = capture_select()

    chat.select_model()

    assert.equals('      1a. Low', state.labels['model:low'])
    assert.equals('      1b. Medium', state.labels['model:medium'])
    assert.equals('2. Hidden (high) [?/15, copilot]', state.labels['hidden:high'])
    assert.equals(1, #warnings)
    for _, item in ipairs(state.choices) do
      state.choose(item)
      assert.equals(item.id, chat.config.model)
    end
  end)
end)
