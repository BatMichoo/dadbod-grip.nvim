-- schema.lua: sidebar schema tree browser.
-- Tables/views with expandable columns showing types + PK/FK markers.
-- Lazy column fetching on expand.

local db      = require("dadbod-grip.db")
local VERSION = require("dadbod-grip.version")
local ui      = require("dadbod-grip.ui")
local esc     = require("dadbod-grip.sql").escape_literal

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripSchema", { clear = true })

-- Active schema state (one per connection URL)
local _states = {}
local _sidebar_bufnr = nil
local _sidebar_winid = nil
local _sidebar_saved_width = nil  -- persists across open/close cycles

local SIDEBAR_WIDTH_RATIO = 0.25
local SIDEBAR_MAX_WIDTH = 36
local SIDEBAR_MIN_WIDTH = 24

--- Abbreviate data types for compact display.
local function abbrev_type(dtype)
  if not dtype or dtype == "" then return "" end
  local lower = dtype:lower()
  -- Exact matches
  if lower == "integer" or lower == "int" or lower == "int4" then return "int" end
  if lower == "bigint" or lower == "int8" then return "big" end
  if lower == "smallint" or lower == "int2" then return "small" end
  if lower == "boolean" or lower == "tinyint(1)" or lower == "bool" then return "bool" end
  if lower == "text" then return "text" end
  if lower == "date" then return "date" end
  if lower == "time" then return "time" end
  if lower == "json" or lower == "jsonb" then return "json" end
  if lower == "real" or lower == "float" then return "float" end
  if lower == "double precision" or lower == "double" then return "dbl" end
  if lower == "blob" or lower == "bytea" then return "bin" end
  if lower == "uuid" or lower == "char(36)" then return "uuid" end
  if lower == "interval" then return "intv" end
  -- Timestamp variants
  if lower:match("^timestamp") then return "ts" end
  -- Varchar with length
  local vc_len = lower:match("^character varying%((%d+)%)$") or lower:match("^varchar%((%d+)%)$")
  if vc_len then return "vc(" .. vc_len .. ")" end
  if lower:match("^varchar") or lower:match("^character varying") then return "vc" end
  -- Decimal/numeric with precision
  local dec_m, dec_n = lower:match("^decimal%((%d+),(%d+)%)$")
  if not dec_m then dec_m, dec_n = lower:match("^numeric%((%d+),(%d+)%)$") end
  if dec_m then return "dec(" .. dec_m .. "," .. dec_n .. ")" end
  if lower:match("^decimal") or lower:match("^numeric") then return "dec" end
  -- INT AUTO_INCREMENT → int
  if lower:match("^int") then return "int" end
  -- Enum
  if lower:match("^enum") or lower:match("^user%-defined") then return "enum" end
  -- Array types
  if lower:match("%[%]$") then return abbrev_type(lower:gsub("%[%]$", "")) .. "[]" end
  -- Fallback: truncate
  if #dtype > 8 then return dtype:sub(1, 7) .. "…" end
  return dtype
end

local filetypes = require("dadbod-grip.filetypes")

--- Returns true when the URL is a file path or remote file (not a DB connection).
local function is_file_url(url)
  if not url then return false end
  local is_remote = url:match("^https?://") or url:match("^s3://")
  local is_path = url:match("^/") or url:match("^~/") or url:match("^%.%.?/")
  return not not ((is_remote or is_path) and filetypes.has_supported_extension(url))
end

--- Get or create state for a URL.
local function get_state(url)
  if not _states[url] then
    _states[url] = {
      url = url,
      items = nil,       -- { {name, type}, ... }: nil = not fetched
      routines = nil,    -- { {name, display, type}, ... }: nil = not fetched
      file_cols = nil,   -- for file-as-table: { {column_name, data_type}, ... }
      expanded = {},      -- column folds, independent from schema/partition folds
      groups_expanded = {},
      col_cache = {},        -- table_name → column_info[]
      pk_cache = {},         -- table_name → set
      pk_list = {},          -- table_name → ordered PK column names
      fk_cache = {},         -- table_name → fk_info[]
      constraint_cache = {}, -- table_name → constraint[]
      index_cache = {},      -- table_name → index[]
      facets_expanded = {},  -- "table\0folder" → true: open folders under a table
      nodes = {},         -- flat rendered node list
      filter = nil,       -- search filter string
    }
  end
  return _states[url]
