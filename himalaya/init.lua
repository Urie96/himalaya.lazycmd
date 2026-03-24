-- himalaya.lazycmd - Interactive email viewer for himalaya CLI
-- https://github.com/soywod/himalaya

local M = {}

-- 缓存系统
local cache = {
  -- system: lc.system 命令输出缓存，键为命令行参数的连接字符串
  system = {},
}

-- 分页状态
local pagination = {
  current_account = nil, -- 当前账号
  current_folder = nil, -- 当前文件夹
  current_page = 1, -- 当前页码（从 1 开始）
  entries = {}, -- 当前所有 entries
  loading = false, -- 是否正在加载下一页
  reached_end = false, -- 是否已到末尾
}

-- 生成缓存键（用于 lc.system）
local function system_cache_key(cmd_args)
  -- 将命令参数表连接成字符串作为缓存键
  return table.concat(cmd_args, '\x00')
end

-- 带缓存的 lc.system 包装函数
local function cached_system(cmd_args, cb)
  local key = system_cache_key(cmd_args)

  -- 检查缓存
  if cache.system[key] then
    lc.log('debug', 'Cache hit for command: {}', table.concat(cmd_args, ' '))
    cb(cache.system[key])
    return
  end

  lc.log('debug', 'Cache miss for command: {}', table.concat(cmd_args, ' '))

  -- 执行命令
  lc.system(cmd_args, function(output)
    -- 保存到缓存
    cache.system[key] = output
    cb(output)
  end)
end

-- 解析账号列表
local function parse_accounts(output)
  local success, data = pcall(lc.json.decode, output.stdout)
  if not success or type(data) ~= 'table' then return {}, (data or 'Invalid JSON') end

  local entries = {}
  for _, account in ipairs(data) do
    table.insert(entries, {
      key = account.name,
      display = account.name,
      account = account.name,
    })
  end

  return entries
end

-- 解析文件夹列表
local function parse_folders(output, account)
  local success, data = pcall(lc.json.decode, output.stdout)
  if not success or type(data) ~= 'table' then return {}, (data or 'Invalid JSON') end

  local entries = {}
  for _, folder in ipairs(data) do
    local display = folder.name
    if folder.unseen and folder.unseen > 0 then display = display .. ' (' .. tostring(folder.unseen) .. ')' end
    table.insert(entries, {
      key = folder.name,
      display = display,
      account = account,
    })
  end

  return entries
end

-- 解析信封列表
local function parse_envelopes(output, account, folder)
  local success, data = pcall(lc.json.decode, output.stdout)
  if not success or type(data) ~= 'table' then return {}, (data or 'Invalid JSON') end

  local entries = {}
  for _, envelope in ipairs(data) do
    local display_parts = {}

    -- 解析日期为时间戳
    if envelope.date then
      local success, parsed = pcall(lc.time.parse, envelope.date)
      if success then
        envelope.timestamp = parsed
        table.insert(display_parts, lc.time.format(envelope.timestamp, 'compact'):fg 'yellow')
        table.insert(display_parts, ' ')
      end
    end

    -- 添加主题
    table.insert(display_parts, (envelope.subject or '(no subject)'):fg 'green')

    -- 添加发件人信息
    if envelope.from and envelope.from.name then
      table.insert(display_parts, ' - ')
      table.insert(display_parts, envelope.from.name:fg 'blue')
    elseif envelope.from and envelope.from.addr then
      table.insert(display_parts, ' - ' .. envelope.from.addr)
    end

    -- 添加附件标记
    if envelope.has_attachment then table.insert(display_parts, (' [A]'):fg 'yellow') end

    table.insert(entries, {
      key = tostring(envelope.id),
      display = lc.style.line(display_parts),
      id = envelope.id,
      account = account,
      folder = folder,
      -- 存储信封数据用于快速预览
      envelope = envelope,
    })
  end

  return entries
end

-- 解析邮件内容（从 himalaya 输出中提取正文）
local function parse_message(output)
  local text = output.stdout
  if not text or text == '' then return nil, 'Empty message' end

  -- 纯文本格式：解析头部并提取正文
  -- 查找头部和正文的分隔位置（连续两个换行）
  local header_end = string.find(text, '\n\n', 1, true)

  if not header_end then
    -- 没有找到分隔，整个文本作为正文
    return { body = text }
  end

  -- 提取头部部分
  local header_text = string.sub(text, 1, header_end - 1)

  -- 解析 Cc 字段（直接提取，不做复杂解析）
  local cc_str = nil
  local cc_match = string.match(header_text, '\nCc:([^\n]*)')
  if cc_match then
    cc_str = cc_match:trim()
    if cc_str == '' then cc_str = nil end
  end

  -- 提取正文部分（跳过分隔符后的空行）
  local body = string.sub(text, header_end + 2)
  -- 去除开头和结尾的空白
  body = body:trim()

  local result = { body = body }
  if cc_str then
    result.cc_str = cc_str -- 存储为字符串
  end

  return result
end

