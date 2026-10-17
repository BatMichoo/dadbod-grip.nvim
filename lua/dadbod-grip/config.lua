-- config.lua: plugin options and keymap overrides.
-- Owns the values setup() stores, so modules read options here instead of
-- requiring the plugin entry point (and everything it loads) back.

local M = {}

-- Default options (overridden by setup)
local OPTS = {
  limit       = 1000,
  max_col_width = 40,
  timeout     = 10000,
  connections_path = nil,
  picker      = "builtin",
  pinned_max  = nil,
  border      = "rounded",
  -- Split style for the full-buffer cell editor (gB): "horizontal" opens a
  -- ~40%-height split below the grid, "vertical" a ~40%-width split.
  cell_split  = "horizontal",
  -- Auto-discover local Docker containers tagged with the
  -- dev.localdb.* label set. See sources/docker_localdb.lua. Set false
  -- to disable shelling out to `docker ps` on picker open.
  -- Mirror the grid's column-name row into the window's winbar so it stays
  -- visible when a long table scrolls past it. Costs one screen line.
  sticky_header = true,
  open_sidebar = true,
}

--- Live option table. Read-only for callers outside this module; use get()
--- for a copy that is safe to keep or modify.
M.values = OPTS

--- Keymap overrides from setup({ keymaps = ... }); read by keymaps.get().
M.keymaps = {}

--- Return a copy of the current options.
--- Copied so callers cannot mutate the live config; a deep copy also means a
--- new option added to OPTS is exposed without touching this function.
function M.get()
  return vim.deepcopy(OPTS)
end

--- Validate and store setup() options. Raises on an invalid value.
function M.apply(opts)
  opts = opts or {}
  -- Deliberately the old table form of vim.validate: the per-argument signature
  -- (vim.validate("name", value, "type")) needs Neovim 0.11, we support 0.10.
  vim.validate({
    limit         = { opts.limit,         "number",  true },
    max_col_width = { opts.max_col_width,  "number",  true },
    timeout       = { opts.timeout,        "number",  true },
    connections_path = { opts.connections_path, "string",  true },
    picker           = { opts.picker, function(v)
      return v == nil or v == "builtin" or v == "telescope" or v == "snacks"
    end, '"builtin", "telescope", or "snacks"' },
    keymaps       = { opts.keymaps,        "table",   true },
    pinned_max    = { opts.pinned_max,     "number",  true },
    border        = { opts.border, function(v) return v == nil or type(v) == "string" or type(v) == "table" end, "string, table, or nil" },
    cell_split    = { opts.cell_split, function(v)
      return v == nil or v == "horizontal" or v == "vertical"
    end, '"horizontal" or "vertical"' },
    discovery     = { opts.discovery, "boolean", true },
    sticky_header = { opts.sticky_header, "boolean", true },
    open_sidebar  = { opts.open_sidebar,  "boolean", true },
    databases     = { opts.databases,     "table",   true },
    sqlserver_max_type_width = { opts.sqlserver_max_type_width, function(v)
      return v == nil or (type(v) == "number" and v >= 0 and v <= 8000 and v % 1 == 0)
    end, "integer from 0 to 8000, or nil" },
  })
  OPTS.limit        = opts.limit        or 1000
  OPTS.max_col_width = opts.max_col_width or 40
  OPTS.timeout      = opts.timeout      or 10000
  OPTS.connections_path = opts.connections_path or nil
  OPTS.picker = opts.picker or "builtin"
  if opts.pinned_max ~= nil then OPTS.pinned_max = opts.pinned_max end
  if opts.border ~= nil then OPTS.border = opts.border end
  OPTS.cell_split = opts.cell_split or "horizontal"
  if opts.discovery ~= nil then OPTS.discovery = opts.discovery end
  if opts.sticky_header ~= nil then OPTS.sticky_header = opts.sticky_header end
  OPTS.open_sidebar = opts.open_sidebar ~= false
  OPTS.databases = opts.databases
  OPTS.sqlserver_max_type_width = opts.sqlserver_max_type_width

  if opts.keymaps then
    M.keymaps = opts.keymaps
  end
end

return M