end

--- Drop every cached per-table metadata list so the next open folder refetches.
local function clear_metadata(state)
  state.col_cache, state.pk_cache, state.pk_list, state.fk_cache = {}, {}, {}, {}
  state.constraint_cache, state.index_cache = {}, {}
end

--- Fetch table list for a persistent DB state.
local function fetch_tables(state)
  local tables, err = db.list_tables(state.url)
  if not tables then
    vim.notify("Grip: " .. (err or "Failed to list tables"), vim.log.levels.ERROR)
    return
  end
  state.items = tables
  local routines = db.list_routines(state.url)
  state.routines = routines or {}
  -- DuckDB's adapter deliberately omits .schema for its known main-schema rows.
  -- Other missing metadata conveys no ownership, including bare PostgreSQL names.
  state.default_schema = require("dadbod-grip.adapters").kind(db.resolved_url(state.url)) == "duckdb" and "main" or nil
  require("dadbod-grip.schema_tree").prune(state)
end

--- Fetch column schema for a file-as-table URL (Parquet, CSV, remote file).
--- Uses DuckDB's DESCRIBE to get column names and types without needing a DB.
local function fetch_file_schema(state)
  local file_url = state.url
  local safe_url = esc(file_url)
  local sql = string.format("DESCRIBE SELECT * FROM '%s' LIMIT 0", safe_url)
  local result, err = db.query(sql, "duckdb::memory:")
  if not result then
    vim.notify("Grip: could not read file schema: " .. (err or "unknown"), vim.log.levels.WARN)
    state.file_cols = {}
    state.items = {}
    return
  end
  local cols = {}
  for _, row in ipairs(result.rows or {}) do
    local col_name  = type(row) == "table" and (row.column_name  or row[1]) or row
    local col_type  = type(row) == "table" and (row.column_type  or row[2]) or ""
    if col_name and col_name ~= "" then
      table.insert(cols, { column_name = col_name, data_type = col_type })
    end
  end
  state.file_cols = cols
  state.items = {}  -- Mark as fetched (empty = no DB tables, which is correct)
end

--- Fetch primary and foreign keys for a table (lazy, cached). Each ensure_*
--- returns true when it queried, so the caller knows to rebuild the tree.
local function ensure_keys(state, table_name)
  if state.pk_cache[table_name] then return false end
  local pks, fks = db.get_table_keys(table_name, state.url)
  local pk_set = {}
  for _, pk in ipairs(pks) do pk_set[pk] = true end
  state.pk_cache[table_name] = pk_set
  state.pk_list[table_name] = pks

  local fk_map = {}
  for _, fk in ipairs(fks or {}) do fk_map[fk.column] = fk.ref_table end
  state.fk_cache[table_name] = fk_map
  return true
end

--- Fetch column info for a table (lazy, cached). Columns only: the PK/FK
--- markers show once the Keys folder has loaded the keys, never at the cost
--- of another round-trip here.
local function ensure_columns(state, table_name)
  if state.col_cache[table_name] then return false end
  local cols = db.get_column_info(table_name, state.url)
  state.col_cache[table_name] = cols or {}
  return true
end

--- Load what one open table folder lists. Expanding a table runs no query;
--- each folder fetches its own metadata the first time it is opened.
local FACET_LOADERS = {
  columns = ensure_columns,
  keys = ensure_keys,
  constraints = function(state, table_name)
    if state.constraint_cache[table_name] then return false end
    state.constraint_cache[table_name] = db.get_constraints(table_name, state.url) or {}
    return true
  end,
  indexes = function(state, table_name)
    if state.index_cache[table_name] then return false end
    state.index_cache[table_name] = db.get_indexes(table_name, state.url) or {}
    return true
  end,
}

