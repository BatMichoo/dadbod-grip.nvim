-- view.lua: grid buffers. One buffer per grip session, state in
-- M._sessions[bufnr]. This file opens and renders grids and wires their
-- keymaps; the parts live under view/:
--   render.lua     layout: lines and highlights for a session
--   cells.lua      cursor <-> cell mapping, horizontal reveal
--   winbar.lua     sticky header and badges        watch.lua  timed refresh
--   floats.lua     Live SQL and info floats         help.lua   ? popup
--   meta_views.lua Columns/Keys/Indexes/... views  fk_nav.lua FK jumps
--   export.lua     export and yank                 keymaps_*.lua key groups

local data    = require("dadbod-grip.data")
local sql     = require("dadbod-grip.sql")
local db      = require("dadbod-grip.db")
local editor  = require("dadbod-grip.editor")

local M = {}
M._sessions = {}  -- [bufnr] = { state, url, query_sql }

--- Canonical content window finder: unpinned grid > welcome screen > nil.
--- Pinned sessions are excluded: callers must not auto-replace them.
--- All window-placement callers use this. Never returns sidebar or query pad.
function M.find_content_win()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  -- Pass 1: prefer an unpinned grip grid.
  for _, wid in ipairs(wins) do
    local s = M._sessions[vim.api.nvim_win_get_buf(wid)]
    if s and not s.pinned then return wid end
  end
  -- Pass 2: fall back to the welcome screen.
  for _, wid in ipairs(wins) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wid)) == "grip://welcome" then
      return wid
    end
  end
  -- All grids are pinned (or none exist): caller will create a new split.
  return nil
end

-- ── enum hint ──────────────────────────────────────────────────────────────
-- A column with few distinct values (a status/role/enum-ish column) gets its
-- values shown as a virtual hint line in the cell editor. Values are fetched
-- on demand (SELECT DISTINCT ... LIMIT threshold+1) and cached per session,
-- so repeat edits are instant. Columns with more distinct values, free-text
-- columns, and grids without a real table (ad-hoc SQL, staged-insert-only)
-- get no hint at all.
local ENUM_HINT_MAX = 8  -- show hint only for <= this many distinct non-NULL values

--- Known distinct values for session's table column, or nil when the column
--- isn't enum-ish. Cached on session.enum_cache[table][col] (false = negative).
function M.enum_hint_values(session, col_name)
  if not session or not session.state or not col_name then return nil end
  local tbl = session.state.table_name
  if not tbl then return nil end  -- no table context: ad-hoc query / staged-only grid

  session.enum_cache = session.enum_cache or {}
  session.enum_cache[tbl] = session.enum_cache[tbl] or {}
  local cached = session.enum_cache[tbl][col_name]
  if cached ~= nil then
    return cached or nil  -- false = cached negative
  end

  local col_q = sql.quote_ident(col_name)
  local distinct_sql = string.format(
    "SELECT DISTINCT %s FROM %s WHERE %s IS NOT NULL ORDER BY 1 LIMIT %d",
    col_q, sql.quote_ident(tbl), col_q, ENUM_HINT_MAX + 1
  )
  local result = db.query(distinct_sql, session.state.url)
  if not result or not result.rows or #result.rows == 0 or #result.rows > ENUM_HINT_MAX then
    session.enum_cache[tbl][col_name] = false  -- error / empty / too wide: cache negative
    return nil
  end

  local values = {}
  for _, row in ipairs(result.rows) do
    if row[1] and row[1] ~= "" then table.insert(values, row[1]) end
  end
  if #values == 0 then
    session.enum_cache[tbl][col_name] = false
    return nil
  end
  session.enum_cache[tbl][col_name] = values
  return values
end

local highlights = require("dadbod-grip.view.highlights")
local ensure_highlights = highlights.ensure
M.set_connection_accent = highlights.set_connection_accent

-- Module-level augroup for all buffer/window lifecycle autocmds in this module.
-- Created once at require time with clear=true so re-sourcing never doubles handlers.
local _ag = vim.api.nvim_create_augroup("DadbodGripView", { clear = true })

