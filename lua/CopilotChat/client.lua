---@class CopilotChat.client.AskOptions
---@field headless boolean
---@field history table<CopilotChat.client.Message>
---@field tools table<CopilotChat.client.Tool>?
---@field resources table<CopilotChat.client.Resource>?
---@field system_prompt string
---@field model string
---@field temperature number
---@field on_progress fun(response: CopilotChat.client.Message)?

---@class CopilotChat.client.Message
---@field role string
---@field content string
---@field reasoning string?
---@field tool_call_id string?
---@field tool_calls table<CopilotChat.client.ToolCall>?

---@class CopilotChat.client.AskResponse
---@field message CopilotChat.client.Message
---@field token_count number
---@field token_max_count number

---@class CopilotChat.client.ToolCall
---@field id number
---@field index number
---@field name string
---@field arguments string

---@class CopilotChat.client.Tool
---@field name string name of the tool
---@field description string description of the tool
---@field schema table? schema of the tool

---@class CopilotChat.client.ResourceAnnotations
---@field start_line number?
---@field end_line number?

---@class CopilotChat.client.Resource
---@field data string
---@field name string?
---@field mimetype string?
---@field uri string?
---@field annotations CopilotChat.client.ResourceAnnotations?

---@class CopilotChat.client.Model
---@field provider string?
---@field id string
---@field name string
---@field tokenizer string?
---@field max_input_tokens number?
---@field max_output_tokens number?
---@field streaming boolean?
---@field tools boolean?
---@field reasoning boolean?

local log = require('plenary.log')
local constants = require('CopilotChat.constants')
local notify = require('CopilotChat.utils.notify')
local tiktoken = require('CopilotChat.tiktoken')
local utils = require('CopilotChat.utils')
local curl = require('CopilotChat.utils.curl')
local class = require('CopilotChat.utils.class')
local files = require('CopilotChat.utils.files')
local orderedmap = require('CopilotChat.utils.orderedmap')
local stringbuffer = require('CopilotChat.utils.stringbuffer')

--- Constants
local RESOURCE_SHORT_FORMAT = '# %s\n```%s start_line=%s end_line=%s\n%s\n```'
local RESOURCE_LONG_FORMAT = '# %s\n```%s path=%s start_line=%s end_line=%s\n%s\n```'
local CACHE_TTL = 300 -- 5 minutes

--- Get a cached value or fill it if not present
--- @param cache table: The cache table to use
--- @param key string: The key to look up in the cache
--- @param filler function: A function that returns the value to cache if not present
local function get_cached(cache, key, filler)
  local now = math.floor(os.time())
  if cache and cache[key] and cache[key .. '_expires_at'] > now then
    return cache[key]
  end

  local value = filler()
  cache[key] = value
  cache[key .. '_expires_at'] = now + CACHE_TTL
  return value
end

---@param key any
---@return boolean
local function is_sensitive_key(key)
  if type(key) ~= 'string' then
    return false
  end

  key = key:lower()
  return key:find('authorization', 1, true) ~= nil
    or key:find('token', 1, true) ~= nil
    or key:find('secret', 1, true) ~= nil
    or key:find('password', 1, true) ~= nil
    or key:find('cookie', 1, true) ~= nil
end

---@param value any
---@return any
local function sanitize_for_log(value)
  if type(value) ~= 'table' then
    return value
  end

  local out = {}
  for k, v in pairs(value) do
    if is_sensitive_key(k) then
      out[k] = '<redacted>'
    else
      out[k] = type(v) == 'table' and sanitize_for_log(v) or v
    end
  end

  return out
end

---@param text any
---@param max_len integer?
---@return any
local function preview_text(text, max_len)
  if type(text) ~= 'string' then
    return text
  end

  max_len = max_len or 200
  local normalized = text:gsub('\r', '\\r'):gsub('\n', '\\n')
  if #normalized > max_len then
    return normalized:sub(1, max_len) .. '…'
  end
  return normalized
end