--- Build flat node list from state.
local function build_nodes(state)
  local nodes = {}

  -- File-as-table mode: show columns of the file directly, no DB schema needed
  if state.file_cols then
    local fname = state.url:match("[^/\\]+$") or state.url
    local expanded = state.expanded["__file__"] ~= false  -- default expanded
    table.insert(nodes, { kind = "header", text = "File" })
    table.insert(nodes, {
      kind = "table", id = "file", name = fname, expanded = expanded,
      is_file = true, file_key = "__file__",
    })
    if expanded then
      for _, col in ipairs(state.file_cols) do
        table.insert(nodes, {
          kind = "column", id = "file\0column\0" .. col.column_name, parent = "file",
          name = col.column_name,
          dtype = abbrev_type(col.data_type),
          pk = false, fk = false,
          table_name = "__file__",
          is_file = true,
        })
      end
    end
    state.nodes = nodes
    return nodes
  end

  if not state.items then return nodes end
  local tree = require("dadbod-grip.schema_tree")
  nodes = tree.build(state)
  local loaded = false
  for _, node in ipairs(nodes) do
    if node.kind == "facet" and node.expanded and FACET_LOADERS[node.facet](state, node.table_name) then
      loaded = true
    end
  end
  if loaded then nodes = tree.build(state) end
  for _, node in ipairs(nodes) do
    if node.kind == "column" then node.dtype = abbrev_type(node.data_type) end
  end
  state.nodes = nodes
  return nodes
end

