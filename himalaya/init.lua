local action = require 'himalaya.action'
local config = require 'himalaya.config'
local meta = require 'himalaya.meta'

local M = {}
local CACHE_NAMESPACE = 'himalaya'

local cache = {
  system = {},
}

local pagination = {
  current_account = nil,
  current_folder = nil,
  current_page = 1,
  entries = {},
  loading = false,
  reached_end = false,
}

local function system_cache_key(cmd_args)
  return table.concat(cmd_args, '\x00')
end

local function cached_system(cmd_args, cb)
  local key = system_cache_key(cmd_args)
  if cache.system[key] then
    lc.log('debug', 'Cache hit for command: {}', table.concat(cmd_args, ' '))
    cb(cache.system[key])
    return
  end

  lc.log('debug', 'Cache miss for command: {}', table.concat(cmd_args, ' '))
  lc.system(cmd_args, function(output)
    cache.system[key] = output
    cb(output)
  end)
end

local function parse_accounts(output)
  local success, data = pcall(lc.json.decode, output.stdout)
  if not success or type(data) ~= 'table' then return {}, (data or 'Invalid JSON') end

  local entries = {}
  for _, account in ipairs(data) do
    table.insert(entries, {
      key = account.name,
      kind = 'account',
      display = account.name,
      account = account.name,
    })
  end

  return entries
end

local function parse_folders(output, account)
  local success, data = pcall(lc.json.decode, output.stdout)
  if not success or type(data) ~= 'table' then return {}, (data or 'Invalid JSON') end

  local entries = {}
  for _, folder in ipairs(data) do
    local display = folder.name
    if folder.unseen and folder.unseen > 0 then display = display .. ' (' .. tostring(folder.unseen) .. ')' end
    table.insert(entries, {
      key = folder.name,
      kind = 'folder',
      display = display,
      account = account,
      folder = folder.name,
      folder_info = folder,
    })
  end

  return entries
end

local function parse_envelopes(output, account, folder)
  local success, data = pcall(lc.json.decode, output.stdout)
  if not success or type(data) ~= 'table' then return {}, (data or 'Invalid JSON') end

  local entries = {}
  for _, envelope in ipairs(data) do
    local display_parts = {}

    if envelope.date then
      local ok, parsed = pcall(lc.time.parse, envelope.date)
      if ok then
        envelope.timestamp = parsed
        table.insert(display_parts, lc.time.format(envelope.timestamp, 'compact'):fg 'yellow')
        table.insert(display_parts, ' ')
      end
    end

    table.insert(display_parts, (envelope.subject or '(no subject)'):fg 'green')

    if envelope.from and envelope.from.name then
      table.insert(display_parts, ' - ')
      table.insert(display_parts, envelope.from.name:fg 'blue')
    elseif envelope.from and envelope.from.addr then
      table.insert(display_parts, ' - ' .. envelope.from.addr)
    end

    if envelope.has_attachment then table.insert(display_parts, (' [A]'):fg 'yellow') end

    table.insert(entries, {
      key = tostring(envelope.id),
      kind = 'email',
      display = lc.style.line(display_parts),
      id = envelope.id,
      account = account,
      folder = folder,
      envelope = envelope,
    })
  end

  return entries
end

