local action = require 'himalaya.action'

local M = {}

local function add_keymap(targets, key, callback, desc)
  if not key or key == '' then return end
  for _, target in ipairs(targets) do
    target[key] = { callback = callback, desc = desc }
  end
end

local metas = {
  account = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        cb(action.account_preview(entry))
      end,
    },
  },
  folder = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        cb(action.folder_preview(entry))
      end,
    },
  },
  email = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        action.email_preview(entry, cb)
      end,
    },
  },
  info = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        cb(action.info_preview(entry))
      end,
    },
  },
}

function M.setup(cfg)
  local keymap = (cfg or {}).keymap or {}
  local account_map = metas.account.__index.keymap
  local folder_map = metas.folder.__index.keymap
  local email_map = metas.email.__index.keymap

  for _, map in ipairs({ account_map, folder_map, email_map }) do
    for key, _ in pairs(map) do
      map[key] = nil
    end
  end

  add_keymap({ account_map, folder_map, email_map }, keymap.write, action.write, 'write new email')
  add_keymap({ email_map }, keymap.action, action.select_action, 'email actions')
end

function M.attach(entries)
  for i, entry in ipairs(entries or {}) do
    local mt = metas[entry.kind]
    if mt then entries[i] = setmetatable(entry, mt) end
  end
  return entries
end

return M