--- Snapshot stable identity and native window view before changing the projection.
local function selection(state)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return nil end
  local view = vim.api.nvim_win_call(_sidebar_winid, vim.fn.winsaveview)
  local node = state.nodes[view.lnum - (state.rendered_filter and 4 or 2)]
  local ids, by_id = {}, {}
  for _, candidate in ipairs(state.nodes) do if candidate.id then by_id[candidate.id] = candidate end end
  while node and node.id do
    ids[#ids + 1] = node.id
    node = by_id[node.parent]
  end
  return {ids = ids, view = view}
end

local function restore_selection(state, anchor)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  local offset, target, same = state.filter and 4 or 2, nil, false
  for n, id in ipairs(anchor and anchor.ids or {}) do
    for i, node in ipairs(state.nodes) do
      if node.id == id then target, same = i, n == 1; break end
    end
    if target then break end
  end
  if not target then
    for i, node in ipairs(state.nodes) do
      if node.kind ~= "header" and node.kind ~= "sep" then target = i; break end
    end
  end
  local view = same and vim.deepcopy(anchor.view) or {col = 0, leftcol = 0, curswant = 0, coladd = 0}
  view.lnum = (target or 1) + offset
  if same then
    -- Keep the selected object in the same viewport position when rows above change.
    view.topline = math.max(1, (view.topline or 1) + view.lnum - anchor.view.lnum)
  end
  vim.api.nvim_win_call(_sidebar_winid, function() vim.fn.winrestview(view) end)
end

--- Render complete buffer labels; the window viewport handles horizontal clipping.
local function render(state, anchor)
  if not _sidebar_bufnr or not vim.api.nvim_buf_is_valid(_sidebar_bufnr) then return end
  anchor = anchor or selection(state)
  local nodes = build_nodes(state)
  local lines, highlights = {}, {}
  local function line(text, hl)
    lines[#lines + 1] = text
    if hl then highlights[#highlights + 1] = {line = #lines - 1, col = 0, end_col = #text, hl = hl} end
  end
  local title
  if state.file_cols ~= nil then
    title = state.url:match("[^/\\]+$") or state.url
  else
    local current = require("dadbod-grip.connections").current()
    title = current and current.name or state.url:match("^%w+://[^/]*/?([^?]*)") or state.url
  end
  line(" " .. title, "GripConnAccentBold")
  line("")
  if state.filter then line(" / " .. state.filter, "Search"); line("") end
  local widths = {}
  for _, node in ipairs(nodes) do
    if node.kind == "column" then
      widths[node.table_name] = math.max(widths[node.table_name] or 0, vim.fn.strdisplaywidth(node.name))
    end
  end
  for _, node in ipairs(nodes) do
    local indent = string.rep("  ", node.depth or 0)
    if node.kind == "header" then
      line(indent .. " " .. node.text, "GripHeader")
    elseif node.kind == "schema" or node.kind == "partitions" then
      local label = node.kind == "schema" and node.name or ("Partitions (" .. node.count .. ")")
      line(indent .. (node.expanded and " ▼ " or " ▶ ") .. label, "GripHeader")
    elseif node.kind == "table" then
      line(indent .. (node.expanded and " ▼ " or " ▶ ") .. (node.display or node.name))
    elseif node.kind == "column" then
      local marker = node.pk and (node.fk and "🔑🔗" or "🔑 ") or (node.fk and " 🔗" or "   ")
      local prefix = indent .. "  " .. marker .. " "
      local pad = string.rep(" ", math.max(1, (widths[node.table_name] or 0) - vim.fn.strdisplaywidth(node.name) + 2))
      line(prefix .. node.name .. pad .. node.dtype)
      highlights[#highlights + 1] = {line = #lines - 1, col = #prefix + #node.name + #pad,
        end_col = #lines[#lines], hl = "GripReadonly"}
    elseif node.kind == "facet" then
      line(indent .. (node.expanded and " ▼ " or " ▶ ") .. node.name
        .. (node.count and (" (" .. node.count .. ")") or ""), "GripHeader")
    elseif node.kind == "facet_item" then
      line(indent .. "  " .. node.icon .. " " .. node.text)
    elseif node.kind == "routine" then
      line(indent .. (node.type == "procedure" and " ◇ " or " ƒ ") .. (node.display or node.name))
    elseif node.kind == "sep" then
      line("")
    end
  end
  if #nodes == 0 and state.items then
    line(state.filter and " (no matches)" or " (no objects found)", "GripReadonly")
  end
  line("")
  line(" 1:conn 2:pad 3:grid", "GripReadonly")
  line(" <CR> / F ?  zh/zl", "GripReadonly")
  vim.bo[_sidebar_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(_sidebar_bufnr, 0, -1, false, lines)
  vim.bo[_sidebar_bufnr].modifiable = false
  local ns = vim.api.nvim_create_namespace("grip_schema")
  vim.api.nvim_buf_clear_namespace(_sidebar_bufnr, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(_sidebar_bufnr, ns, hl.line, hl.col, {end_col = hl.end_col, hl_group = hl.hl})
  end
  state.rendered_filter = state.filter
  restore_selection(state, anchor)
end

--- Get the node at the current cursor line.
local function node_at_cursor(state)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return nil end
  local cursor = vim.api.nvim_win_get_cursor(_sidebar_winid)
  local line = cursor[1]
  -- title(1) + blank(1) = base offset 2
  local offset = 2
  if state.filter then offset = offset + 2 end
  local node_idx = line - offset
  if node_idx >= 1 and node_idx <= #state.nodes then
    return state.nodes[node_idx]
  end
  return nil
end

--- Find the best non-sidebar window to reuse for a new grid.
--- Prefers an existing grip grid window over the query pad.
local function find_right_win()
  return require("dadbod-grip.view").find_content_win()
end

--- Open a table in a grip grid, reusing the adjacent window.
local function open_table(table_name, url)
  local grip = require("dadbod-grip")
  local target_win = find_right_win()
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  end
  grip.open(table_name, url, { reuse_win = target_win })
end

--- Open a table in a new split (explicit second grid).
local function open_table_split(table_name, url)
  local grip = require("dadbod-grip")
  local target_win = find_right_win()
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  end
  grip.open(table_name, url, { force_split = true })
end

--- Show a table's metadata view (columns, fk, constraints, indexes) in the
--- grid, as selecting a folder in SSMS's Object Explorer does. A grid already
--- on that table just switches view; otherwise a grid opens on the view alone,
--- and the rows are queried only when the user switches to the records.
local function open_table_view(table_name, url, view_name)
  local view_mod = require("dadbod-grip.view")
  local win = find_right_win()
  local buf = win and vim.api.nvim_win_get_buf(win)
  local session = buf and view_mod._sessions[buf]
  if session and session.url == url and session.state and session.state.table_name == table_name then
    vim.api.nvim_set_current_win(win)
  else
    -- The folder's metadata only: no SELECT of the rows, no pad sync
    if win then vim.api.nvim_set_current_win(win) end
    require("dadbod-grip").open(table_name, url, { reuse_win = win, metadata_view = view_name })
    return
  end
  if session and (session.current_view or "records") ~= view_name then
    view_mod.switch_view(buf, view_name)
  end
end

--- Open a routine definition in a read-only SQL buffer.
local function open_routine_source(routine_name, url)
  local source, err = db.get_routine_source(routine_name, url)
  if not source then
    vim.notify("Grip: " .. (err or "Failed to load routine source"), vim.log.levels.ERROR)
    return
  end

  local target_win = find_right_win()
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  else
    vim.cmd("rightbelow vsplit")
    target_win = vim.api.nvim_get_current_win()
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "grip://routine/" .. routine_name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  ui.highlight_as(bufnr, "sql")
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(source, "\n", { plain = true }))
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.api.nvim_win_set_buf(target_win, bufnr)
end

--- Line number offset for node list (title + blank [+ filter + blank]).
local function node_offset(state)
  return state.filter and 4 or 2
end

--- Navigate to next (+1) or prev (-1) table node, wrapping at ends.
local function jump_to_next_table(state, direction)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  local offset = node_offset(state)
  local cur_line = vim.api.nvim_win_get_cursor(_sidebar_winid)[1]
  local tlines = {}
  for i, node in ipairs(state.nodes) do
    if node.kind == "table" or node.kind == "routine" then table.insert(tlines, offset + i) end
  end
  if #tlines == 0 then return end
  if direction > 0 then
    for _, ln in ipairs(tlines) do
      if ln > cur_line then pcall(vim.api.nvim_win_set_cursor, _sidebar_winid, { ln, 0 }); return end
    end
    pcall(vim.api.nvim_win_set_cursor, _sidebar_winid, { tlines[1], 0 })
  else
    for i = #tlines, 1, -1 do
      if tlines[i] < cur_line then pcall(vim.api.nvim_win_set_cursor, _sidebar_winid, { tlines[i], 0 }); return end
    end
    pcall(vim.api.nvim_win_set_cursor, _sidebar_winid, { tlines[#tlines], 0 })
  end
end

-- Sidebar internals the keymaps in schema/keymaps.lua drive. The buffer and
-- window are getters: both change whenever the sidebar is reopened.
local keymap_ctx = {
  bufnr = function() return _sidebar_bufnr end,
  winid = function() return _sidebar_winid end,
  augroup = _ag,
  close = function() return M.close() end,
  clear_metadata = clear_metadata,
  ensure_columns = ensure_columns,
  ensure_keys = ensure_keys,
  fetch_tables = fetch_tables,
  find_right_win = find_right_win,
  get_state = get_state,
  jump_to_next_table = jump_to_next_table,
  node_at_cursor = node_at_cursor,
  node_offset = node_offset,
  open_routine_source = open_routine_source,
  open_table = open_table,
  open_table_split = open_table_split,
  open_table_view = open_table_view,
  render = render,
  selection = selection,
}

--- Set up buffer-local keymaps.
local function setup_keymaps(url)
  require("dadbod-grip.schema.keymaps").setup(url, keymap_ctx)
end

local function sidebar_width_for(columns)
  local w = math.floor(columns * SIDEBAR_WIDTH_RATIO)
  return math.max(SIDEBAR_MIN_WIDTH, math.min(SIDEBAR_MAX_WIDTH, w))
end

local function sidebar_width()
  return sidebar_width_for(vim.o.columns)
end

--- Shrink a sidebar that no longer fits the editor, but never grow one the
--- user deliberately made narrower than the automatic target.
local function clamp_sidebar_width(current, columns)
  return math.min(current, sidebar_width_for(columns))
end

vim.api.nvim_create_autocmd("VimResized", {
  group = _ag,
  callback = function()
    if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
    local current = vim.api.nvim_win_get_width(_sidebar_winid)
    local clamped = clamp_sidebar_width(current, vim.o.columns)
    if clamped < current then pcall(vim.api.nvim_win_set_width, _sidebar_winid, clamped) end
  end,
})

--- Fetch the schema for `url` into state, touching no window.
---
--- Split out of toggle() so a caller assembling the workspace can pay for the
--- DB round-trip while the preloader is still up and the old screen is still
--- whole, instead of behind a sidebar that is already visible and empty.
--- Cached: a second call for the same URL costs nothing.
--- @param url string
--- @return table state
function M.prefetch(url)
  local state = get_state(url)
  if not state.items then
    if is_file_url(url) then
      fetch_file_schema(state)
    else
      fetch_tables(state)
    end
  end
  return state
end

--- Open or toggle the schema sidebar.
-- From outside the sidebar: focus it (open if needed).
-- From inside the sidebar: close it.
function M.toggle(url)
  if _sidebar_winid and vim.api.nvim_win_is_valid(_sidebar_winid) then
    if vim.api.nvim_get_current_win() == _sidebar_winid then
      -- Already in sidebar → close (toggle off)
      M.close()
    else
      -- Not in sidebar → just focus it
      vim.api.nvim_set_current_win(_sidebar_winid)
    end
    return
  end

  if not url then
    local db_mod = require("dadbod-grip.db")
    url = db_mod.get_url()
    if not url then
      vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
      return
    end
  end

  -- Fetch first, window second. list_tables()/list_routines() block on a DB
  -- round-trip that pumps the event loop, so a sidebar opened ahead of them
  -- sat on screen empty for the whole query -- and, next to an equally empty
  -- content area, made the workspace look like it was assembling itself in
  -- front of the user. Nothing between here and render() below blocks, so the
  -- split now appears already filled.
  local state = M.prefetch(url)

  -- Create buffer if needed
  if not _sidebar_bufnr or not vim.api.nvim_buf_is_valid(_sidebar_bufnr) then
    _sidebar_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[_sidebar_bufnr].buftype = "nofile"
    vim.bo[_sidebar_bufnr].bufhidden = "hide"
    vim.bo[_sidebar_bufnr].swapfile = false
    vim.bo[_sidebar_bufnr].filetype = "grip_schema"
    vim.api.nvim_buf_set_name(_sidebar_bufnr, "grip://schema")
  end
  -- The buffer is reused across connections; callbacks must bind the current URL.
  setup_keymaps(url)

  -- Open left split, restoring previous width if available
  local width = _sidebar_saved_width or sidebar_width()
  vim.cmd("topleft vertical " .. width .. "split")
  _sidebar_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(_sidebar_winid, _sidebar_bufnr)

  -- Window options
  vim.wo[_sidebar_winid].number = false
  vim.wo[_sidebar_winid].relativenumber = false
  vim.wo[_sidebar_winid].signcolumn = "no"
  vim.wo[_sidebar_winid].cursorline = true
  vim.wo[_sidebar_winid].winfixwidth = true
  vim.wo[_sidebar_winid].wrap = false
  vim.wo[_sidebar_winid].sidescrolloff = 0
  vim.wo[_sidebar_winid].list = true
  vim.wo[_sidebar_winid].listchars = "extends:…,precedes:…"

  render(state)
end

--- Close the schema sidebar.
function M.close()
  if _sidebar_winid and vim.api.nvim_win_is_valid(_sidebar_winid) then
    _sidebar_saved_width = vim.api.nvim_win_get_width(_sidebar_winid)
    vim.api.nvim_win_close(_sidebar_winid, true)
  end
  _sidebar_winid = nil
end

function M.is_open()
  return _sidebar_winid ~= nil and vim.api.nvim_win_is_valid(_sidebar_winid)
end

function M.get_winid()
  if _sidebar_winid and vim.api.nvim_win_is_valid(_sidebar_winid) then
    return _sidebar_winid
  end
  return nil
end

--- Get first non-sidebar window (the right content area).
function M.get_right_win()
  if not M.is_open() then return nil end
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if bufnr ~= _sidebar_bufnr then
      return winid
    end
  end
  return nil
end

--- Expose per-URL state for use by er_diagram.lua (read-only; do not mutate).
M.get_state = get_state

--- Exposed for testing only.
--- Test hook: forget every cached schema so a spec can watch a fresh fetch.
function M._reset_state()
  _states = {}
end

M._clamp_sidebar_width = clamp_sidebar_width
M._sidebar_width_for = sidebar_width_for

M._build_nodes = build_nodes

--- Refresh sidebar if visible (e.g., after connection switch).
function M.refresh(url)
  if not url then return end
  local state = get_state(url)
  -- Invalidate all caches so fresh data is fetched
  state.items = nil
  state.routines = nil
  state.file_cols = nil
  clear_metadata(state)
  db.clear_key_cache(url)
  -- Only re-render if sidebar is currently visible
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  if is_file_url(url) then
    fetch_file_schema(state)
  else
    fetch_tables(state)
  end
  if _sidebar_bufnr and vim.api.nvim_buf_is_valid(_sidebar_bufnr) then
    setup_keymaps(url)
  end
  render(state)
end

return M