---@param models table<string, CopilotChat.client.Model>
---@return table<string, table>
local function summarize_models(models)
  local out = {}
  local ids = vim.tbl_keys(models or {})
  table.sort(ids)

  for _, id in ipairs(ids) do
    local model = models[id]
    out[id] = {
      id = model.id,
      name = model.name,
      provider = model.provider,
      tokenizer = model.tokenizer,
      max_input_tokens = model.max_input_tokens,
      max_output_tokens = model.max_output_tokens,
      streaming = model.streaming,
      tools = model.tools,
      reasoning = model.reasoning,
      version = model.version,
      use_responses = model.use_responses,
      base_url = model.base_url,
    }
  end

  return out
end

---@param models table<string, CopilotChat.client.Model>
---@param provider_name string
---@return string[]
local function model_ids_for_provider(models, provider_name)
  local out = {}
  for id, model in pairs(models or {}) do
    if model.provider == provider_name then
      table.insert(out, id)
    end
  end
  table.sort(out)
  return out
end

---@param cache table?
---@return table?
local function summarize_provider_cache(cache)
  if not cache then
    return nil
  end

  local now = math.floor(os.time())
  local out = {}

  for key, value in pairs(cache) do
    if not tostring(key):match('_expires_at$') then
      local expires_at = cache[key .. '_expires_at']
      out[key] = {
        present = value ~= nil,
        expires_at = expires_at,
        expired = expires_at and expires_at <= now or nil,
      }

      if type(value) == 'table' then
        if key == 'headers' then
          out[key].value = sanitize_for_log(value)
        elseif vim.islist(value) then
          out[key].count = #value
          if key == 'models' then
            out[key].value = vim.tbl_map(function(model)
              return {
                id = model.id,
                name = model.name,
                provider = model.provider,
                version = model.version,
                use_responses = model.use_responses,
                base_url = model.base_url,
              }
            end, value)
          else
            out[key].value = sanitize_for_log(value)
          end
        else
          out[key].value = sanitize_for_log(value)
        end
      else
        out[key].value = value
      end
    end
  end

  return out
end

---@param tools table<CopilotChat.client.Tool>?
---@return table
local function summarize_tools(tools)
  return vim.tbl_map(function(tool)
    local properties = {}
    if tool.schema and tool.schema.properties then
      properties = vim.tbl_keys(tool.schema.properties)
      table.sort(properties)
    end

    return {
      name = tool.name,
      description = preview_text(tool.description, 120),
      schema_properties = properties,
    }
  end, tools or {})
end

---@param resources table<CopilotChat.client.Resource>?
---@return table
local function summarize_resources(resources)
  return vim.tbl_map(function(resource)
    return {
      uri = resource.uri,
      name = resource.name,
      mimetype = resource.mimetype,
      data_length = resource.data and #resource.data or 0,
      data_preview = preview_text(resource.data, 160),
      annotations = resource.annotations,
    }
  end, resources or {})
end

---@param messages table<CopilotChat.client.Message>
---@return table
local function summarize_messages(messages)
  return vim.tbl_map(function(message)
    local out = {
      role = message.role,
      content_length = message.content and #message.content or 0,
      content_preview = preview_text(message.content, 160),
      reasoning_length = message.reasoning and #message.reasoning or 0,
      tool_call_id = message.tool_call_id,
      model = message.model,
    }

    if message.tool_calls then
      out.tool_calls = vim.tbl_map(function(tool_call)
        return {
          id = tool_call.id,
          index = tool_call.index,
          name = tool_call.name,
          arguments_length = tool_call.arguments and #tool_call.arguments or 0,
          arguments_preview = preview_text(tool_call.arguments, 160),
        }
      end, message.tool_calls)
    end

    return out
  end, messages or {})
end

---@param request table
---@return table
local function summarize_request(request)
  local summary = {
    model = request.model,
    stream = request.stream,
    messages_count = request.messages and #request.messages or nil,
    input_count = request.input and #request.input or nil,
    tools_count = request.tools and #request.tools or 0,
    instructions_length = request.instructions and #request.instructions or 0,
  }

  local ok, inspected = pcall(vim.inspect, sanitize_for_log(request), { indent = '  ' })
  summary.preview = ok and preview_text(inspected, 2000) or '<inspect failed>'
  return summary
end

