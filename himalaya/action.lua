local M = {}

local runtime = {
  cfg = nil,
  pagination = nil,
  cached_system = nil,
  load_next_page = nil,
}

local function get_selected_email()
  local entry = lc.api.get_hovered()
  if not entry or entry.kind ~= 'email' or not entry.id or not entry.account or not entry.folder then return nil end
  return entry
end

local function parse_message(output)
  local body = output.stdout
  if not body or body == '' then return nil, 'Empty message' end

  local header_end = string.find(body, '\n\n', 1, true)
  if not header_end then return { body = body } end

  local header_text = string.sub(body, 1, header_end - 1)
  local cc_str = nil
  local cc_match = string.match(header_text, '\nCc:([^\n]*)')
  if cc_match then
    cc_str = cc_match:trim()
    if cc_str == '' then cc_str = nil end
  end

  body = string.sub(body, header_end + 2):trim()
  local result = { body = body }
  if cc_str then result.cc_str = cc_str end
  return result
end

local function format_addr(addr_obj)
  if not addr_obj then return nil end
  if addr_obj.name and addr_obj.addr then return addr_obj.name .. ' <' .. addr_obj.addr .. '>' end
  if addr_obj.name then return addr_obj.name end
  if addr_obj.addr then return addr_obj.addr end
  return nil
end

local function format_addrs(addrs)
  if not addrs then return nil end
  if type(addrs) == 'string' then return addrs ~= '' and addrs or nil end

  local addr_list = type(addrs) == 'table' and addrs[1] and addrs or { addrs }
  local result = {}
  for _, addr_obj in ipairs(addr_list) do
    local formatted = format_addr(addr_obj)
    if formatted then table.insert(result, formatted) end
  end
  return #result > 0 and table.concat(result, ', ') or nil
end

local function build_header_lines(message)
  local lines = {}

  if message.subject then
    table.insert(lines, lc.style.line { ('Subject: '):fg 'cyan', message.subject:fg 'green' })
    table.insert(lines, '')
  end

  if message.from then
    table.insert(lines, lc.style.line { ('From: '):fg 'cyan', (format_addr(message.from) or 'Unknown'):fg 'yellow' })
  end

  local to_str = format_addrs(message.to)
  if to_str then table.insert(lines, lc.style.line { ('To: '):fg 'cyan', to_str:fg 'yellow' }) end

  local cc_str = message.cc_str or format_addrs(message.cc)
  if cc_str then table.insert(lines, lc.style.line { ('Cc: '):fg 'cyan', cc_str:fg 'yellow' }) end

  if message.timestamp then
    table.insert(
      lines,
      lc.style.line { ('Date: '):fg 'cyan', lc.time.format(message.timestamp, '%Y/%m/%d %H:%M:%S'):fg 'yellow' }
    )
  end

  table.insert(lines, '')
  table.insert(
    lines,
    lc.style.line {
      ('Attachments: '):fg 'cyan',
      (message.has_attachment and 'yes' or 'none'):fg(message.has_attachment and 'yellow' or 'gray'),
    }
  )

  return lines
end

local function build_preview(message)
  if not message then return 'No message data' end
  if type(message.body) == 'string' and not message.subject and not message.from then return message.body end

  local lines = build_header_lines(message)
  table.insert(lines, '')
  table.insert(lines, string.rep('─', 50))
  table.insert(lines, '')
  if message.body then table.insert(lines, message.body) end
  return lc.style.text(lines)
end

local function build_loading_preview(envelope)
  local lines = build_header_lines(envelope)
  table.insert(lines, '')
  table.insert(lines, string.rep('─', 50))
  table.insert(lines, '')
  table.insert(lines, '正文 loading 中...')
  return lc.style.text(lines)
end

local function merge_envelope_and_body(envelope, body_message)
  return {
    subject = envelope.subject,
    from = envelope.from,
    to = envelope.to,
    cc = envelope.cc,
    cc_str = body_message.cc_str,
    timestamp = envelope.timestamp,
    has_attachment = envelope.has_attachment,
    body = body_message.body,
  }
end