-- 格式化单个地址对象
local function format_addr(addr_obj)
  if not addr_obj then return nil end
  if addr_obj.name and addr_obj.addr then
    return addr_obj.name .. ' <' .. addr_obj.addr .. '>'
  elseif addr_obj.name then
    return addr_obj.name
  elseif addr_obj.addr then
    return addr_obj.addr
  end
  return nil
end

-- 格式化地址列表（可能是对象、数组或 nil）
local function format_addrs(addrs)
  if not addrs then return nil end

  -- 处理字符串格式
  if type(addrs) == 'string' then return addrs ~= '' and addrs or nil end

  -- 处理数组或单个对象
  local addr_list = type(addrs) == 'table' and addrs[1] and addrs or { addrs }
  local result = {}

  for _, addr_obj in ipairs(addr_list) do
    local formatted = format_addr(addr_obj)
    if formatted then table.insert(result, formatted) end
  end

  return #result > 0 and table.concat(result, ', ') or nil
end

-- 构建邮件头部信息行
local function build_header_lines(message)
  local lines = {}

  -- 主题
  if message.subject then
    table.insert(lines, lc.style.line { ('Subject: '):fg 'cyan', message.subject:fg 'green' })
    table.insert(lines, '')
  end

  -- 发件人
  if message.from then
    local from_str = format_addr(message.from)
    table.insert(lines, lc.style.line { ('From: '):fg 'cyan', (from_str or 'Unknown'):fg 'yellow' })
  end

  -- 收件人
  local to_str = format_addrs(message.to)
  if to_str then table.insert(lines, lc.style.line { ('To: '):fg 'cyan', to_str:fg 'yellow' }) end

  -- 抄送
  local cc_str = message.cc_str or format_addrs(message.cc)
  if cc_str then table.insert(lines, lc.style.line { ('Cc: '):fg 'cyan', cc_str:fg 'yellow' }) end

  -- 日期（格式化为 年/月/日 时:分:秒）
  if message.timestamp then
    table.insert(
      lines,
      lc.style.line { ('Date: '):fg 'cyan', lc.time.format(message.timestamp, '%Y/%m/%d %H:%M:%S'):fg 'yellow' }
    )
  end

  -- 附件
  table.insert(lines, '')
  if message.has_attachment then
    table.insert(lines, lc.style.line { ('Attachments: '):fg 'cyan', ('yes'):fg 'yellow' })
  else
    table.insert(lines, lc.style.line { ('Attachments: '):fg 'cyan', ('none'):fg 'gray' })
  end

  return lines
end

-- 构建邮件预览（完整版）
local function build_preview(message)
  if not message then return 'No message data' end

  -- 如果只有 body 字段且是纯文本，直接返回
  if type(message.body) == 'string' and not message.subject and not message.from then return message.body end

  local lines = build_header_lines(message)

  -- 分隔线
  table.insert(lines, '')
  table.insert(lines, string.rep('─', 50))
  table.insert(lines, '')

  -- 邮件正文
  if message.body then table.insert(lines, message.body) end

  return lc.style.text(lines)
end

-- 构建初始预览（使用信封数据，显示 loading 状态）
local function build_loading_preview(envelope)
  if not envelope then return 'No envelope data' end

  local lines = build_header_lines(envelope)

  -- 分隔线
  table.insert(lines, '')
  table.insert(lines, string.rep('─', 50))
  table.insert(lines, '')

  -- Loading 提示
  table.insert(lines, '正文 loading 中...')

  return lc.style.text(lines)
end

-- 合并信封数据和消息正文
local function merge_envelope_and_body(envelope, body_message)
  local merged = {
    subject = envelope.subject,
    from = envelope.from,
    to = envelope.to,
    cc = envelope.cc,
    cc_str = body_message.cc_str,
    timestamp = envelope.timestamp,
    has_attachment = envelope.has_attachment,
    body = body_message.body,
  }
  return merged
end

-- 加载下一页邮件
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
    'himalaya',
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
      pagination.current_page = pagination.current_page - 1 -- 回退页码
      pagination.reached_end = true
      lc.notify 'End of messages'
      return
    end

    local new_entries, err = parse_envelopes(output, account, folder)
    if err then
      lc.log('error', 'Failed to parse page {}: {}', pagination.current_page, err)
      pagination.current_page = pagination.current_page - 1 -- 回退页码
      pagination.reached_end = true
      lc.notify 'End of messages'
      return
    end

    if #new_entries == 0 then
      -- 没有更多邮件
      lc.log('info', 'No more emails on page {}', pagination.current_page)
      pagination.current_page = pagination.current_page - 1 -- 回退页码
      pagination.reached_end = true
      lc.notify 'End of messages'
      return
    end

    -- 追加新 entries
    for _, entry in ipairs(new_entries) do
      table.insert(pagination.entries, entry)
    end

    -- 更新列表
    lc.api.page_set_entries(pagination.entries)

    lc.log(
      'info',
      'Loaded {} emails from page {} (total: {})',
      #new_entries,
      pagination.current_page,
      #pagination.entries
    )
    lc.notify('Loaded ' .. #new_entries .. ' more emails')
  end)
