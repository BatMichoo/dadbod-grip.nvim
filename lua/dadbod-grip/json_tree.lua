-- json_tree.lua: JSON path drilldown for JSON/JSONB cells (gK).
--
-- Renders a decoded JSON document as a collapsible tree in a float:
--
--   ▾ $: {...} (2 keys)
--       key: "value"
--     ▸ nested: {...} (1 key)
--
-- Float keymaps: <CR>/za toggle node, y yank value, gy yank JSONPath,
-- q/<Esc> close. Opens with the top level expanded and children collapsed,
-- unless the document has <= 20 leaves (then fully expanded).
--
-- Pure helpers (_kind, _children, _jsonpath, _leaf_count, _initial_expanded,
-- _build_lines, _yank_text) are exported for unit tests: no UI required.

local ui = require("dadbod-grip.ui")

local M = {}

-- Documents with at most this many leaves open fully expanded.
M._MAX_AUTO_EXPAND_LEAVES = 20

-- ── pure helpers ────────────────────────────────────────────────────────────

--- Decode a cell value into a drillable JSON document.
--- Only objects/arrays are drillable; scalars and invalid JSON return nil.
---@param value any
---@return table|nil
function M.parse(value)
  if type(value) ~= "string" then return nil end
  local ok, decoded = pcall(vim.json.decode, value)
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

local _empty_dict_mt = getmetatable(vim.empty_dict())

--- Classify a decoded JSON value.
---@return string "object"|"array"|"null"|"string"|"number"|"boolean"
function M._kind(v)
  if v == vim.NIL then return "null" end
  local t = type(v)
  if t ~= "table" then return t end
  local mt = getmetatable(v)
  if mt ~= nil and mt == _empty_dict_mt then return "object" end
  if next(v) == nil then return "array" end   -- decoded [] is a plain {}
  return vim.islist(v) and "array" or "object"
end