---@param trace table
---@param event string
---@param data any
local function add_trace(trace, event, data)
  local entry = {
    at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    event = event,
    data = sanitize_for_log(data),
  }
  table.insert(trace, entry)

  local ok, inspected = pcall(vim.inspect, entry, { indent = '  ' })
  if ok then
    log.debug('CopilotChat ask trace:\n' .. inspected)
  else
    log.debug('CopilotChat ask trace event: ' .. event)
  end
end

---@param job_id string
---@param trace table
---@param reason string
---@param extra any
local function dump_trace(job_id, trace, reason, extra)
  local payload = {
    job_id = job_id,
    reason = reason,
    extra = sanitize_for_log(extra),
    trace = trace,
  }

  local ok, inspected = pcall(vim.inspect, payload, { indent = '  ' })
  if ok then
    log.error('CopilotChat ask trace dump:\n' .. inspected)
  else
    log.error('CopilotChat ask trace dump failed for job ' .. job_id .. ': ' .. reason)
  end
end

--- Generate resource block with line numbers, truncating if necessary
---@param content string
---@param start_line number: The starting line number
---@return string
local function generate_resource_block(content, mimetype, name, path, start_line, end_line)
  local lines = vim.split(content, '\n')
  local total_lines = #lines
  local max_length = #tostring(total_lines)
  for i, line in ipairs(lines) do
    local formatted_line_number = string.format('%' .. max_length .. 'd', i - 1 + (start_line or 1))
    lines[i] = formatted_line_number .. ': ' .. line
  end

  local updated_content = table.concat(lines, '\n')
  local filetype = files.mimetype_to_filetype(mimetype or 'text')
  if not start_line then
    start_line = 1
  end
  if not end_line then
    end_line = start_line and (start_line + total_lines - 1) or 1
  end

  if path then
    return string.format(RESOURCE_LONG_FORMAT, name, filetype, path, start_line, end_line, updated_content)
  else
    return string.format(RESOURCE_SHORT_FORMAT, name, filetype, start_line, end_line, updated_content)
  end
end

--- Generate messages for the given resources
--- @param resources CopilotChat.client.Resource[]
--- @return table<CopilotChat.client.Message>
local function generate_resource_messages(resources)
  return vim
    .iter(resources or {})
    :filter(function(resource)
      return resource.data and resource.data ~= ''
    end)
    :map(function(resource)
      local start_line = resource.annotations and resource.annotations.start_line or 1
      local end_line = resource.annotations and resource.annotations.end_line or nil
      return {
        content = generate_resource_block(
          resource.data,
          resource.mimetype,
          resource.uri,
          resource.name,
          start_line,
          end_line
        ),
        role = constants.ROLE.USER,
      }
    end)
    :totable()
end

--- Generate ask request
--- @param system_prompt string
--- @param history table<CopilotChat.client.Message>
--- @param generated_messages table<CopilotChat.client.Message>
local function generate_ask_request(system_prompt, history, generated_messages)
  local messages = {}

  system_prompt = vim.trim(system_prompt)

  -- Include system prompt
  if not utils.empty(system_prompt) then
    table.insert(messages, {
      content = system_prompt,
      role = constants.ROLE.SYSTEM,
    })
  end

  -- Include generated messages and history
  vim.list_extend(messages, generated_messages)
  vim.list_extend(messages, history)
  return messages
end

---@class CopilotChat.client.Client : Class
---@field private provider_resolver function():table<string, CopilotChat.config.providers.Provider>
---@field private provider_cache table<string, table>
---@field private current_job string?
local Client = class(function(self)
  self.provider_resolver = nil
  self.provider_cache = vim.defaulttable(function()
    return {}
  end)
  self.current_job = nil
end)

--- Get all providers from the client
---@param supported_method? string: The method to filter providers by (optional)
---@return OrderedMap<string, CopilotChat.config.providers.Provider>
function Client:get_providers(supported_method)
  local out = orderedmap()

  if not self.provider_resolver then
    return out
  end

  local providers = self.provider_resolver()
  local provider_names = vim.tbl_keys(providers)
  table.sort(provider_names)

  for _, provider_name in ipairs(provider_names) do
    local provider = providers[provider_name]
    if provider and not provider.disabled and (not supported_method or provider[supported_method]) then
      out:set(provider_name, provider)
    end
  end
  return out
