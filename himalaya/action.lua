local M = {}

-- 辅助函数：获取当前选中的邮件信息
local function get_selected_email()
  local entry = lc.api.page_get_hovered()
  if not entry or not entry.id or not entry.account or not entry.folder then return nil end
  return entry
end

-- 辅助函数：执行 himalaya 命令
local function do_himalaya_action(action_name)
  local entry = get_selected_email()
  if not entry then
    lc.notify 'No email selected'
    return
  end

  lc.log('info', 'Action: {} for message {} in {}/{}', action_name, entry.id, entry.account, entry.folder)

  if action_name == 'export' then
    -- 导出邮件为 EML 文件并用默认程序打开
    local temp_file = '/tmp/lazycmd-message-' .. tostring(entry.id) .. '.eml'

    lc.notify 'Exporting message...'

    lc.system({
      'himalaya',
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
        local error_msg = output.stderr or 'Unknown error'
        lc.notify('Export failed: ' .. error_msg)
        lc.log('error', 'Failed to export message: {}', error_msg)
        return
      end

      lc.log('info', 'Message exported to {}', temp_file)
      lc.system.open(temp_file)
      lc.notify 'Message opened'
    end)
  elseif action_name == 'download' then
    -- 下载附件
    lc.notify 'Downloading attachments...'

    lc.system({
      'himalaya',
      'attachment',
      'download',
      tostring(entry.id),
      '--account',
      entry.account,
      '--folder',
      entry.folder,
    }, function(output)
      if output.code ~= 0 then
        local error_msg = output.stderr or 'Unknown error'
        lc.notify('Download failed: ' .. error_msg)
        lc.log('error', 'Failed to download attachment: {}', error_msg)
      else
        local success_msg = output.stdout and output.stdout:trim() or 'Attachment downloaded'
        lc.notify(success_msg)
        lc.log('info', 'Attachment download output: {}', output.stdout)
      end
    end)
  elseif action_name == 'reply' then
    -- 回复邮件
    lc.interactive({
      'himalaya',
      'message',
      'reply',
      tostring(entry.id),
      '--account',
      entry.account,
      '--folder',
      entry.folder,
    }, function(exit_code)
      if exit_code ~= 0 then
        lc.notify 'Failed to reply to message'
      else
        lc.notify 'Reply sent'
      end
    end)
  elseif action_name == 'delete' then
    -- 删除邮件
    lc.interactive({
      'himalaya',
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

function M.export() do_himalaya_action 'export' end
function M.download() do_himalaya_action 'download' end
function M.reply() do_himalaya_action 'reply' end
function M.delete() do_himalaya_action 'delete' end

function M.write()
  -- 写新邮件
  local path = lc.api.get_current_path()
  if #path < 1 then
    lc.notify 'Please select an account first'
    return
  end

  local account = path[1]
  lc.log('info', 'Writing new message in {}', account)

  lc.interactive({ 'himalaya', 'message', 'write', '--account', account }, function(exit_code)
    if exit_code ~= 0 then
      lc.notify 'Failed to send email'
    else
      lc.notify 'Email sent successfully'
    end
  end)
end

function M.select_action()
  local entry = get_selected_email()
  if not entry then
    lc.notify 'No email selected'
    return
  end

  local options = {}

  -- 导出邮件（在默认程序中打开）
  table.insert(options, {
    value = 'export',
    display = lc.style.line { ('📄 Export'):fg 'cyan' },
  })

  -- 回复邮件
  table.insert(options, {
    value = 'reply',
    display = lc.style.line { ('↩️ Reply'):fg 'green' },
  })

  -- 下载附件
  table.insert(options, {
    value = 'download',
    display = lc.style.line { ('📎 Download Attachments'):fg 'blue' },
  })

  -- 删除邮件（需要确认）
  table.insert(options, {
    value = 'delete',
    display = lc.style.line { ('🗑️ Delete'):fg 'red' },
  })

  lc.select({
    prompt = 'Select an action',
    options = options,
  }, function(choice)
    if not choice then return end

    if choice == 'delete' then
      -- 删除操作需要确认
      lc.confirm {
        title = 'Delete Message',
        prompt = 'Are you sure you want to delete this message?',
        on_confirm = function() require('himalaya.action').delete() end,
      }
    else
      -- 其他操作直接执行
      require('himalaya.action')[choice]()
    end
  end)
end

return M
