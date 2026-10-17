-- view/meta_views.lua: the grid's metadata views (Columns, Foreign Keys,
-- Indexes, Constraints, Stats) and switching between them and the records.

local ui = require("dadbod-grip.ui")

local M = {}

-- Short labels for the view tabs in the grid title.
M.LABELS = {
  records     = "Rec",
  columns     = "Col",
  fk          = "FK",
  indexes     = "Idx",
  constraints = "Con",
  stats       = "Stat",
  history     = "Hist",
  er_diagram  = "ER",
}
local VIEW_LABELS = M.LABELS

local function view()
  return require("dadbod-grip.view")
end

-- ── tab view system ──────────────────────────────────────────────────────────

-- Build a minimal read-only state table compatible with build_render.
-- rows = array of arrays matching the columns order.
local function make_meta_state(table_name, columns, rows)
  return {
    rows            = rows,
    columns         = columns,
    pks             = {},
    table_name      = table_name,
    changes         = {},
    deleted         = {},
    inserted        = {},
    _next_insert_idx = 1000,
    readonly        = true,
  }
end

-- Update the buffer name to reflect the current view.
local function update_buf_name(bufnr, table_name, view_name)
  local base = table_name or "result"
  local name
  if view_name and view_name ~= "records" then
    local full = {
      columns="Columns", fk="Foreign Keys", indexes="Indexes",
      constraints="Constraints", stats="Stats", history="History", explain="Explain",
    }
    name = "grip://" .. base .. " [" .. (full[view_name] or view_name) .. "]"
  else
    name = "grip://" .. base
  end
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
end

-- Per-view data fetchers. Each returns (columns, rows, err).
local function fetch_view_columns(table_name, url, session)
  -- Opening a table already fetched this for conditional formatting; reuse it
  -- rather than paying another round-trip (a new login, for sqlcmd).
  local cols, err = session and session._column_info, nil
  if not cols then
    cols, err = require("dadbod-grip.db").get_column_info(table_name, url)
    if err and not cols then return nil, nil, err end
    if not cols then return nil, nil, "no column info returned" end
    if session then session._column_info = cols end
  end
  local columns = { "column_name", "data_type", "nullable", "default", "key" }
  local rows = {}
  for _, c in ipairs(cols) do
    table.insert(rows, {
      c.column_name or "",
      c.data_type or "",
      c.is_nullable or "",
      (c.column_default and c.column_default ~= "") and c.column_default or "-",
      (c.constraints and c.constraints ~= "") and c.constraints or "",
    })
  end
  return columns, rows, nil
end