end

--- Set a provider resolver on the client
---@param resolver function: A function that returns a table of providers
function Client:set_providers(resolver)
  self.provider_resolver = resolver
end

--- Authenticate with GitHub and get the required headers
---@param provider_name string: The provider to authenticate with
---@return table<string, string>
function Client:authenticate(provider_name)
  local provider = self:get_providers():get(provider_name)
  local headers = self.provider_cache[provider_name].headers
  local expires_at = self.provider_cache[provider_name].expires_at

  if provider.get_headers and (not headers or (expires_at and expires_at <= math.floor(os.time()))) then
    headers, expires_at = provider.get_headers()
    self.provider_cache[provider_name].headers = headers
    self.provider_cache[provider_name].expires_at = expires_at
  end

  return headers or {}
end

--- Fetch models from the Copilot API
---@return table<string, CopilotChat.client.Model>
function Client:models()
  local out = {}
  local providers = self:get_providers('get_models')

  for _, provider_name in ipairs(providers:keys()) do
    local provider = providers:get(provider_name)
    for _, model in
      ipairs(get_cached(self.provider_cache[provider_name], 'models', function()
        notify.publish(notify.STATUS, 'Fetching models from ' .. provider_name)

        local ok, headers = pcall(self.authenticate, self, provider_name)
        if not ok then
          log.warn('Failed to authenticate with ' .. provider_name .. ': ' .. headers)
          return {}
        end

        local ok, models = pcall(provider.get_models, headers)
        if not ok then
          log.warn('Failed to fetch models from ' .. provider_name .. ': ' .. models)
          return {}
        end

        return models or {}
      end))
    do
      model.provider = provider_name
      if out[model.id] then
        model.id = model.id .. ':' .. provider_name
      end
      out[model.id] = model
    end
  end

  log.debug('Fetched models:', #vim.tbl_keys(out))
  return out
end

--- Get information about all providers
---@return table<string, string[]>
function Client:info()
  local out = {}
  local providers = self:get_providers('get_info')

  for _, provider_name in ipairs(providers:keys()) do
    local provider = providers:get(provider_name)
    out[provider_name] = get_cached(self.provider_cache[provider_name], 'infos', function()
      notify.publish(notify.STATUS, 'Fetching info from ' .. provider_name)

      local ok, headers = pcall(self.authenticate, self, provider_name)
      if not ok then
        log.warn('Failed to authenticate with ' .. provider_name .. ': ' .. headers)
        return {}
      end

      local ok, infos = pcall(provider.get_info, headers)
      if not ok then
        log.warn('Failed to fetch info from ' .. provider_name .. ': ' .. infos)
        return {}
      end

      return infos or {}
    end)
  end

  log.debug('Fetched provider infos:', #vim.tbl_keys(out))
  return out
end

--- Ask a question to Copilot
---@param opts CopilotChat.client.AskOptions: Options for the request
---@return CopilotChat.client.AskResponse?
function Client:ask(opts)
  opts = opts or {}
  local job_id = utils.uuid()
  local trace = {}

  local function fail(message, extra)
    add_trace(trace, 'error', {
      message = message,
      extra = extra,
    })
    dump_trace(job_id, trace, message, extra)
    error(message)
  end

  add_trace(trace, 'ask_started', {
    job_id = job_id,
    opts = {
      headless = opts.headless,
      model = opts.model,
      temperature = opts.temperature,
      system_prompt_length = opts.system_prompt and #opts.system_prompt or 0,
      tools = summarize_tools(opts.tools),
      resources = summarize_resources(opts.resources),
      history = summarize_messages(opts.history),
    },
  })

  log.debug('Model:', opts.model)
  log.debug('Tools:', #(opts.tools or {}))
  log.debug('Resources:', #(opts.resources or {}))
  log.debug('History:', #(opts.history or {}))

  local models = self:models()
  add_trace(trace, 'models_loaded', {
    requested_model = opts.model,
    available_model_ids = vim.tbl_keys(models),
    models = summarize_models(models),
  })

  local model_config = models[opts.model]
  if not model_config then
    fail('Model not found: ' .. tostring(opts.model), {
      requested_model = opts.model,
      available_models = summarize_models(models),
    })
  end

  local provider_name = model_config.provider
  if not provider_name then
    fail('Provider not found for model: ' .. tostring(opts.model), {
      requested_model = opts.model,
      model_config = model_config,
    })
  end

  add_trace(trace, 'model_selected', {
    requested_model = opts.model,
    provider_name = provider_name,
    model_config = model_config,
  })

  local provider = self:get_providers():get(provider_name)
  if not provider then
    fail('Provider not found: ' .. provider_name, {
      requested_model = opts.model,
      provider_name = provider_name,
      available_providers = self:get_providers():keys(),
    })
  end

  if provider.resolve_model then
    add_trace(trace, 'resolve_model_started', {
      provider_name = provider_name,
      requested_model = opts.model,
      provider_cache = summarize_provider_cache(self.provider_cache[provider_name]),
    })

    local ok_headers, headers = pcall(self.authenticate, self, provider_name)
    if not ok_headers then
      fail('Failed to authenticate provider: ' .. provider_name, {
        provider_name = provider_name,
        authenticate_error = headers,
        provider_cache = summarize_provider_cache(self.provider_cache[provider_name]),
      })
    end

    add_trace(trace, 'provider_authenticated', {
      provider_name = provider_name,
      headers = headers,
      provider_cache = summarize_provider_cache(self.provider_cache[provider_name]),
    })

    local requested_model = opts.model
    local ok_resolve, resolved_model = pcall(provider.resolve_model, headers, opts.model)
    if not ok_resolve then
      fail('Failed to resolve model: ' .. tostring(requested_model), {
        provider_name = provider_name,
        requested_model = requested_model,
        resolve_error = resolved_model,
        provider_cache = summarize_provider_cache(self.provider_cache[provider_name]),
      })
    end

    opts.model = resolved_model
    add_trace(trace, 'resolve_model_finished', {
      provider_name = provider_name,
      requested_model = requested_model,
      resolved_model = resolved_model,
      same_provider_model_ids = model_ids_for_provider(models, provider_name),
      provider_cache = summarize_provider_cache(self.provider_cache[provider_name]),
    })

    model_config = models[opts.model]
    if not model_config then
      fail('Resolved model not found: ' .. tostring(opts.model), {
        provider_name = provider_name,
        requested_model = requested_model,
        resolved_model = resolved_model,
        same_provider_model_ids = model_ids_for_provider(models, provider_name),
        available_models = summarize_models(models),
        provider_cache = summarize_provider_cache(self.provider_cache[provider_name]),
      })
    end
  end

  local options = {
    model = vim.tbl_extend('force', model_config, {
      id = opts.model:gsub(':' .. provider_name .. '$', ''),
    }),
    temperature = opts.temperature,
    tools = opts.tools,
  }

  add_trace(trace, 'request_options_prepared', {
    provider_name = provider_name,
    resolved_model = opts.model,
    options = sanitize_for_log(options),
  })

  local max_tokens = model_config.max_input_tokens
  local tokenizer = model_config.tokenizer or 'o200k_base'
  log.debug('Tokenizer:', tokenizer)

  if max_tokens and tokenizer then
    add_trace(trace, 'tokenizer_loading_started', {
      tokenizer = tokenizer,
      max_tokens = max_tokens,
    })

    local ok_load, load_err = pcall(tiktoken.load, tiktoken, tokenizer)
    if not ok_load then
      fail('Failed to load tokenizer: ' .. tostring(tokenizer), {
        tokenizer = tokenizer,
        error = load_err,
        provider_name = provider_name,
        resolved_model = opts.model,
      })
    end

    add_trace(trace, 'tokenizer_loading_finished', {
      tokenizer = tokenizer,
      max_tokens = max_tokens,
    })
  end

  if not opts.headless then
    notify.publish(notify.STATUS, 'Generating request')
  end

  local history = vim.deepcopy(opts.history)
  local tool_calls = orderedmap()
  local generated_messages = {}
  local resource_messages = generate_resource_messages(opts.resources)

  add_trace(trace, 'resource_messages_generated', {
    resource_messages = summarize_messages(resource_messages),
  })

  if max_tokens then
    -- Count required tokens that we cannot reduce
    local system_tokens = tiktoken:count(opts.system_prompt)
    local prompt_tokens = #history > 0 and tiktoken:count(history[#history].content) or 0
    local resource_tokens = #resource_messages > 0 and tiktoken:count(resource_messages[1].content) or 0
    local required_tokens = prompt_tokens + system_tokens + resource_tokens

    log.debug('System tokens:', system_tokens)
    log.debug('Prompt tokens:', prompt_tokens)
    log.debug('Resource tokens:', resource_tokens)

    -- Calculate how many tokens we can use for history
    local history_limit = max_tokens - required_tokens
    local history_tokens = 0
    for _, msg in ipairs(history) do
      history_tokens = history_tokens + tiktoken:count(msg.content)
    end

    add_trace(trace, 'token_budget_computed', {
      max_tokens = max_tokens,
      tokenizer = tokenizer,
      system_tokens = system_tokens,
      prompt_tokens = prompt_tokens,
      resource_tokens = resource_tokens,
      required_tokens = required_tokens,
      history_limit = history_limit,
      history_tokens_before_trim = history_tokens,
    })

    -- Remove history messages except prompt until we are under the limit
    local removed_history = {}
    while history_tokens > history_limit and #history > 1 do
      local entry = table.remove(history, 1)
      history_tokens = history_tokens - tiktoken:count(entry.content)
      table.insert(removed_history, {
        role = entry.role,
        content_length = entry.content and #entry.content or 0,
        content_preview = preview_text(entry.content, 120),
      })
    end

    -- Now add as many files as possible with remaining token budget
    local remaining_tokens = max_tokens - required_tokens - history_tokens
    local included_resources = {}
    local skipped_resources = {}
    for _, message in ipairs(resource_messages) do
      local tokens = tiktoken:count(message.content)
      if remaining_tokens - tokens >= 0 then
        remaining_tokens = remaining_tokens - tokens
        table.insert(generated_messages, message)
        table.insert(included_resources, {
          content_length = #message.content,
          tokens = tokens,
          preview = preview_text(message.content, 120),
        })
      else
        table.insert(skipped_resources, {
          content_length = #message.content,
          tokens = tokens,
          preview = preview_text(message.content, 120),
        })
        break
      end
    end

    add_trace(trace, 'token_budget_applied', {
      history_tokens_after_trim = history_tokens,
      removed_history = removed_history,
      remaining_tokens = remaining_tokens,
      included_resources = included_resources,
      skipped_resources = skipped_resources,
      final_history = summarize_messages(history),
      generated_messages = summarize_messages(generated_messages),
    })
  else
    -- Add all embedding messages as we cant limit them
    for _, message in ipairs(resource_messages) do
      table.insert(generated_messages, message)
    end

    add_trace(trace, 'token_budget_skipped', {
      reason = 'model_has_no_max_input_tokens',
      final_history = summarize_messages(history),
      generated_messages = summarize_messages(generated_messages),
    })
  end

  local errored = nil
  local finished = false
  local token_count = 0
  local out_model = nil
  local response_content_buffer = stringbuffer()
  local response_reasoning_buffer = stringbuffer()

  local function finish_stream(err, job)
    if err then
      errored = err
    end

    add_trace(trace, 'stream_finished', {
      error = err,
      current_job = self.current_job,
      finished = true,
    })

    log.debug('Finishing stream', err)
    finished = true

    if job then
      job:shutdown(0)
    end
  end

  local function parse_line(line, job)
    if not line or line == '' then
      return
    end

    if not opts.headless then
      notify.publish(notify.STATUS, '')
    end

    local content, err = utils.json_decode(line)

    if err then
      add_trace(trace, 'stream_json_decode_failed', {
        line_preview = preview_text(line, 500),
        error = err,
      })
      finish_stream(line, job)
      return
    end

    if type(content) ~= 'table' then
      add_trace(trace, 'stream_non_table_payload', {
        payload = content,
      })
      finish_stream(content, job)
      return
    end

    local out = provider.prepare_output(content, options)
    add_trace(trace, 'provider_output_received', {
      finish_reason = out.finish_reason,
      total_tokens = out.total_tokens,
      model = out.model,
      content_preview = preview_text(out.content, 160),
      reasoning_preview = preview_text(out.reasoning, 160),
      tool_calls = out.tool_calls,
    })

    if out.total_tokens then
      token_count = out.total_tokens
    end

    if out.tool_calls then
      for _, tool_call in ipairs(out.tool_calls) do
        local key = tostring(tool_call.index or tool_call.id or tool_call.name or #tool_calls:values() + 1)
        local existing = tool_calls:get(key)

        if not existing then
          tool_calls:set(key, tool_call)
        else
          existing.arguments = existing.arguments .. tool_call.arguments
          if tool_call.id then
            existing.id = tool_call.id
          end
          if tool_call.index then
            existing.index = tool_call.index
          end
          if tool_call.name then
            existing.name = tool_call.name
          end
        end
      end
    end

    if out.content then
      response_content_buffer:put(out.content)
    end

    if out.reasoning then
      response_reasoning_buffer:put(out.reasoning)
    end

    if out.model then
      out_model = out.model
    end

    if opts.on_progress then
      opts.on_progress({
        role = constants.ROLE.ASSISTANT,
        content = out.content or '',
        reasoning = out.reasoning or '',
      })
    end

    if out.finish_reason then
      local reason = out.finish_reason
      if reason == 'stop' or reason == 'tool_calls' then
        reason = nil
      else
        reason = 'Early stop: ' .. reason
      end
      finish_stream(reason, job)
    end
  end

  local function parse_stream_line(line, job)
    line = vim.trim(line)

    -- Ignore SSE event names and comments
    if vim.startswith(line, 'event:') or vim.startswith(line, ':') then
      return
    end

    line = line:gsub('^data:%s*', '')
    if line == '[DONE]' then
      add_trace(trace, 'stream_done_marker_received', {})
      finish_stream(nil, job)
      return
    end

    parse_line(line, job)
  end

  local function stream_func(err, line, job)
    if not line or errored or finished then
      return
    end

    if not opts.headless and self.current_job ~= job_id then
      add_trace(trace, 'stream_stopped_due_to_job_switch', {
        current_job = self.current_job,
        expected_job = job_id,
      })
      finish_stream(nil, job)
      return
    end

    if err then
      add_trace(trace, 'stream_callback_error', {
        error = err,
        line_preview = preview_text(line, 500),
      })
      finish_stream(err and err or line, job)
      return
    end

    parse_stream_line(line, job)
  end

  if not opts.headless then
    notify.publish(notify.STATUS, 'Thinking')
    self.current_job = job_id
  end

  local ok_headers, headers = pcall(self.authenticate, self, provider_name)
  if not ok_headers then
    fail('Failed to authenticate provider: ' .. provider_name, {
      provider_name = provider_name,
      authenticate_error = headers,
      provider_cache = summarize_provider_cache(self.provider_cache[provider_name]),
    })
  end

  add_trace(trace, 'request_auth_headers_ready', {
    provider_name = provider_name,
    headers = headers,
    provider_cache = summarize_provider_cache(self.provider_cache[provider_name]),
  })

  local request_messages = generate_ask_request(opts.system_prompt, history, generated_messages)
  add_trace(trace, 'request_messages_ready', {
    messages = summarize_messages(request_messages),
  })

  local ok_prepare, request, extra_headers = pcall(provider.prepare_input, request_messages, options)
  if not ok_prepare then
    fail('Failed to prepare request for provider: ' .. provider_name, {
      provider_name = provider_name,
      error = request,
      resolved_model = opts.model,
      options = options,
      request_messages = summarize_messages(request_messages),
    })
  end

  if extra_headers then
    headers = vim.tbl_extend('force', headers, extra_headers)
  end

  add_trace(trace, 'request_prepared', {
    provider_name = provider_name,
    resolved_model = opts.model,
    extra_headers = extra_headers,
    final_headers = headers,
    request = summarize_request(request),
  })

  local is_stream = request.stream

  local args = {
    json_request = true,
    body = request,
    headers = headers,
  }
  if is_stream then
    args.stream = stream_func
  end

  local ok_url, url_or_err = pcall(provider.get_url, options)
  if not ok_url then
    fail('Failed to get provider url: ' .. provider_name, {
      provider_name = provider_name,
      error = url_or_err,
      resolved_model = opts.model,
      options = options,
    })
  end

  add_trace(trace, 'request_dispatching', {
    provider_name = provider_name,
    url = url_or_err,
    is_stream = is_stream,
    args = {
      json_request = args.json_request,
      headers = args.headers,
      body = summarize_request(args.body),
      has_stream_callback = args.stream ~= nil,
    },
  })

  local response, err = curl.post(url_or_err, args)

  if response then
    log.debug('API response status:', response.status)
    log.debug('API response body:\n' .. (response.body or '<empty>'))
  end

  if not opts.headless then
    if self.current_job ~= job_id then
      add_trace(trace, 'request_aborted_due_to_job_switch', {
        current_job = self.current_job,
        expected_job = job_id,
      })
      return
    end

    self.current_job = nil
  end

  if err then
    local error_msg = 'Failed to get response: ' .. err

    if response then
      if response.status == 401 then
        local content = utils.json_decode(response.body)
        if content.authorize_url then
          error_msg = 'Failed to authenticate. Visit following url to authorize '
            .. content.slug
            .. ':\n'
            .. content.authorize_url
        end
      else
        error_msg = 'Failed to get response: ' .. tostring(response.status) .. '\n' .. response.body
      end
    end

    fail(error_msg, {
      provider_name = provider_name,
      url = url_or_err,
      response = response and sanitize_for_log(response) or nil,
      err = err,
    })
  end

  if errored then
    fail(tostring(errored), {
      provider_name = provider_name,
      url = url_or_err,
      partial_response = response and sanitize_for_log(response) or nil,
    })
  end

  local response_text = response_content_buffer:tostring()
  local response_reasoning = response_reasoning_buffer:tostring()

  if response then
    add_trace(trace, 'response_received', {
      status = response.status,
      body_preview = preview_text(response.body, 1000),
      is_stream = is_stream,
    })

    if is_stream then
      if utils.empty(response_text) and not finished then
        add_trace(trace, 'stream_fallback_body_parse_started', {
          body_preview = preview_text(response.body, 1000),
        })

        for _, line in ipairs(vim.split(response.body, '\n')) do
          parse_stream_line(line)
        end
      end
    else
      parse_line(response.body)
    end
    response_text = response_content_buffer:tostring()
    response_reasoning = response_reasoning_buffer:tostring()
  end

  -- Filter out tool calls that don't have names (streaming deltas used only for accumulation)
  local final_tool_calls = vim.tbl_filter(function(tc)
    return tc.name ~= nil
  end, tool_calls:values())

  add_trace(trace, 'ask_finished', {
    provider_name = provider_name,
    resolved_model = opts.model,
    response_content_length = #response_text,
    response_content_preview = preview_text(response_text, 300),
    response_reasoning_length = #response_reasoning,
    response_reasoning_preview = preview_text(response_reasoning, 300),
    token_count = token_count,
    token_max_count = max_tokens,
    output_model = out_model,
    final_tool_calls = final_tool_calls,
  })

  return {
    message = {
      role = constants.ROLE.ASSISTANT,
      content = response_text,
      reasoning = response_reasoning,
      tool_calls = #final_tool_calls > 0 and final_tool_calls or nil,
      model = out_model,
    },
    token_count = token_count,
    token_max_count = max_tokens,
  }
end

--- Stop the running job
---@return boolean
function Client:stop()
  if self.current_job ~= nil then
    self.current_job = nil
    return true
  end

  return false
end

--- Check if there is a running job
---@return boolean
function Client:running()
  return self.current_job ~= nil
end

--- @type CopilotChat.client.Client
return Client()