local render = require("dadbod-grip.view.render")
local profile = render.profile
local NULL_DISPLAY = render.NULL_DISPLAY
local VIEW_LABELS = require("dadbod-grip.view.meta_views").LABELS
local build_render = render.build_render
local is_editable = render.is_editable
local classify_cell = render.classify_cell
local format_cell = render.format_cell
local truncate_display = render.truncate_display
M._is_editable = is_editable  -- exposed for cell_buffer.lua
M._distribute_slack = render._distribute_slack

-- ── namespace for extmarks ───────────────────────────────────────────────
local ns = vim.api.nvim_create_namespace("dadbod_grip")
local _col_hl_ns = vim.api.nvim_create_namespace("grip_col_hl")

-- M.update_table_sessions(old_name, new_name): patch all open grip sessions
-- that reference old_name after a table rename, then refresh them.
function M.update_table_sessions(old_name, new_name)
  local sql_mod = require("dadbod-grip.sql")
  local old_quoted = sql_mod.quote_ident(old_name)
  local new_quoted = sql_mod.quote_ident(new_name)
  for bufnr, session in pairs(M._sessions) do
    if session.state and session.state.table_name == old_name then
      -- Update the query SQL string in-place (replace first occurrence, escaped)
      if session.query_sql then
        session.query_sql = session.query_sql:gsub(vim.pesc(old_quoted), new_quoted, 1)
      end
      -- Update query_spec.table_name so on_refresh rebuilds SQL with new name
      if session.query_spec and session.query_spec.table_name == old_name then
        session.query_spec = vim.tbl_extend("force", session.query_spec, { table_name = new_name })
      end
      -- Update state table_name
      session.state = vim.tbl_extend("force", session.state, { table_name = new_name })
      -- Refresh the buffer
      if session.on_refresh and vim.api.nvim_buf_is_valid(bufnr) then
        vim.schedule(function() session.on_refresh(bufnr) end)
      end
    end
  end
end

-- M.render(bufnr, state): wipes and rewrites buffer, reapplies extmarks
function M.render(bufnr, state)
  local session = M._sessions[bufnr]
  if not session then return end
  session.state = state

  -- Save cursor position before re-render
  local saved_cursor
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    saved_cursor = vim.api.nvim_win_get_cursor(win)
  end

  local opts = session.opts or {}
  local rendered = profile("build_render", function()
    return build_render(session, opts)
  end)
  session._render = rendered  -- cache for get_cell
  session._col_hl = nil       -- column-highlight memo belongs to the old render

  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })

  local ok, err = pcall(function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, rendered.lines)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, _col_hl_ns, 0, -1)

    for _, m in ipairs(rendered.marks) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, m.line, m.col, {
        end_col = m.end_col,
        hl_group = m.hl,
        priority = 100,
      })
    end

  end)

  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

  -- Restore cursor position
  if saved_cursor and win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win, saved_cursor)
  end

  if not ok then
    vim.notify("Grip: render error: " .. tostring(err), vim.log.levels.WARN)
  end

  -- Update live SQL float if active
  M._update_live_sql_float(session)

  -- The sticky header mirrors this render's column row; a new render (sort,
  -- filter, FK jump, tab view) changes it, so refresh the winbar with it.
  -- Drop the cached connection mode with it: a render is rare enough to pay
  -- for the file read the RO badge needs, a CursorMoved is not.
  session._ro_mode = nil
  M._update_winbar(bufnr)
end

local UNDO_STACK_MAX = 50

-- M.apply_edit(bufnr, new_state): pushes current state to undo stack, then renders.
-- Use this for user-initiated edits (not for refresh/requery).
function M.apply_edit(bufnr, new_state)
  local session = M._sessions[bufnr]
  if not session then return end
  if not session._undo_stack then session._undo_stack = {} end
  table.insert(session._undo_stack, session.state)
  if #session._undo_stack > UNDO_STACK_MAX then
    table.remove(session._undo_stack, 1)
  end
  session._redo_stack = nil  -- new edit clears redo
  M.render(bufnr, new_state)
end

local floats = require("dadbod-grip.view.floats")
M._update_live_sql_float = floats._update_live_sql_float
M._close_live_sql_float = floats._close_live_sql_float
M.close_all_floats = floats.close_all_floats