--- Ordered children of a container: sorted string keys for objects,
--- 0-based numeric indices for arrays. Returns { {key=..., value=...}, ... }.
function M._children(v)
  local kind = M._kind(v)
  local out = {}
  if kind == "array" then
    for i = 1, #v do out[#out + 1] = { key = i - 1, value = v[i] } end
  elseif kind == "object" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do out[#out + 1] = { key = k, value = v[k] } end
  end
  return out
end

--- Append a key/index to a JSONPath. Identifier-safe keys use dot notation,
--- everything else bracket-quoted syntax; array indices use [i] (0-based).
---@param parent string  e.g. "$.items"
---@param key string|number
---@return string
function M._jsonpath(parent, key)
  if type(key) == "number" then
    return parent .. "[" .. key .. "]"
  end
  if key:match("^[%a_][%w_]*$") then
    return parent .. "." .. key
  end
  return parent .. '["' .. key:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"]'
end

--- Count scalar leaves; empty containers count as one leaf each.
function M._leaf_count(v)
  local kind = M._kind(v)
  if kind ~= "object" and kind ~= "array" then return 1 end
  local children = M._children(v)
  if #children == 0 then return 1 end
  local n = 0
  for _, c in ipairs(children) do n = n + M._leaf_count(c.value) end
  return n
end

--- All container JSONPaths in the document (root first, depth-first).
function M._container_paths(v, path)
  path = path or "$"
  local out = {}
  local kind = M._kind(v)
  if kind == "object" or kind == "array" then
    out[#out + 1] = path
    for _, c in ipairs(M._children(v)) do
      for _, p in ipairs(M._container_paths(c.value, M._jsonpath(path, c.key))) do
        out[#out + 1] = p
      end
    end
  end
  return out
end

--- Initial expansion state: root only, or everything when the document
--- has <= _MAX_AUTO_EXPAND_LEAVES leaves.
---@return table  set: expanded[jsonpath] = true
function M._initial_expanded(decoded)
  local expanded = { ["$"] = true }
  if M._leaf_count(decoded) <= M._MAX_AUTO_EXPAND_LEAVES then
    for _, p in ipairs(M._container_paths(decoded)) do expanded[p] = true end
  end
  return expanded
end

--- Display text + highlight group for a scalar value.
function M._scalar_display(v)
  if v == vim.NIL then return "null", "GripNull" end
  local t = type(v)
  if t == "boolean" then
    return tostring(v), v and "GripBoolTrue" or "GripBoolFalse"
  end
  if t == "number" then return vim.json.encode(v), "Number" end
  if t == "string" then return vim.json.encode(v), "String" end
  return tostring(v), nil
end

local function container_summary(v, kind)
  local n = #M._children(v)
  if kind == "object" then
    return "{...} (" .. n .. (n == 1 and " key)" or " keys)")
  end
  return "[...] (" .. n .. (n == 1 and " item)" or " items)")
end

--- Text to yank for a node value: raw scalars, compact JSON for containers.
function M._yank_text(v)
  local kind = M._kind(v)
  if kind == "object" or kind == "array" then return vim.json.encode(v) end
  if v == vim.NIL then return "null" end
  return tostring(v)
end

--- Render the tree into buffer lines given an expansion set.
--- Returns (lines, nodes): nodes[i] describes lines[i]:
---   { path, value, kind, depth, expandable, expanded, val_col, val_hl }
---@param decoded table
---@param expanded table  set: expanded[jsonpath] = true
function M._build_lines(decoded, expanded)
  local lines, nodes = {}, {}

  local function add(label, v, path, depth)
    local indent = string.rep("  ", depth)
    local kind = M._kind(v)
    local node = { path = path, value = v, kind = kind, depth = depth }
    if kind == "object" or kind == "array" then
      local is_exp = expanded[path] == true
      local marker = is_exp and "▾" or "▸"
      local prefix = indent .. marker .. " " .. label .. ": "
      node.expandable = true
      node.expanded   = is_exp
      node.val_col    = #prefix
      node.val_hl     = "Comment"
      lines[#lines + 1] = prefix .. container_summary(v, kind)
      nodes[#nodes + 1] = node
      if is_exp then
        for _, c in ipairs(M._children(v)) do
          local child_label = type(c.key) == "number" and ("[" .. c.key .. "]") or c.key
          add(child_label, c.value, M._jsonpath(path, c.key), depth + 1)
        end
      end
    else
      local text, hl = M._scalar_display(v)
      local prefix = indent .. "  " .. label .. ": "
      node.expandable = false
      node.val_col    = #prefix
      node.val_hl     = hl
      lines[#lines + 1] = prefix .. text
      nodes[#nodes + 1] = node
    end
  end

  add("$", decoded, "$", 0)
  return lines, nodes
end

-- ── float ───────────────────────────────────────────────────────────────────

local _ns = vim.api.nvim_create_namespace("grip_json_tree")
local _ag = vim.api.nvim_create_augroup("DadbodGripJsonTree", { clear = true })

local FOOTER = " <CR>/za toggle  y value  gy path  q close "

--- Open the JSON drilldown float for a cell value.
---@param value any          raw cell text (JSON expected)
---@param opts table|nil     { title?, origin_win? }
---@return integer|nil win, integer|nil buf
function M.open(value, opts)
  opts = opts or {}
  local decoded = M.parse(value)
  if decoded == nil then
    vim.notify("Not a JSON cell", vim.log.levels.INFO)
    return nil
  end

  local origin_win = opts.origin_win or vim.api.nvim_get_current_win()
  local expanded = M._initial_expanded(decoded)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local nodes

  local function win_size(lines)
    local max_w = 0
    for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
    max_w = math.max(max_w, vim.fn.strdisplaywidth(FOOTER))
    local width  = math.min(math.max(max_w + 2, 40), math.max(vim.o.columns - 4, 20))
    local height = math.min(math.max(#lines, 3), math.max(vim.o.lines - 6, 3))
    return width, height
  end

  local function render()
    local lines
    lines, nodes = M._build_lines(decoded, expanded)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, _ns, 0, -1)
    for i, node in ipairs(nodes) do
      if node.val_hl then
        vim.api.nvim_buf_set_extmark(buf, _ns, i - 1, node.val_col, {
          end_col = #lines[i],
          hl_group = node.val_hl,
        })
      end
    end
    return lines
  end

  local lines = render()
  local width, height = win_size(lines)
  local win = ui.info_float({
    buf        = buf,
    width      = width,
    height     = height,
    title      = opts.title or " JSON ",
    title_pos  = "center",
    zindex     = 60,
    footer     = FOOTER,
    footer_pos = "center",
  })
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    group    = _ag,
    buffer   = buf,
    once     = true,
    callback = function() vim.schedule(close) end,
  })

  local function node_under_cursor()
    return nodes[vim.api.nvim_win_get_cursor(win)[1]]
  end

  local function toggle()
    local node = node_under_cursor()
    if not node or not node.expandable then return end
    if expanded[node.path] then
      expanded[node.path] = nil
    else
      expanded[node.path] = true
    end
    local new_lines = render()
    -- Keep the cursor on the toggled node.
    for i, n in ipairs(nodes) do
      if n.path == node.path then
        pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
        break
      end
    end
    -- Grow/shrink the float with the content (bounded by the screen).
    local w, h = win_size(new_lines)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, {
        relative = "editor",
        row      = math.floor((vim.o.lines - h) / 2),
        col      = math.floor((vim.o.columns - w) / 2),
        width    = w,
        height   = h,
      })
    end
  end

  local function yank(text, what)
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    ui.notify("Yanked " .. what, vim.log.levels.INFO, "yank")
  end

  local map_opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", toggle, map_opts)
  vim.keymap.set("n", "za",   toggle, map_opts)
  vim.keymap.set("n", "y", function()
    local node = node_under_cursor()
    if node then yank(M._yank_text(node.value), "value") end
  end, map_opts)
  vim.keymap.set("n", "gy", function()
    local node = node_under_cursor()
    if node then yank(node.path, node.path) end
  end, map_opts)
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      close()
      if vim.api.nvim_win_is_valid(origin_win) then
        vim.api.nvim_set_current_win(origin_win)
      end
    end, map_opts)
  end

  return win, buf
end

return M
