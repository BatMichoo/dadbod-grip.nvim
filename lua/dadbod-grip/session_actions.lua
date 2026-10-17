-- session_actions.lua: what a grid does with its staged changes and data —
-- apply (to the database or back to a file), refresh, edit a cell, and the
-- preview shown before a pad INSERT/UPDATE/DELETE runs.

local db       = require("dadbod-grip.db")
local data     = require("dadbod-grip.data")
local view     = require("dadbod-grip.view")
local editor   = require("dadbod-grip.editor")
local sql      = require("dadbod-grip.sql")
local esc      = sql.escape_literal
local query    = require("dadbod-grip.query")
local ui       = require("dadbod-grip.ui")
local filetypes = require("dadbod-grip.filetypes")
local adapters = require("dadbod-grip.adapters")
local OPTS     = require("dadbod-grip.config").values

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripSessionActions", { clear = true })

--- Compute where the cursor should land after editing a cell (spreadsheet-style advance).
--- Returns {line, col} (1-indexed line, 0-indexed byte col) or nil if position cannot be
--- determined. Always uses the NEXT row's byte_positions, never the current cursor offset.
function M._next_edit_cursor(r, edited_row_idx, edited_col)
  local ordered = r.ordered
  if not ordered or #ordered == 0 then return nil end
  local edit_order
  for i, ri in ipairs(ordered) do
    if ri == edited_row_idx then edit_order = i; break end
  end
  if not edit_order then return nil end
  local next_order = math.min(edit_order + 1, #ordered)
  local next_line  = (r.data_start or 4) + next_order - 1
  local bp     = r.byte_positions and r.byte_positions[next_order]
  local col_bp = bp and bp[edited_col]
  if not col_bp then return nil end
  return { line = next_line, col = col_bp.start }
end

-- ── file write-back ───────────────────────────────────────────────────────
-- Applies staged changes to a local file by creating a temp table, mutating it,
-- then COPY TO-ing back to the original path. file_path must be a local path.
local function do_apply_file_writeback(bufnr, session)
  local st = session.state
  local file_path = session.file_path
  local fmt = filetypes.write_format(file_path)
  if not fmt then
    vim.notify("Write mode does not support this file format", vim.log.levels.ERROR)
    return
  end

  local updates = data.get_updates(st)
  local inserts = data.get_inserts(st)
  local deletes = data.get_deletes(st)
  local total = #updates + #inserts + #deletes

  if total == 0 then
    vim.notify("No changes to apply", vim.log.levels.INFO)
    return
  end

  -- Destructive-action confirm
  local short = vim.fn.fnamemodify(file_path, ":t")
  if not ui.confirm("Overwrite " .. short .. " (" .. total .. " change(s))? (y/N): ") then
    vim.notify("Write-back cancelled", vim.log.levels.INFO)
    return
  end

  local safe_path = esc(file_path)
  local stmts = {}

  -- 1. Create temp table with synthetic row-number PK
  table.insert(stmts,
    string.format("CREATE TEMP TABLE _grip_w AS SELECT ROW_NUMBER() OVER () AS _grip_rowid, * FROM '%s'", safe_path)
  )

  -- 2. Apply deletes (by row index)
  for _, del in ipairs(deletes) do
    table.insert(stmts, string.format("DELETE FROM _grip_w WHERE _grip_rowid = %d", del.row_idx))
  end

  -- 3. Apply updates (by row index)
  for _, upd in ipairs(updates) do
    local set_parts = {}
    for col, val in pairs(upd.changes) do
      local qval = (val == nil or val == data.NULL_SENTINEL) and "NULL"
                   or sql.quote_value(tostring(val))
      table.insert(set_parts, sql.quote_ident(col) .. " = " .. qval)
    end
    if #set_parts > 0 then
      table.insert(stmts, string.format(
        "UPDATE _grip_w SET %s WHERE _grip_rowid = %d",
        table.concat(set_parts, ", "), upd.row_idx
      ))
    end
  end

  -- 4. Apply inserts (no rowid needed: appended at end)
  for _, ins in ipairs(inserts) do
    table.insert(stmts, sql.build_insert("_grip_w", ins.values, ins.columns))
  end

  -- 5. Copy back to original file
  local copy_extra = fmt == "CSV" and ", HEADER TRUE" or ""
  table.insert(stmts, string.format(
    "COPY (SELECT * EXCLUDE (_grip_rowid) FROM _grip_w ORDER BY _grip_rowid) TO '%s' (FORMAT %s, OVERWRITE_OR_IGNORE TRUE%s)",
    safe_path, fmt, copy_extra
  ))

  -- 6. Drop temp table
  table.insert(stmts, "DROP TABLE _grip_w")

  local full_sql = table.concat(stmts, ";\n") .. ";"
  local t0 = vim.uv.hrtime()
  local _, err = db.execute(full_sql, "duckdb::memory:")
  local ms = math.floor((vim.uv.hrtime() - t0) / 1e6)

  if err then
    editor.show_error("Write-back failed", {
      "✗ File not overwritten", "",
      "  " .. (err:match("[^\n]+") or err), "",
      "  Your staged changes are preserved.",
    })
    return
  end

  local parts = {}
  if #updates > 0 then table.insert(parts, #updates .. " update(s)") end
  if #deletes > 0 then table.insert(parts, #deletes .. " delete(s)") end
  if #inserts > 0 then table.insert(parts, #inserts .. " insert(s)") end
  vim.notify(
    "Written " .. table.concat(parts, ", ") .. " to " .. short .. " (" .. ms .. "ms)",
    vim.log.levels.INFO
  )

  local history = require("dadbod-grip.history")
  history.record({ sql = full_sql, url = "duckdb::memory:", table_name = file_path, type = "writeback", elapsed_ms = ms })

  session.elapsed_ms = ms
  session.last_action = "writeback"
  session.on_refresh(bufnr)
end

-- ── apply staged changes ──────────────────────────────────────────────────
local function do_apply(bufnr, url)
  local session = view._sessions[bufnr]
  if not session then return end

  -- File write-back path: session is a local file opened in write mode
  if session.write_mode and session.file_path
      and not session.file_path:match("^https?://") then
    do_apply_file_writeback(bufnr, session)
    return
  end

  local st = session.state

  local updates = data.get_updates(st)
  local inserts = data.get_inserts(st)
  local deletes = data.get_deletes(st)

  local total = #updates + #inserts + #deletes
  if total == 0 then
    vim.notify("No changes to apply", vim.log.levels.INFO)
    return
  end

  -- Build all statements
  local stmts = {}

  -- Deletes first (avoids FK conflicts with inserts)
  for _, del in ipairs(deletes) do
    table.insert(stmts, sql.build_delete(st.table_name, del.pk_values))
  end
  for _, upd in ipairs(updates) do
    table.insert(stmts, sql.build_update(st.table_name, upd.pk_values, upd.changes))
  end
  for _, ins in ipairs(inserts) do
    table.insert(stmts, sql.build_insert(st.table_name, ins.values, ins.columns))
  end

  -- Wrap in transaction for atomicity (all or nothing)
  local txn_sql = sql.wrap_transaction(stmts, require("dadbod-grip.adapters").kind(url))
  local t_apply = vim.uv.hrtime()
  local _, err = db.execute(txn_sql, url)
  local apply_ms = math.floor((vim.uv.hrtime() - t_apply) / 1e6)

  if err then
    -- Transaction failed: DB auto-rolled back
    local err_lines = { "✗ Transaction rolled back (" .. total .. " statement(s))", "" }
    for chunk in (err .. "\n"):gmatch("([^\n]+)\n?") do
      if chunk ~= "" then table.insert(err_lines, "  " .. chunk) end
    end
    table.insert(err_lines, "")
    table.insert(err_lines, "  Your changes are preserved. Fix the value or press u to undo.")
    editor.show_error("Apply failed", err_lines)
    return
  end

  -- Success: compute reverse SQL for transaction undo before clearing staging
  local reverse_stmts = {}
  local col_idx = {}
  for i, col in ipairs(st.columns) do col_idx[col] = i end

  -- Reverse of DELETE = INSERT with full original row data
  for _, del in ipairs(deletes) do
    local row_values = {}
    for _, col in ipairs(st.columns) do
      row_values[col] = data.from_csv_raw(st.rows[del.row_idx][col_idx[col]])
    end
    table.insert(reverse_stmts, sql.build_insert(st.table_name, row_values, st.columns))
  end

  -- Reverse of UPDATE = UPDATE with original pre-change values
  for _, upd in ipairs(updates) do
    local orig_values = {}
    for col, _ in pairs(upd.changes) do
      orig_values[col] = data.from_csv_raw(st.rows[upd.row_idx][col_idx[col]])
    end
    table.insert(reverse_stmts, sql.build_update(st.table_name, upd.pk_values, orig_values))
  end

  -- Reverse of INSERT = DELETE by PK.
  -- If the user typed an explicit PK (plain INSERT), use it directly.
  -- If PK was auto-assigned (clone / new-row with SERIAL/UUID), find the row
  -- by matching non-PK values after commit, then build reverse DELETE.
  for _, ins in ipairs(inserts) do
    local ins_pk_values = {}
    for _, pk in ipairs(st.pks) do
      ins_pk_values[pk] = ins.values[pk]
    end

    if not next(ins_pk_values) and #st.pks > 0 then
      -- Auto-assigned PK: locate the row by non-PK values (best-effort)
      local pk_set = {}
      for _, pk in ipairs(st.pks) do pk_set[pk] = true end
      local where_parts = {}
      for col, val in pairs(ins.values) do
        if not pk_set[col] and val and val ~= "" and val ~= data.NULL_SENTINEL then
          table.insert(where_parts, sql.quote_ident(col) .. " = " .. sql.quote_value(tostring(val)))
        end
      end
      if #where_parts > 0 then
        local pk_cols = table.concat(vim.tbl_map(function(pk)
          return sql.quote_ident(pk)
        end, st.pks), ", ")
        -- ORDER BY pk DESC picks the highest (most recently inserted) matching row
        local find_sql = "SELECT " .. pk_cols
          .. " FROM " .. sql.quote_ident(st.table_name)
          .. " WHERE " .. table.concat(where_parts, " AND ")
          .. " ORDER BY " .. sql.quote_ident(st.pks[1]) .. " DESC LIMIT 1"
        local r, _ = db.query(find_sql, url)
        if r and r.rows and r.rows[1] then
          for i, pk in ipairs(st.pks) do
            ins_pk_values[pk] = r.rows[1][i]
          end
        end
      end
    end

    if next(ins_pk_values) then
      table.insert(reverse_stmts, sql.build_delete(st.table_name, ins_pk_values))
    end
  end

  -- Store in transaction undo stack
  if #reverse_stmts > 0 then
    session._txn_undo_stack = session._txn_undo_stack or {}
    table.insert(session._txn_undo_stack, reverse_stmts)
    if #session._txn_undo_stack > 10 then table.remove(session._txn_undo_stack, 1) end
  end

  -- Clear local staging undo stack (stale pre-apply states)
  session._undo_stack = {}

  -- Notify, record history, and refresh
  local parts = {}
  if #updates > 0 then table.insert(parts, #updates .. " update(s)") end
  if #deletes > 0 then table.insert(parts, #deletes .. " delete(s)") end
  if #inserts > 0 then table.insert(parts, #inserts .. " insert(s)") end
  vim.notify("Applied " .. table.concat(parts, ", "), vim.log.levels.INFO)

  local history = require("dadbod-grip.history")
  history.record({ sql = txn_sql, url = url, table_name = st.table_name, type = "dml" })

  session.elapsed_ms = apply_ms
  -- Build action label from what was applied
  local action_parts = {}
  if #updates > 0 then table.insert(action_parts, "updated") end
  if #inserts > 0 then table.insert(action_parts, "inserted") end
  if #deletes > 0 then table.insert(action_parts, "deleted") end
  session.last_action = table.concat(action_parts, "+")
  session.on_refresh(bufnr)
end

-- ── refresh ───────────────────────────────────────────────────────────────

--- Spinner label for a grid reload: the bare table name (no schema prefix),
--- one line, capped so a long name cannot outgrow the float.
local function spinner_label(table_name)
  local label = table_name and (table_name:match("[^.]+$") or table_name) or "result"
  return ((label:match("^([^\n]+)") or "query"):sub(1, 50))
end

--- Every db round-trip one refresh needs. Split out of do_refresh so a caller
--- that has its own db work to do first (on_requery runs a COUNT) can put the
--- whole batch inside one ui.blocking float instead of flashing two.
---
--- Returns ONE table, never a bare `nil, err`: ui.blocking() forwards its fn's
--- returns through table.unpack, which drops everything after a leading nil.
--- @return table { result: table|nil, err: string|nil, elapsed_ms: number }
local function fetch_refresh(url, query_sql, table_name)
  local t0 = vim.uv.hrtime()
  local result, err = db.query(query_sql, url)
  local elapsed_ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
  if err then return { err = err, elapsed_ms = elapsed_ms } end

  -- Empty result: fetch columns from schema (adapter returns none for 0 rows)
  if (#result.columns == 0) and table_name then
    local col_info = db.get_column_info(table_name, url)
    if col_info then
      for _, ci in ipairs(col_info) do
        table.insert(result.columns, ci.column_name)
      end
    end
  end

  -- Re-fetch primary keys
  result.readonly, result.readonly_reason = db.is_readonly(url)
  if table_name and not result.readonly then
    local pks, pk_err = db.get_primary_keys(table_name, url)
    result.primary_keys = (pk_err == nil) and pks or {}
    result.pk_error = pk_err
  else
    result.primary_keys = {}
  end

  result.table_name = table_name
  result.url = url
  result.sql = query_sql
  return { result = result, elapsed_ms = elapsed_ms }
end

--- Render what fetch_refresh returned. Kept outside the spinner float so the
--- grid repaints after it is torn down, the same order init.open() uses.
local function apply_refresh(bufnr, fetched)
  if not fetched or not fetched.result then
    vim.notify("Grip: query failed: " .. tostring((fetched and fetched.err) or "unknown error"),
      vim.log.levels.ERROR)
    return
  end
  local new_state = data.new(fetched.result)
  local session = view._sessions[bufnr]
  if session then
    session.elapsed_ms = fetched.elapsed_ms
    session.last_action = "query"
  end
  view.apply_records(bufnr, new_state)
end

local function do_refresh(bufnr, url, query_sql, table_name)
  local fetched = ui.blocking("  querying " .. spinner_label(table_name) .. "...", function()
    return fetch_refresh(url, query_sql, table_name)
  end)
  apply_refresh(bufnr, fetched)
end

-- ── edit cell ─────────────────────────────────────────────────────────────
local function do_edit(bufnr, cell, url)
  local session = view._sessions[bufnr]
  if not session then return end

  -- Binary columns: not editable
  local val = cell.value or ""
  if val:sub(1, #"<binary") == "<binary" then
    vim.notify("Binary column: not editable", vim.log.levels.INFO)
    return
  end

  local prompt = (session.state.table_name or "row") .. "." .. cell.col_name
  local edited_row_idx = cell.row_idx
  local edited_col    = cell.col_name

  -- JSON-aware edit: pretty-print JSON/jsonb before opening the editor.
  -- On save, the (still-valid JSON) value is written back as-is.
  local initial_val = cell.value
  local is_json = false
  if initial_val and #initial_val > 1 then
    local json_ok, json_decoded = pcall(vim.json.decode, initial_val)
    if json_ok and type(json_decoded) == "table" then
      is_json = true
      local json_lines = view._json_to_lines and view._json_to_lines(json_decoded)
      if json_lines and #json_lines > 0 then
        initial_val = table.concat(json_lines, "\n")
      end
    end
  end

  -- JSON cells get a taller/wider float with JSON syntax highlighting
  local edit_opts = {}
  if is_json then
    edit_opts.max_h = 25
    edit_opts.max_w = 110
    edit_opts.ft    = "json"
  end

  -- Enum hint: columns with few distinct values show them as virtual text
  -- in the editor (fetched once per session, cached on session.enum_cache).
  edit_opts.enum_values = view.enum_hint_values(session, cell.col_name)

  -- Capture cursor before the float opens. The editor.open/close cycle (stopinsert
  -- + window switch) shifts the grid cursor by 1, accumulating on every Enter.
  -- Pre-capturing gives us the ground truth for restoration in all three cases:
  -- cancel, no-mutation save, and valid mutation (where we advance the LINE only).
  local _pre_w = vim.fn.bufwinid(bufnr)
  local _pre_cursor = _pre_w ~= -1 and vim.api.nvim_win_get_cursor(_pre_w) or nil

  -- Restore cursor to target position, resisting plugin WinEnter chains via SafeState.
  local function _restore(target)
    if not target then return end
    local w = vim.fn.bufwinid(bufnr)
    if w ~= -1 then pcall(vim.api.nvim_win_set_cursor, w, target) end
    local tl, tc = target[1], target[2]
    vim.api.nvim_create_autocmd("SafeState", {
      group = _ag, once = true,
      callback = function()
        local w2 = vim.fn.bufwinid(bufnr)
        if w2 ~= -1 then pcall(vim.api.nvim_win_set_cursor, w2, { tl, tc }) end
      end,
    })
  end

  editor.open(prompt, initial_val, function(new_val)
    if new_val == nil then  -- cancelled
      _restore(_pre_cursor)
      return
    end

    -- Skip staging if nothing actually changed
    local was_null = cell.value == nil
    local now_null = new_val == editor.NULL_VALUE
    if now_null and was_null then
      _restore(_pre_cursor)
      return
    end
    if not now_null and not was_null and new_val == initial_val then
      _restore(_pre_cursor)
      return
    end

    -- Valid mutation: stage and advance to next row (spreadsheet style).
    local actual_val = editor.resolve_null(new_val)
    local new_state = data.add_change(session.state, cell.row_idx, cell.col_name, actual_val)
    view.apply_edit(bufnr, new_state)

    -- Use _next_edit_cursor for the target LINE, but _pre_cursor[2] for the COLUMN
    -- so the column never drifts regardless of col_bp.start vs actual cursor offset.
    local s = view._sessions[bufnr]
    local next_pos = s and s._render and M._next_edit_cursor(s._render, edited_row_idx, edited_col)
    if next_pos and _pre_cursor then
      _restore({ next_pos.line, _pre_cursor[2] })
    else
      _restore(_pre_cursor)
    end
  end, edit_opts)
end

-- ── parse INSERT VALUES ───────────────────────────────────────────────────
-- Best-effort parser for INSERT ... VALUES (...), (...).
-- Returns list of {col = val} tables. Skips INSERT...SELECT (no VALUES keyword).
local function parse_insert_values(flat, columns)
  if not flat:find("[Vv][Aa][Ll][Uu][Ee][Ss]") then return {} end

  -- Extract column list between INSERT INTO tbl (...) VALUES
  -- Pattern: everything in parens before the VALUES keyword
  local col_str = flat:match("[Ii][Nn][Ss][Ee][Rr][Tt][^(]+%(([^)]+)%)%s*[Vv][Aa][Ll][Uu][Ee][Ss]")
  local insert_cols
  if col_str then
    insert_cols = {}
    for part in col_str:gmatch("[^,]+") do
      local col = part:match("^%s*(.-)%s*$"):gsub('^"(.*)"$', "%1"):gsub("^`(.*)`$", "%1")
      if col ~= "" then table.insert(insert_cols, col) end
    end
  else
    insert_cols = columns  -- no column list: assume schema order
  end
  if #insert_cols == 0 then return {} end

  local values_part = flat:match("[Vv][Aa][Ll][Uu][Ee][Ss]%s*(.*)")
  if not values_part then return {} end

  local rows = {}
  local pos = 1
  while pos <= #values_part do
    local pstart = values_part:find("%(", pos)
    if not pstart then break end
    -- Walk to matching ')' respecting single-quoted strings
    local depth, i = 1, pstart + 1
    while i <= #values_part and depth > 0 do
      local ch = values_part:sub(i, i)
      if ch == "'" then
        i = i + 1
        while i <= #values_part do
          if values_part:sub(i, i) == "'" then
            if values_part:sub(i + 1, i + 1) == "'" then i = i + 2
            else i = i + 1; break end
          else i = i + 1 end
        end
      elseif ch == "(" then depth = depth + 1; i = i + 1
      elseif ch == ")" then depth = depth - 1; i = i + 1
      else i = i + 1 end
    end
    local tuple = values_part:sub(pstart + 1, i - 2)
    pos = i

    -- Tokenize the tuple
    local vals, ti, tn = {}, 1, #tuple
    while ti <= tn do
      while ti <= tn and (tuple:sub(ti, ti) == "," or tuple:sub(ti, ti):match("^%s$")) do ti = ti + 1 end
      if ti > tn then break end
      local token
      if tuple:sub(ti, ti) == "'" then
        local tj = ti + 1
        while tj <= tn do
          if tuple:sub(tj, tj) == "'" then
            if tuple:sub(tj + 1, tj + 1) == "'" then tj = tj + 2
            else break end
          else tj = tj + 1 end
        end
        token = tuple:sub(ti + 1, tj - 1):gsub("''", "'")
        ti = tj + 1
      else
        local tj = ti
        while tj <= tn and tuple:sub(tj, tj) ~= "," do tj = tj + 1 end
        token = tuple:sub(ti, tj - 1):match("^%s*(.-)%s*$")
        if token:upper() == "NULL" then token = nil end
        ti = tj
      end
      table.insert(vals, token)
    end

    local row = {}
    for j, col in ipairs(insert_cols) do row[col] = vals[j] end
    table.insert(rows, row)
  end
  return rows
end

-- ── mutation preview ──────────────────────────────────────────────────────
-- Shows affected rows in a grid before executing UPDATE/DELETE/INSERT.
function M._mutation_preview(mutation_sql, url, stmt_type, caller_opts)
  local sql_mod = require("dadbod-grip.sql")

  -- Extract table name from the SQL (handles quoted identifiers)
  local flat = mutation_sql:gsub("\n", " ")
  local table_name
  if stmt_type == "UPDATE" then
    local after_update = flat:match("[Uu][Pp][Dd][Aa][Tt][Ee]%s+(.*)")
    if after_update then
      table_name = after_update:match('^"([^"]+)"') or after_update:match("^`([^`]+)`") or after_update:match("^([%w_%.]+)")
    end
  elseif stmt_type == "DELETE" then
    table_name = flat:match('[Ff][Rr][Oo][Mm]%s+"([^"]+)"')
      or flat:match("[Ff][Rr][Oo][Mm]%s+`([^`]+)`")
      or flat:match("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)")
  elseif stmt_type == "INSERT" then
    table_name = flat:match('[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+"([^"]+)"')
      or flat:match("[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+`([^`]+)`")
      or flat:match("[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+([%w_%.]+)")
  end

  if not table_name then
    vim.notify("Could not parse table from " .. stmt_type, vim.log.levels.ERROR)
    return
  end

  -- Extract WHERE clause (not applicable for INSERT)
  local where
  if stmt_type ~= "INSERT" then
    where = flat:match("[Ww][Hh][Ee][Rr][Ee]%s+(.+)$")
    if where then
      where = where:gsub("%s*;%s*$", "")
      -- Strip trailing ORDER BY, LIMIT etc.
      where = where:gsub("%s+[Oo][Rr][Dd][Ee][Rr]%s+[Bb][Yy].*$", "")
      where = where:gsub("%s+[Ll][Ii][Mm][Ii][Tt]%s+.*$", "")
    end
  end

  -- Build preview SELECT (INSERT shows full current table state)
  local preview_sql = "SELECT * FROM " .. sql_mod.quote_ident(table_name)
  if where and where ~= "" then
    preview_sql = preview_sql .. " WHERE " .. where
  end

  -- Run preview query
  local result, err = db.query(preview_sql, url)
  if not result then
    vim.notify("Preview failed: " .. (err or "query error"), vim.log.levels.ERROR)
    return
  end

  -- Fetch columns from schema if needed (empty result)
  if #result.columns == 0 then
    local col_info = db.get_column_info(table_name, url)
    if col_info then
      for _, ci in ipairs(col_info) do table.insert(result.columns, ci.column_name) end
    end
  end

  -- Fetch PKs
  result.readonly = db.is_readonly(url)
  local pks = result.readonly and {} or (db.get_primary_keys(table_name, url) or {})
  result.primary_keys = pks
  result.table_name = table_name
  result.url = url
  result.sql = preview_sql

  local state = data.new(result)
  local row_count = #result.rows

  -- For UPDATE: parse SET clause and pre-stage changes so cells show as blue
  if stmt_type == "UPDATE" and row_count > 0 then
    local set_clause = flat:match("[Ss][Ee][Tt]%s+(.-)%s+[Ww][Hh][Ee][Rr][Ee]")
      or flat:match("[Ss][Ee][Tt]%s+(.-)%s*;?%s*$")
    if set_clause then
      -- Parse "col = 'val', col2 = 'val2'" assignments
      for assignment in set_clause:gmatch("([^,]+)") do
        local col_raw, val_raw = assignment:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if col_raw and val_raw then
          -- Strip quotes from column name
          local col = col_raw:match('^"([^"]+)"$') or col_raw:match("^`([^`]+)`$") or col_raw:match("^%s*(%S+)%s*$")
          -- Strip quotes from value
          local val = val_raw:match("^'(.-)'$") or val_raw:match('^"(.-)"$') or val_raw
          if col and val then
            -- Apply as staged change to every row
            for row_idx = 1, #state.rows do
              state = data.add_change(state, row_idx, col, val)
            end
          end
        end
      end
    end
  end

  -- For DELETE: mark all rows as deleted so they show red
  if stmt_type == "DELETE" and row_count > 0 then
    for row_idx = 1, #state.rows do
      state = data.toggle_delete(state, row_idx)
    end
  end

  -- For INSERT with VALUES: parse and add new rows highlighted green
  if stmt_type == "INSERT" then
    local insert_rows = parse_insert_values(flat, result.columns)
    for _, row_values in ipairs(insert_rows) do
      state = data.insert_row_with_values(state, #result.rows, row_values)
    end
    row_count = #insert_rows  -- count = rows being inserted, not existing rows
  end

  -- Open grid with pending_mutation metadata
  local reuse_win = caller_opts and caller_opts.reuse_win
  local view_opts = {
    max_col_width = OPTS.max_col_width,
    pending_mutation = {
      sql = mutation_sql,
      type = stmt_type,
      table_name = table_name,
      row_count = row_count,
    },
  }
  if reuse_win then view_opts.reuse_win = reuse_win end

  local bufnr = view.open(state, url, preview_sql, view_opts)

  -- Store mutation info on session and re-render to pick up title/hints
  local session = view._sessions[bufnr]
  if session then
    session.pending_mutation = view_opts.pending_mutation
    session.query_spec = query.new_raw(preview_sql, OPTS.limit)
    if stmt_type == "INSERT" then
      if row_count > 0 then
        session._mutation_title = string.format("INSERT into %s (%d new row%s)",
          table_name, row_count, row_count == 1 and "" or "s")
      else
        -- INSERT ... SELECT or unparseable VALUES
        session._mutation_title = string.format("INSERT into %s (current state)", table_name)
      end
    else
      session._mutation_title = string.format("%s %s (%d row%s)",
        stmt_type, table_name, row_count, row_count == 1 and "" or "s")
    end

    -- Wire refresh callback so grid updates after mutation executes
    view.set_callbacks(bufnr, {
      on_refresh = function(bid)
        do_refresh(bid, url, preview_sql, table_name)
      end,
    })

    view.render(bufnr, session.state)  -- re-render with mutation title + hints
  end
end

M.do_apply = do_apply
M.spinner_label = spinner_label
M.fetch_refresh = fetch_refresh
M.apply_refresh = apply_refresh
M.do_refresh = do_refresh
M.do_edit = do_edit

return M