end

-- 列出内容
function M.list(path, cb)
  -- 根路径：列出所有账号
  if #path == 0 then
    cached_system({ 'himalaya', '--output', 'json', 'account', 'list' }, function(output)
      if output.code ~= 0 then
        lc.notify('Failed to list accounts: ' .. output.stderr)
        cb {}
        return
      end

      local entries, err = parse_accounts(output)
      if err then
        lc.notify('Failed to parse accounts: ' .. tostring(err))
        cb {}
        return
      end

      cb(entries)
    end)

  -- 账号路径：列出该账号的文件夹
  elseif #path == 1 then
    local account = path[1]

    -- 检查持久化缓存（14 天 TTL）
    local cache_key = 'folders:' .. account
    local cached_folders = lc.cache.get(cache_key)
    if cached_folders then
      lc.log('info', 'Using cached folders for account: {}', account)
      cb(cached_folders)
      return
    end

    -- 缓存未命中，执行命令
    lc.system({ 'himalaya', '--output', 'json', 'folder', 'list', '--account', account }, function(output)
      if output.code ~= 0 then
        lc.notify('Failed to list folders: ' .. output.stderr)
        cb {}
        return
      end

      local entries, err = parse_folders(output, account)
      if err then
        lc.notify('Failed to parse folders: ' .. tostring(err))
        cb {}
        return
      end

      -- 缓存文件夹列表，TTL 14 天
      lc.cache.set(cache_key, entries, { ttl = 14 * 24 * 3600 })
      lc.log('info', 'Cached folders for account: {}', account)

      cb(entries)
    end)

  -- 文件夹路径：列出该文件夹的信封
  elseif #path == 2 then
    local account = path[1]
    local folder = path[2]

    -- 检测账号/文件夹变化，重置分页状态
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
      'himalaya',
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
        cb {}
        return
      end

      local entries, err = parse_envelopes(output, account, folder)
      if err then
        lc.log('error', 'Failed to parse envelopes: {}', tostring(err))
        cb {}
        return
      end

      -- 保存到 pagination.entries
      pagination.entries = entries

      cb(entries)
    end)
  end
end

-- 预览内容
function M.preview(entry, cb)
  if not entry or not entry.id or not entry.account or not entry.folder then
    cb 'Select an email to preview'
    return
  end

  -- 检查是否在最后一封邮件，如果是则加载下一页
  local path = lc.api.get_current_path()
  if #path == 2 and not pagination.loading and not pagination.reached_end then
    -- 遍历 pagination.entries 找到当前 entry 的索引
    for i, e in ipairs(pagination.entries) do
      if e.id == entry.id then
        -- 检查是否为最后一项
        if i == #pagination.entries then
          lc.log('info', 'At last email (index {}), loading next page', i)
          load_next_page()
        end
        break
      end
    end
  end

  -- 第一阶段：如果有信封数据，先显示 loading 预览
  if entry.envelope then
    local loading_preview = build_loading_preview(entry.envelope)
    cb(loading_preview)
  end

  -- 第二阶段：异步加载完整邮件内容
  cached_system({
    'himalaya',
    'message',
    'read',
    tostring(entry.id),
    '--account',
    entry.account,
    '--folder',
    entry.folder,
    '--preview',
  }, function(output)
    if output.code ~= 0 then
      local error_msg = output.stderr or 'Unknown error'
      lc.log('error', 'Failed to read message: {}', error_msg)
      cb('Error: ' .. error_msg)
      return
    end

    -- 供<enter>键使用
    entry.read_content = output and output.stdout

    local body_message, err = parse_message(output)
    if err then
      lc.log('error', 'Failed to parse message: {}', err)
      cb('Error: ' .. tostring(err))
      return
    end

    -- 如果有信封数据，合并后构建完整预览
    if entry.envelope then
      local merged = merge_envelope_and_body(entry.envelope, body_message)
      cb(build_preview(merged))
    else
      -- 没有信封数据，直接显示 body
      local preview = build_preview(body_message)
      cb(preview)
    end
  end)
end

-- 设置插件
function M.setup()
  lc.api.append_hook_pre_reload(function()
    cache.system = {}
    -- 重置分页状态
    pagination.current_account = nil
    pagination.current_folder = nil
    pagination.current_page = 1
    pagination.entries = {}
    pagination.loading = false
    pagination.reached_end = false
  end)

  -- <enter> 键：根据路径决定进入下一级或显示操作菜单
  lc.keymap.set('main', '<enter>', function()
    local path = lc.api.get_current_path()

    -- 在邮件列表中（路径长度 >= 2），显示操作菜单
    if #path >= 2 then
      require('himalaya.action').select_action()
    else
      -- 其他情况进入下一级
      lc.cmd 'enter'
    end
  end)

  -- w 键：写新邮件（任何层级都可以）
  lc.keymap.set('main', 'w', function() require('himalaya.action').write() end)
end

return M
