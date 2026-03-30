local M = {}

local cfg = {
  command = 'himalaya',
  folder_cache_ttl = 14 * 24 * 3600,
  keymap = {
    action = '<enter>',
    write = 'w',
  },
}

function M.setup(opt)
  cfg = lc.tbl_deep_extend('force', cfg, opt or {})
end

function M.get() return cfg end

return M