local function load_next_page()
  if pagination.loading or pagination.reached_end then return end

  local account = pagination.current_account
  local folder = pagination.current_folder
  if not account or not folder then return end

  pagination.loading = true
  pagination.current_page = pagination.current_page + 1

  lc.notify('Loading page ' .. pagination.current_page .. '...')
  lc.log('info', 'Loading page {} for {}/{}', pagination.current_page, account, folder)

  cached_system({
    config.get().command,
    '--output',
    'json',
    'envelope',
    'list',
    '--account',
    account,
    '--folder',
    folder,
    '--page',
    tostring(pagination.current_page),
  }, function(output)
    pagination.loading = false

    if output.code ~= 0 then
      lc.log('error', 'Failed to load page {}: {}', pagination.current_page, output.stderr or 'Unknown error')
      pagination.current_page = pagination.current_page - 1
      pagination.reached_end = true
      lc.notify 'End of messages'
      return
    end

    local new_entries, err = parse_envelopes(output, account, folder)
    if err or #new_entries == 0 then
      lc.log('info', 'No more emails on page {}', pagination.current_page)
      pagination.current_page = pagination.current_page - 1
      pagination.reached_end = true
      lc.notify 'End of messages'
      return
    end

    new_entries = meta.attach(new_entries)
    for _, entry in ipairs(new_entries) do
      table.insert(pagination.entries, entry)
    end

    lc.api.page_set_entries(pagination.entries)
    lc.notify('Loaded ' .. #new_entries .. ' more emails')
  end)
end

function M.setup(opt)
  config.setup(opt or {})

  action.setup {
    cfg = config.get(),
    pagination = pagination,
    cached_system = cached_system,
    load_next_page = load_next_page,
  }
  meta.setup(config.get())

  lc.api.append_hook_pre_reload(function()
    cache.system = {}
    pagination.current_account = nil
    pagination.current_folder = nil
    pagination.current_page = 1
    pagination.entries = {}
    pagination.loading = false
    pagination.reached_end = false
  end)
end

function M.list(path, cb)
  if #path == 1 then
    cached_system({ config.get().command, '--output', 'json', 'account', 'list' }, function(output)
      if output.code ~= 0 then
        lc.notify('Failed to list accounts: ' .. output.stderr)
        cb(meta.attach {})
        return
      end

      local entries, err = parse_accounts(output)
      if err then
        lc.notify('Failed to parse accounts: ' .. tostring(err))
        cb(meta.attach {})
        return
      end

      cb(meta.attach(entries))
    end)
    return
  end

  if #path == 2 then
    local account = path[2]
    local folder_cache_key = 'folders:' .. account
    local cached_folders = lc.cache.get(CACHE_NAMESPACE, folder_cache_key)
    if cached_folders then
      lc.log('info', 'Using cached folders for account: {}', account)
      cb(meta.attach(cached_folders))
      return
    end

    lc.system({ config.get().command, '--output', 'json', 'folder', 'list', '--account', account }, function(output)
      if output.code ~= 0 then
        lc.notify('Failed to list folders: ' .. output.stderr)
        cb(meta.attach {})
        return
      end

      local entries, err = parse_folders(output, account)
      if err then
        lc.notify('Failed to parse folders: ' .. tostring(err))
        cb(meta.attach {})
        return
      end

      lc.cache.set(CACHE_NAMESPACE, folder_cache_key, entries, { ttl = config.get().folder_cache_ttl })
      cb(meta.attach(entries))
    end)
    return
  end

  if #path == 3 then
    local account = path[2]
    local folder = path[3]

    if pagination.current_account ~= account or pagination.current_folder ~= folder then
      lc.log('info', 'Folder changed to {}/{}, resetting pagination', account, folder)
      pagination.current_account = account
      pagination.current_folder = folder
      pagination.current_page = 1
      pagination.entries = {}
      pagination.loading = false
      pagination.reached_end = false
    end

    cached_system({
      config.get().command,
      '--output',
      'json',
      'envelope',
      'list',
      '--account',
      account,
      '--folder',
      folder,
      '--page',
      tostring(pagination.current_page),
    }, function(output)
      if output.code ~= 0 then
        lc.log('error', 'Failed to list envelopes: {}', output.stderr or 'Unknown error')
        cb(meta.attach {})
        return
      end

      local entries, err = parse_envelopes(output, account, folder)
      if err then
        lc.log('error', 'Failed to parse envelopes: {}', tostring(err))
        cb(meta.attach {})
        return
      end

      pagination.entries = meta.attach(entries)
      cb(pagination.entries)
    end)
    return
  end

  cb(meta.attach {})
end

return M