local function do_himalaya_action(action_name)
  local entry = get_selected_email()
  if not entry then
    lc.notify 'No email selected'
    return
  end

  if action_name == 'export' then
    local temp_file = '/tmp/lazycmd-message-' .. tostring(entry.id) .. '.eml'
    lc.notify 'Exporting message...'
    lc.system({
      runtime.cfg.command,
      'message',
      'export',
      tostring(entry.id),
      '--account',
      entry.account,
      '--folder',
      entry.folder,
      '-F',
      '-d',
      temp_file,
    }, function(output)
      if output.code ~= 0 then
        lc.notify('Export failed: ' .. (output.stderr or 'Unknown error'))
        return
      end
      lc.system.open(temp_file)
      lc.notify 'Message opened'
    end)
  elseif action_name == 'download' then
    lc.notify 'Downloading attachments...'
    lc.system({
      runtime.cfg.command,
      'attachment',
      'download',
      tostring(entry.id),
      '--account',
      entry.account,
      '--folder',
      entry.folder,
    }, function(output)
      if output.code ~= 0 then
        lc.notify('Download failed: ' .. (output.stderr or 'Unknown error'))
      else
        lc.notify(output.stdout and output.stdout:trim() or 'Attachment downloaded')
      end
    end)
  elseif action_name == 'reply' then
    lc.interactive({
      runtime.cfg.command,
      'message',
      'reply',
      tostring(entry.id),
      '--account',
      entry.account,
      '--folder',
      entry.folder,
    }, function(exit_code)
      lc.notify(exit_code ~= 0 and 'Failed to reply to message' or 'Reply sent')
    end)
  elseif action_name == 'delete' then
    lc.interactive({
      runtime.cfg.command,
      'message',
      'delete',
      tostring(entry.id),
      '--account',
      entry.account,
      '--folder',
      entry.folder,
    }, function(exit_code)
      if exit_code ~= 0 then
        lc.notify 'Failed to delete message'
      else
        lc.notify 'Message deleted'
        lc.cmd 'reload'
      end
    end)
  end
end

function M.setup(opts)
  runtime.cfg = opts.cfg
  runtime.pagination = opts.pagination
  runtime.cached_system = opts.cached_system
  runtime.load_next_page = opts.load_next_page
end

function M.account_preview(entry)
  return lc.style.text {
    lc.style.line { ('Account: '):fg 'cyan', tostring(entry.account or entry.key):fg 'green' },
    '',
    'Enter 查看该账号下的文件夹。',
  }
end

function M.folder_preview(entry)
  return lc.style.text {
    lc.style.line { ('Folder: '):fg 'cyan', tostring(entry.folder or entry.key):fg 'green' },
    lc.style.line { ('Account: '):fg 'cyan', tostring(entry.account or ''):fg 'yellow' },
    '',
    'Enter 查看该文件夹中的邮件。',
  }
end

function M.email_preview(entry, cb)
  if not entry or not entry.id or not entry.account or not entry.folder then
    cb 'Select an email to preview'
    return
  end

  local path = lc.api.get_current_path()
  if #path == 3 and not runtime.pagination.loading and not runtime.pagination.reached_end then
    for i, value in ipairs(runtime.pagination.entries) do
      if value.id == entry.id then
        if i == #runtime.pagination.entries then runtime.load_next_page() end
        break
      end
    end
  end

  if entry.envelope then cb(build_loading_preview(entry.envelope)) end

  runtime.cached_system({
    runtime.cfg.command,
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
      cb('Error: ' .. (output.stderr or 'Unknown error'))
      return
    end

    entry.read_content = output.stdout
    local body_message, err = parse_message(output)
    if err then
      cb('Error: ' .. tostring(err))
      return
    end

    if entry.envelope then
      cb(build_preview(merge_envelope_and_body(entry.envelope, body_message)))
    else
      cb(build_preview(body_message))
    end
  end)
end

function M.info_preview(entry)
  return lc.style.text {
    lc.style.line { (entry.title or 'himalaya'):fg 'cyan' },
    lc.style.line { (entry.message or ''):fg(entry.color or 'darkgray') },
    lc.style.line { (entry.detail or ''):fg 'darkgray' },
  }
end

function M.export() do_himalaya_action 'export' end
function M.download() do_himalaya_action 'download' end
function M.reply() do_himalaya_action 'reply' end
function M.delete() do_himalaya_action 'delete' end

function M.write()
  local path = lc.api.get_current_path()
  if #path < 2 then
    lc.notify 'Please select an account first'
    return
  end

  lc.interactive({ runtime.cfg.command, 'message', 'write', '--account', path[2] }, function(exit_code)
    lc.notify(exit_code ~= 0 and 'Failed to send email' or 'Email sent successfully')
  end)
end

function M.select_action()
  local entry = get_selected_email()
  if not entry then
    lc.notify 'No email selected'
    return
  end

  local options = {
    { value = 'export', display = lc.style.line { ('📄 Export'):fg 'cyan' } },
    { value = 'reply', display = lc.style.line { ('↩️ Reply'):fg 'green' } },
    { value = 'download', display = lc.style.line { ('📎 Download Attachments'):fg 'blue' } },
    { value = 'delete', display = lc.style.line { ('🗑️ Delete'):fg 'red' } },
  }

  lc.select({
    prompt = 'Select an action',
    options = options,
  }, function(choice)
    if not choice then return end
    if choice == 'delete' then
      lc.confirm {
        title = 'Delete Message',
        prompt = 'Are you sure you want to delete this message?',
        on_confirm = function() M.delete() end,
      }
      return
    end
    M[choice]()
  end)
end

return M