local cells = require("dadbod-grip.view.cells")
M.get_cell = cells.get_cell
M._snap_col = cells._snap_col
M._clamp_data_line = cells._clamp_data_line
M._reveal_leftcol = cells._reveal_leftcol
M._cell_end_byte = cells._cell_end_byte
M._resolve_col_at = cells._resolve_col_at
M._active_col_bp = cells._active_col_bp

local winbar = require("dadbod-grip.view.winbar")
M._update_winbar = winbar._update_winbar
M.invalidate_mode_cache = winbar.invalidate_mode_cache

local watch = require("dadbod-grip.view.watch")

-- ── open ──────────────────────────────────────────────────────────────────
-- Creates split, renders initial state, wires keymaps.
-- Returns bufnr.
function M.open(state, url, query_sql, opts)
  ensure_highlights()

  -- Create a new scratch buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

  local tbl = state.table_name or "result"
  local buf_name = "grip://" .. tbl
  -- For raw query results, embed a SQL preview so multiple results are distinguishable.
  if tbl == "result" and query_sql and query_sql ~= "" then
    local preview = query_sql:gsub("\n", " "):gsub("%s+", " "):gsub("|", "!"):sub(1, 20)
    buf_name = "grip://result [" .. preview .. "...]"
  end
  -- Ensure unique name (avoid collision with grip://query pad or duplicate table opens)
  if vim.fn.bufnr(buf_name) ~= -1 then
    buf_name = buf_name .. "#" .. bufnr
  end
  pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)

  -- Register session before rendering. query_spec is optional: a caller that
  -- has it hands it over here so the very first render can draw the row cap
  -- hint instead of rendering twice.
  M._sessions[bufnr] = {
    state = state,
    url = url,
    query_sql = query_sql,
    opts = opts or {},
    hidden_columns = {},
    elapsed_ms = opts and opts.elapsed_ms or nil,
    write_mode = (opts and opts.write == true) and true or false,
    pinned = false,
    query_spec = opts and opts.query_spec or nil,
  }

  -- Open in existing window (reuse_win) or a new horizontal split below
  local winid
  if opts and opts.reuse_win and vim.api.nvim_win_is_valid(opts.reuse_win) then
    winid = opts.reuse_win
    local prev_buf = vim.api.nvim_win_get_buf(winid)
    -- Inherit pin state before replacing (covers refresh, tab-view switches, apply).
    local prev_was_pinned = M._sessions[prev_buf] and M._sessions[prev_buf].pinned or false
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_set_current_win(winid)  -- focus grip window (Issue #3)
    if prev_was_pinned then M._sessions[bufnr].pinned = true end
    -- Clean up old grip session to prevent stale entries causing duplicate windows
    if prev_buf ~= bufnr and M._sessions[prev_buf] then
      local old_s = M._sessions[prev_buf]
      if old_s then M._close_live_sql_float(old_s) end
      M._sessions[prev_buf] = nil
      pcall(vim.api.nvim_buf_delete, prev_buf, { force = true })
    end
  else
    -- No explicit reuse_win: find the content window (grid > welcome) or create a split.
    local content_win = not (opts and opts.force_split) and M.find_content_win() or nil

    if content_win then
      winid = content_win
      local prev_buf = vim.api.nvim_win_get_buf(winid)
      -- Inherit pin state before replacing.
      local prev_was_pinned = M._sessions[prev_buf] and M._sessions[prev_buf].pinned or false
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.api.nvim_set_current_win(winid)
      if prev_was_pinned then M._sessions[bufnr].pinned = true end
      -- Clean up old grip session if we replaced a grid
      if prev_buf ~= bufnr and M._sessions[prev_buf] then
        local old_s = M._sessions[prev_buf]
        if old_s then M._close_live_sql_float(old_s) end
        M._sessions[prev_buf] = nil
        pcall(vim.api.nvim_buf_delete, prev_buf, { force = true })
      end
    else
      -- No grid or welcome screen: create a new split in the right area
      local schema_mod = require("dadbod-grip.schema")
      local right_win = schema_mod.is_open() and schema_mod.get_right_win()
      if right_win then
        vim.api.nvim_set_current_win(right_win)
        vim.cmd("belowright split")
      else
        vim.cmd("botright split")
      end
      winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
    end
  end

  -- Render
  M.render(bufnr, state)

  -- Move cursor to first data cell, enable row tracking
  -- Byte offset 4 = after "║ " (║ is 3 bytes + 1 space)
  local rendered = M._sessions[bufnr] and M._sessions[bufnr]._render
  pcall(vim.api.nvim_win_set_cursor, winid, { rendered and rendered.data_start or 5, #("║ ") })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("wrap", false, { win = winid })
  vim.api.nvim_set_option_value("sidescrolloff", 5, { win = winid })

  -- Wire keymaps
  M._setup_keymaps(bufnr)

  -- Cleanup session on buffer wipe (also stops watch timer)
  vim.api.nvim_create_autocmd("BufWipeout", {
    group  = _ag,
    buffer = bufnr,
    once = true,
    callback = function()
      local s = M._sessions[bufnr]
      if s then
        M._close_live_sql_float(s)
        if s.watch_timer then
          pcall(function() s.watch_timer:stop(); s.watch_timer:close() end)
          s.watch_timer = nil
        end
      end
      M._sessions[bufnr] = nil
    end,
  })

  -- Start watch timer if requested via opts; show badge for write/watch
  if (opts and opts.watch_ms) or (opts and opts.write) then
    vim.schedule(function()
      if opts.watch_ms then watch.start(bufnr, opts.watch_ms) end
      M._update_winbar(bufnr)
    end)
  end

  return bufnr
end

-- ── JSON pretty-printer ──────────────────────────────────────────────────
-- Converts a decoded Lua value (from vim.json.decode) into an indented
-- line table suitable for display floats and editor pre-fill.
-- cell_buffer.pretty_lines is the single implementation; the depth cap keeps
-- deeply nested payloads from flooding a float. Returns nil for nil input.
local MAX_JSON_DEPTH = 8
local function json_to_lines(decoded)
  if decoded == nil then return nil end  -- caller signals "no value"
  return require("dadbod-grip.cell_buffer").pretty_lines(decoded, 0, MAX_JSON_DEPTH)
end

-- Expose for testing
M._json_to_lines = json_to_lines

local export = require("dadbod-grip.view.export")
M._format_export = export.format_export
M._request_export_rows = export.request_export_rows
M._write_export_file = export.write_export_file
M.export_to_clipboard = export.export_to_clipboard
M.do_export = export.do_export

local meta_views = require("dadbod-grip.view.meta_views")
M.switch_view = meta_views.switch_view
M.apply_records = meta_views.apply_records

local fk_nav = require("dadbod-grip.view.fk_nav")
M._sync_pad = fk_nav._sync_pad
M._fk_referencing = fk_nav._fk_referencing

--- Tell the user why an edit key did nothing on the current read-only grid.
function M.notify_readonly(bufnr)
  local session = M._sessions[bufnr or vim.api.nvim_get_current_buf()]
  vim.notify(data.readonly_message(session and session.state), vim.log.levels.INFO)
end

-- ── multi-cursor column set ───────────────────────────────────────────────
--- Stage the same value for the current column across ALL visible rows of the
--- visible rows (bulk-edit a status field without SQL or a visual selection).
--- Mirror of the visual-mode batch edit (grid_v_edit) over the rendered rows:
--- rows staged as deleted are skipped, staged INSERT rows are included, and
--- rows not shown in the grid are never touched.
--- Module-level (not a keymap closure) so tests can drive it directly.
function M._column_set(bufnr)
  local session = M._sessions[bufnr]
  if not session or not session._render then return end
  if not is_editable(session) then
    M.notify_readonly()
    return
  end
  local cell = M.get_cell(bufnr)
  if not cell then
    vim.notify("No cell under cursor", vim.log.levels.INFO)
    return
  end
  local col_name = cell.col_name

  -- Visible rows = exactly what the render enumerates,
  -- minus rows already staged as deleted.
  local st = session.state
  local row_indices = {}
  for _, ri in ipairs(session._render.ordered) do
    if not st.deleted[ri] then table.insert(row_indices, ri) end
  end
  if #row_indices == 0 then return end

  -- Guard against accidental huge stages.
  if #row_indices > 50 then
    local choice = vim.fn.confirm(
      "Set " .. col_name .. " for " .. #row_indices .. " rows?",
      "&Yes\n&Cancel", 2
    )
    if choice ~= 1 then return end
  end

  editor.open("Set " .. #row_indices .. " rows (" .. col_name .. ")", cell.value, function(new_val)
    if new_val == nil then return end
    -- NOTE: explicit if, not `x == NULL_VALUE and nil or x` — that and/or
    -- chain short-circuits back to x when the comparison is true.
    local actual = new_val
    if new_val == editor.NULL_VALUE then actual = nil end
    local new_state = session.state
    for _, ri in ipairs(row_indices) do
      new_state = data.add_change(new_state, ri, col_name, actual)
    end
    M.apply_edit(bufnr, new_state)
    vim.notify("Set " .. #row_indices .. " rows in " .. col_name, vim.log.levels.INFO)
  end, {})
end

-- ── keymap wiring ─────────────────────────────────────────────────────────
-- One module per keymap group under view/, each exporting setup(bufnr, ctx);
-- they all share the helper set built once by make_keymap_ctx() instead of
-- redefining it. Registration order matters: for a given lhs the last
-- vim.keymap.set() wins, so _setup_keymaps() walks KEYMAP_SECTIONS in order.
--
-- The section modules never require view.lua: this file requires them, so the
-- reverse would be a cycle. Anything they need from here rides on ctx.

--- The keymap sections, in registration order. This list IS the precedence
--- rule for a duplicated lhs, not a stylistic ordering: reordering it silently
--- changes which mapping survives. Append, do not shuffle.
local KEYMAP_SECTIONS = {
  require("dadbod-grip.view.keymaps_edit"),
  require("dadbod-grip.view.keymaps_visual_batch"),
  require("dadbod-grip.view.keymaps_inspect"),
  require("dadbod-grip.view.keymaps_nav"),
  require("dadbod-grip.view.keymaps_misc"),
  require("dadbod-grip.view.keymaps_sort_filter"),
  require("dadbod-grip.view.keymaps_fk"),
  require("dadbod-grip.view.keymaps_aggregate"),
  require("dadbod-grip.view.keymaps_schema"),
  require("dadbod-grip.view.keymaps_session"),
  require("dadbod-grip.view.keymaps_results"),
  require("dadbod-grip.view.keymaps_tab_view"),
  require("dadbod-grip.view.column_highlight"),
  require("dadbod-grip.view.sticky_header"),
}

--- Helpers shared by every keymap section: the four map wrappers, the visual
--- selection row collector and the cell editor (also reached via <CR>).
--- ctx.view hands the sections this whole module; what they may reach through
--- it is spelled out at the assignment below, and M._sessions is not on that
--- list.
local function make_keymap_ctx(bufnr)
  local km = require("dadbod-grip.keymaps")
  local ctx = { km = km }

  -- Session accessor, deliberately a function: re-running a query replaces the
  -- session table wholesale, so a closure that captured the value would keep
  -- mutating a dead session. Every section must resolve it at call time.
  function ctx.session()
    return M._sessions[bufnr]
  end
  -- Same reason, plus is_editable() is file-local and unreachable once the
  -- sections live in their own modules. Named for its subject: it answers for
  -- ctx.session(), not for whatever session the caller happens to be holding.
  function ctx.session_is_editable()
    return is_editable(M._sessions[bufnr])
  end

  -- The column under the cursor, wherever the cursor is: a data row, the header
  -- or the type row. Column-scoped actions (sort, filter, stats, resize) should
  -- work from all three, and this is the only correct way to get there --
  -- pairing _snap_col with a byte-position map by hand is what got three
  -- handlers reading the header while the cursor sat on the type row.
  -- Actions that need the cell *value* still want view.get_cell(), which is
  -- nil off a data row by design.
  function ctx.cursor_column()
    local session = M._sessions[bufnr]
    local r = session and session._render
    if not r then return nil end
    local cols = r.visible_columns or (session.state and session.state.columns)
    local cursor = vim.api.nvim_win_get_cursor(0)
    return M._resolve_col_at(r, cols, cursor[1], cursor[2])
  end

  -- The view module itself. Handed over rather than require()d by the section
  -- modules: view.lua requires them at load time, so a require back would be a
  -- cycle. Injecting the table keeps the sections free of any view import.
  --
  -- Passing M whole is a shortcut, not a licence. The contract is this list of
  -- functions, and nothing else on M is part of it:
  --   render, switch_view, _snap_col, _clamp_data_line, get_cell,
  --   _cell_end_byte, apply_edit, close_all_floats, _close_live_sql_float,
  --   _update_live_sql_float, show_help, do_export, _format_export,
  --   _json_to_lines, enum_hint_values, _fk_referencing, _column_set
  -- M._sessions in particular is off limits: reaching into the registry lets a
  -- section read or mutate another buffer's session behind the accessors that
  -- exist for exactly that. Use ctx.session() for this buffer, ctx.each_session
  -- for the others.
  ctx.view = M

  -- gL/gJ need every live grid, not just this buffer's. An iterator instead of
  -- the registry table so no section has to name M._sessions.
  function ctx.each_session(fn)
    for b, s in pairs(M._sessions) do fn(b, s) end
  end

  -- File-local render/buffer helpers the sections call. Injected for the same
  -- reason as ctx.view: they are not part of the module's public surface.
  ctx.open_info_float = floats.open_info_float
  ctx.resolve_row_bp  = cells.resolve_row_bp
  ctx.reveal_col_edge = cells.reveal_col_edge
  ctx.update_winbar   = M._update_winbar
  ctx.start_watch     = watch.start
  ctx.stop_watch      = watch.stop
  ctx.augroup         = _ag
  ctx.col_hl_ns       = _col_hl_ns
  ctx.NULL_DISPLAY    = NULL_DISPLAY
  ctx.VIEW_LABELS     = VIEW_LABELS

  function ctx.kmap(action, fn, desc)
    km.bind("grid", bufnr, action, "n", fn, { desc = desc })
  end
  function ctx.kvmap(action, fn, desc)
    km.bind("grid", bufnr, action, "x", fn, { desc = desc })
  end

  -- Helper: collect row indices from visual selection
  function ctx.get_visual_rows()
    local start_line = vim.fn.line("v")
    local end_line = vim.fn.line(".")
    if start_line > end_line then start_line, end_line = end_line, start_line end
    local session = ctx.session()
    if not session or not session._render then return nil end
    local r = session._render
    local ds = r.data_start or 5
    local rows = {}
    for line = start_line, end_line do
      local row_order = line - ds + 1
      if row_order >= 1 and row_order <= #r.ordered then
        table.insert(rows, r.ordered[row_order])
      end
    end
    return rows
  end

  -- e/i: edit cell
  function ctx.edit_cell()
    local session = ctx.session()
    if not session then return end
    if not ctx.session_is_editable() then
      M.notify_readonly()
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("No cell under cursor", vim.log.levels.INFO)
      return
    end
    if session.on_edit then session.on_edit(bufnr, cell) end
  end

  return ctx
end

--- Wire all buffer-local grid keymaps and the column-highlight autocmd.
--- Section order is load bearing (see the note above make_keymap_ctx).
function M._setup_keymaps(bufnr)
  local ctx = make_keymap_ctx(bufnr)
  for _, section in ipairs(KEYMAP_SECTIONS) do
    section.setup(bufnr, ctx)
  end
end

M.show_help = require("dadbod-grip.view.help").show_help

-- Register callbacks for edit/delete/insert/apply/refresh from init.
function M.set_callbacks(bufnr, callbacks)
  local session = M._sessions[bufnr]
  if not session then return end
  for k, v in pairs(callbacks) do
    session[k] = v
  end
end

-- Exposed for testing
M._classify_cell = classify_cell
M._format_cell = format_cell
M._truncate_display = truncate_display

return M