local function fetch_view_fk(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  local fks, err = db_mod.get_foreign_keys(table_name, url)
  if err and not fks then return nil, nil, err end
  fks = fks or {}
  local columns = { "direction", "column", "ref_table", "ref_column" }
  local rows = {}
  -- Outbound: columns in this table pointing to other tables
  for _, fk in ipairs(fks) do
    table.insert(rows, { "→ outbound", fk.column or "", fk.ref_table or "", fk.ref_column or "" })
  end
  -- Inbound: other tables that reference this table. get_referencing_foreign_keys
  -- answers this in one query on every adapter that supports it (and falls back
  -- to the same list_tables + per-table scan otherwise), instead of spawning one
  -- CLI process per table in the schema. Same source as the gr keymap.
  local refs = db_mod.get_referencing_foreign_keys(table_name, url) or {}
  for _, ref in ipairs(refs) do
    -- Self-references are already listed above as outbound; don't repeat them.
    if ref.table ~= table_name then
      table.insert(rows, { "← inbound", (ref.table or "") .. "." .. (ref.column or ""), table_name, ref.ref_column or "" })
    end
  end
  if #rows == 0 then
    table.insert(rows, { "(none)", "", "", "" })
  end
  return columns, rows, nil
end

local function fetch_view_indexes(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  local indexes, err = db_mod.get_indexes(table_name, url)
  if err and not indexes then return nil, nil, err end
  indexes = indexes or {}
  local columns = { "index_name", "type", "columns" }
  local rows = {}
  for _, idx in ipairs(indexes) do
    table.insert(rows, {
      idx.name or "",
      idx.type or "INDEX",
      type(idx.columns) == "table" and table.concat(idx.columns, ", ") or (idx.columns or ""),
    })
  end
  if #rows == 0 then
    table.insert(rows, { "(none)", "", "" })
  end
  return columns, rows, nil
end

local function fetch_view_constraints(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  local constraints, err = db_mod.get_constraints(table_name, url)
  if err and not constraints then return nil, nil, err end
  constraints = constraints or {}
  local columns = { "constraint_name", "type", "definition" }
  local rows = {}
  for _, c in ipairs(constraints) do
    table.insert(rows, { c.name or "", c.type or "", c.definition or "" })
  end
  if #rows == 0 then
    table.insert(rows, { "(none)", "", "" })
  end
  return columns, rows, nil
end

local function fetch_view_stats(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  local cols = session and session._column_info
  if not cols then
    local err
    cols, err = db_mod.get_column_info(table_name, url)
    if err and not cols then return nil, nil, err end
    if session and cols then session._column_info = cols end
  end
  if not cols or #cols == 0 then return nil, nil, "no columns found" end

  local d = db_mod.stats_dialect(url)
  local tbl = {}
  for part in table_name:gmatch("[^.]+") do tbl[#tbl + 1] = d.quote(part) end

  -- One row, one scan: COUNT(*) once, then four aggregates per column. A
  -- UNION ALL per column scanned the table once per column.
  local function build(compare)
    local select_list = { "COUNT(*)" }
    for _, c in ipairs(cols) do
      local q = d.quote(c.column_name)
      local base = vim.trim(tostring(c.data_type or ""):lower():match("^[%a_ %-]+") or "")
      local cast = d.cast_from and d.cast_from[base]
      select_list[#select_list + 1] = "COUNT(" .. q .. ")"
      if (d.no_compare and d.no_compare[base]) or not compare then
        select_list[#select_list + 1] = "NULL"
        select_list[#select_list + 1] = "NULL"
        select_list[#select_list + 1] = "NULL"
      else
        local v = cast and ("CAST(" .. q .. " AS " .. cast .. ")") or q
        select_list[#select_list + 1] = "COUNT(DISTINCT " .. v .. ")"
        select_list[#select_list + 1] = "CAST(MIN(" .. v .. ") AS " .. d.text .. ")"
        select_list[#select_list + 1] = "CAST(MAX(" .. v .. ") AS " .. d.text .. ")"
      end
    end
    return "SELECT " .. table.concat(select_list, ", ") .. " FROM " .. table.concat(tbl, ".")
  end

  local result, query_err = db_mod.query(build(true), url)
  if query_err then
    -- A column type with no ordering we did not foresee fails the whole
    -- query. Counts still work on any type: show those rather than nothing.
    local counts = db_mod.query(build(false), url)
    if not counts then return nil, nil, "Stats query failed: " .. query_err end
    result = counts
    vim.notify("Grip stats: distinct/min/max unavailable: " .. query_err, vim.log.levels.WARN)
  end
  if not result or not result.rows or not result.rows[1] then return nil, nil, "no stats result" end

  local r = result.rows[1]
  local total = tonumber(r[1]) or 0
  local columns = { "column", "total", "non_null", "nulls", "distinct", "min", "max" }
  local rows = {}
  for i, c in ipairs(cols) do
    local at = 1 + (i - 1) * 4
    local non_null = tonumber(r[at + 1]) or 0
    local nulls = total - non_null
    local function cell(v) return (v == nil or v == "" or v == "NULL") and "-" or v end
    table.insert(rows, {
      c.column_name or "",
      tostring(total),
      tostring(non_null),
      total > 0 and string.format("%.1f%%", (nulls / total) * 100) or "-",
      cell(r[at + 2]),
      cell(r[at + 3]),
      cell(r[at + 4]),
    })
  end
  return columns, rows, nil
end

local VIEW_FETCHERS = {
  columns     = fetch_view_columns,
  fk          = fetch_view_fk,
  indexes     = fetch_view_indexes,
  constraints = fetch_view_constraints,
  stats       = fetch_view_stats,
}

--- Switch the current grip buffer to a different view facet.
--- view_name: "records"|"columns"|"fk"|"indexes"|"constraints"|"stats"|"history"|"explain"
--- opts.force = true re-fetches the view even when it is already showing.
function M.switch_view(bufnr, view_name, opts)
  local session = view()._sessions[bufnr]
  if not session then return end

  -- Already on this view: show hint rather than silently re-fetching
  -- (history is excluded: it's a picker, re-opening it is fine)
  local actual_view = session.current_view or "records"
  if actual_view == view_name and view_name ~= "history" and not (opts and opts.force) then
    local full_labels = {
      records = "Records", columns = "Columns", fk = "Foreign Keys",
      indexes = "Indexes", constraints = "Constraints", stats = "Stats", explain = "Explain",
    }
    local label = full_labels[view_name] or view_name
    vim.notify("Already on " .. label .. " · press 2 for Records", vim.log.levels.INFO)
    return
  end

  local table_name = session.state and session.state.table_name
  local url = session.url

  -- Tab 1 is the table picker, handled by the keymap directly (no view switch)
  if view_name == "records" then
    -- Save scroll position of current metadata view before switching back
    local win = vim.fn.bufwinid(bufnr)
    if win ~= -1 then
      session.view_cache = session.view_cache or {}
      local old_cv = session.current_view or "records"
      session.view_cache[old_cv] = { cursor = vim.api.nvim_win_get_cursor(win) }
    end
    session.current_view = "records"
    -- _records_state always holds the canonical records data
    local real_state = session._records_state or session.state
    view().render(bufnr, real_state)
    -- Restore records cursor if cached
    local cur_win = vim.fn.bufwinid(bufnr)
    if cur_win ~= -1 and session.view_cache and session.view_cache["records"] then
      pcall(vim.api.nvim_win_set_cursor, cur_win, session.view_cache["records"].cursor)
    end
    session._meta_state = nil
    update_buf_name(bufnr, table_name, nil)
    return
  end

  if not table_name then
    vim.notify("Grip: no table in focus for view switching", vim.log.levels.WARN)
    return
  end

  -- History opens the grip picker (same as gh) filtered to this table: not a grid
  if view_name == "history" then
    require("dadbod-grip.history").pick_for_table(table_name, function(sql_content)
      require("dadbod-grip.query_pad").open(url, { initial_sql = sql_content })
    end)
    return
  end

  -- Explain opens the Query Health popup (same as gQ): text format is far more readable than a grid
  if view_name == "explain" then
    local query_sql
    if session.query_spec then
      query_sql = require("dadbod-grip.query").build_sql(session.query_spec)
    elseif session.query_sql then
      query_sql = session.query_sql
    else
      -- Through the query builder, so each adapter gets its own row cap syntax.
      local qmod = require("dadbod-grip.query")
      query_sql = qmod.build_sql(qmod.new_table(table_name, 100))
    end
    -- Pass through nvim_cmd args: string form splits the argument on newlines
    -- (and on |), so a multi-line query pad SQL was executed as several
    -- Ex commands instead of being handed to :GripExplain.
    vim.cmd({ cmd = "GripExplain", args = { query_sql } })
    return
  end

  local fetcher = VIEW_FETCHERS[view_name]
  if not fetcher then
    vim.notify("Grip: unknown view '" .. view_name .. "'", vim.log.levels.WARN)
    return
  end

  -- Save scroll position of current view before switching
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    session.view_cache = session.view_cache or {}
    local old_cv = session.current_view or "records"
    session.view_cache[old_cv] = { cursor = vim.api.nvim_win_get_cursor(win) }
  end

  -- Preserve the canonical records state so it survives the render() call
  if not session._records_state or session.current_view == nil or session.current_view == "records" then
    session._records_state = session.state
  end

  -- Fetch view data
  local columns, rows, err = ui.blocking(
    "Loading " .. (VIEW_LABELS[view_name] or view_name) .. " for " .. table_name .. "...",
    function() return fetcher(table_name, url, session) end
  )
  if err or not columns then
    vim.notify("Grip " .. view_name .. ": " .. (err or "no data returned"), vim.log.levels.WARN)
    return
  end

  -- Build meta state and render (render sets session.state = meta_state temporarily)
  local meta_state = make_meta_state(table_name, columns, rows or {})
  local prev_view, prev_meta = session.current_view, session._meta_state
  session.current_view = view_name
  session._meta_state = meta_state  -- preserved for CR navigation (session.state is restored below)
  local ok, render_err = pcall(view().render, bufnr, meta_state)
  -- Restore the canonical records state so keymaps like `r` still work
  session.state = session._records_state
  if not ok then
    -- Stay on the view that is still on screen, so pressing the key again retries.
    session.current_view, session._meta_state = prev_view, prev_meta
    error(render_err, 0)
  end

  -- Update buffer name and restore cached cursor for this view
  update_buf_name(bufnr, table_name, view_name)
  local cur_win = vim.fn.bufwinid(bufnr)
  if cur_win ~= -1 then
    if session.view_cache and session.view_cache[view_name] then
      pcall(vim.api.nvim_win_set_cursor, cur_win, session.view_cache[view_name].cursor)
    else
      -- Default: top of data
      pcall(vim.api.nvim_win_set_cursor, cur_win, { 5, 0 })
    end
  end
end

--- Show freshly fetched records after a refresh. When a metadata view
--- (columns, constraints, ...) is on screen, the rows become the records behind
--- it and the view itself is reloaded; painting the records there would leave
--- them under the metadata view's badge.
function M.apply_records(bufnr, state)
  local session = view()._sessions[bufnr]
  local cv = session and session.current_view
  if cv and cv ~= "records" then
    session.state = state
    session._records_state = state
    -- Refreshing the Columns view is the explicit way to see a DDL change
    if cv == "columns" then session._column_info = nil end
    view().switch_view(bufnr, cv, { force = true })
    return
  end
  view().render(bufnr, state)
end

return M
