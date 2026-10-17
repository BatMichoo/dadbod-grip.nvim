-- view.lua: buffer rendering + keymaps.
-- One buffer per grip session. State in M._sessions[bufnr].

local data    = require("dadbod-grip.data")
local sql     = require("dadbod-grip.sql")
local db      = require("dadbod-grip.db")
local editor  = require("dadbod-grip.editor")
local ui      = require("dadbod-grip.ui")

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

-- ── live SQL float ──────────────────────────────────────────────────────
function M._update_live_sql_float(session)
  if not session.live_sql then return end
  local st = session.state
  if not st.table_name then return end

  -- Build content
  local content_lines
  if data.has_changes(st) then
    local preview = sql.preview_staged(
      st.table_name,
      data.get_updates(st),
      data.get_deletes(st),
      data.get_inserts(st)
    )
    content_lines = {}
    for line in (preview .. "\n"):gmatch("([^\n]*)\n") do
      if line ~= "" then table.insert(content_lines, line) end
    end
  else
    content_lines = { "-- stage changes to see live SQL" }
  end

  local editor_cols = vim.o.columns
  local max_line_w = 0
  for _, l in ipairs(content_lines) do max_line_w = math.max(max_line_w, #l) end
  local float_w = math.min(math.max(max_line_w + 4, 30), editor_cols - 10)
  local float_h = math.min(#content_lines, 15)

  -- Reuse existing float or create new one
  if session._live_sql_win and vim.api.nvim_win_is_valid(session._live_sql_win) then
    -- Update buffer contents
    vim.api.nvim_set_option_value("modifiable", true, { buf = session._live_sql_buf })
    vim.api.nvim_buf_set_lines(session._live_sql_buf, 0, -1, false, content_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = session._live_sql_buf })
    -- Resize if needed
    vim.api.nvim_win_set_width(session._live_sql_win, float_w)
    vim.api.nvim_win_set_height(session._live_sql_win, float_h)
  else
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
    vim.api.nvim_set_option_value("filetype", "sql", { buf = buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

    local _ei = vim.o.eventignore
    vim.o.eventignore = "all"
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = math.max(0, vim.o.lines - float_h - 4),
      col = math.max(0, editor_cols - float_w - 2),
      width = float_w,
      height = float_h,
      style = "minimal",
      border = ui.border(),
      title = " Live SQL ",
      title_pos = "center",
      focusable = false,
      zindex = 40,
    })
    vim.o.eventignore = _ei
    session._live_sql_win = win
    session._live_sql_buf = buf
  end
end

function M._close_live_sql_float(session)
  if session._live_sql_win and vim.api.nvim_win_is_valid(session._live_sql_win) then
    vim.api.nvim_win_close(session._live_sql_win, true)
  end
  session._live_sql_win = nil
  session._live_sql_buf = nil
end

--- Close every grip-owned floating window.
--- Called at the start of every 1-9 surface keymap so pressing any number key
--- instantly dismisses open pickers / floats before the target surface opens.
--- @param session? table  grid session; may be nil (e.g. called from query pad)
function M.close_all_floats(session)
  if session then M._close_live_sql_float(session) end
  -- er_diagram tracks its own window; close() is a no-op when nothing is open
  pcall(function() require("dadbod-grip.er_diagram").close() end)
  -- close any grip_picker floats (stamped with grip_owned_float at creation)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative ~= "" then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.b[buf] and vim.b[buf].grip_owned_float then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end
end

-- ── cursor → cell mapping ─────────────────────────────────────────────────
-- M.get_cell(bufnr) → {row_idx, col_name, col_idx, value} | nil
function M.get_cell(bufnr)
  local session = M._sessions[bufnr]
  if not session or not session._render then return nil end

  local r = session._render
  local st = session.state
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_nr = cursor[1]  -- 1-based
  local col_nr  = cursor[2]  -- 0-based byte offset

  -- Data rows start at line 4 (title, header, sep) or 5 (with type row)
  local data_start = r.data_start or 4
  local data_end = data_start + #r.ordered - 1
  if line_nr < data_start or line_nr > data_end then return nil end

  local row_order_idx = line_nr - data_start + 1
  local row_idx = r.ordered[row_order_idx]
  if not row_idx then return nil end

  -- Use cached byte positions from build_render
  -- Iterate visible_columns so col_idx matches the rendered layout
  local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
  local vis_cols = r.visible_columns or st.columns
  if bp_row then
    for i, col in ipairs(vis_cols) do
      local bp = bp_row[col]
      if bp and col_nr >= bp.start and col_nr <= bp.finish then
        local value = data.effective_value(st, row_idx, col)
        return {
          row_idx = row_idx,
          col_name = col,
          col_idx = i,
          value = value,
        }
      end
    end
    -- Cursor is on a separator or border -- snap to nearest LEFT column
    local snap = M._snap_col(vis_cols, bp_row, col_nr)
    if snap then
      return {
        row_idx  = row_idx,
        col_name = snap.col_name,
        col_idx  = snap.col_idx,
        value    = data.effective_value(st, row_idx, snap.col_name),
      }
    end
  end

  return nil
end

--- Pure helper: given visible columns, their byte positions, and a cursor byte offset,
--- return { col_name, col_idx } for the column the cursor belongs to.
--- Snaps LEFT (to the previous column) when cursor is in a separator region,
--- EXCEPT when the cursor is exactly one byte before a column start (last separator
--- byte): in that case snaps RIGHT to the next column. This ensures that actions
--- (edit, sort, filter) fire on the column the user is reaching toward, not the
--- one they left. Used by get_cell() and testable without vim state.
function M._snap_col(vis_cols, bp_row, col_nr)
  local best_col, best_idx = nil, nil
  for i, col in ipairs(vis_cols) do
    local bp = bp_row[col]
    if bp then
      if col_nr < bp.start then
        -- Last separator byte (touching the column) → snap RIGHT to this column.
        if col_nr == bp.start - 1 then
          return { col_name = col, col_idx = i }
        end
        break  -- mid-separator: best_col (previous column) is the snap target
      end
      best_col, best_idx = col, i
    end
  end
  if best_col then
    return { col_name = best_col, col_idx = best_idx }
  end
  -- Cursor is before ALL columns → snap to first
  local first = vis_cols[1]
  if first and bp_row[first] then
    return { col_name = first, col_idx = 1 }
  end
  return nil
end

--- Clamp a buffer line to the data-row range [data_start, data_start + #ordered - 1].
--- The title/header/type/separator rows sit above this range and the footer/hint
--- line sits below it; visual-mode navigation reuses this so `G`/`j`/`k` stop at the
--- last data row instead of overshooting onto the footer (issue #20). Pure/testable.
function M._clamp_data_line(r, line)
  local ds = r.data_start or 4
  local last = ds + #r.ordered - 1
  if last < ds then last = ds end  -- empty result set: collapse to data_start
  if line < ds then return ds end
  if line > last then return last end
  return line
end

--- Compute the horizontal scroll offset (leftcol) needed to bring a column's
--- right edge into view. `$` (grid_col_last) puts the cursor at the start of the
--- last column, but Neovim's default sidescroll leaves a wide column's right edge
--- off-screen. Given the current leftcol, the window's text width, and the
--- column's display-column span [start_vcol, finish_vcol] (all 1-based; a display
--- column c is visible iff leftcol < c <= leftcol + textwidth), return the new
--- leftcol that seats the right edge at the window's right, keeping the column's
--- start visible when the column fits. `margin` reveals that many extra display
--- columns past finish_vcol so the trailing separator/border glyph (" ║" / " │ ")
--- is shown too, not just the cell data. Returns nil when no scroll is needed.
--- Pure/testable.
function M._reveal_leftcol(leftcol, textwidth, start_vcol, finish_vcol, margin)
  margin = margin or 0
  if textwidth <= 0 then return nil end
  local want = finish_vcol + margin                  -- reveal this far to the right
  if want <= leftcol + textwidth then return nil end -- edge (incl. border) already visible
  local target = want - textwidth              -- seat the right edge at the window's right
  if target > start_vcol - 1 then              -- but never scroll the column's start off-screen
    target = start_vcol - 1                     -- (column wider than the window: show the start)
  end
  if target < 0 then target = 0 end
  if target == leftcol then return nil end
  return target
end

--- Map a cell's last byte to the START byte of the character it belongs to — the
--- furthest position a normal-mode cursor can actually reach in that cell. Cells
--- rendered with a trailing multibyte glyph (the … truncation marker or ·NULL·)
--- have bp.finish pointing mid-character; the cursor snaps to the glyph's start,
--- so `e` (grid_col_end) must compare against this instead of bp.finish or it
--- gets stuck re-seeking the same spot. `finish` is a 0-based byte offset.
--- Pure/testable.
function M._cell_end_byte(line, finish)
  local i = finish
  local b = line:byte(i + 1)
  while i > 0 and b and b >= 0x80 and b < 0xC0 do  -- UTF-8 continuation byte (10xxxxxx)
    i = i - 1
    b = line:byte(i + 1)
  end
  return i
end

--- After the cursor has been placed on a column at byte span `bp` on line `lnum`,
--- scroll the window horizontally (if needed) so the column's right edge is
--- visible. Converts the byte span to display columns — grid lines contain
--- multibyte box-drawing chars, so bytes ≠ screen cells — and applies the offset
--- from M._reveal_leftcol via winrestview. No-op when the edge already fits.
local function reveal_col_edge(win, buf, lnum, bp)
  if not (win and bp) then return end
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local start_vcol = vim.fn.strdisplaywidth(line:sub(1, bp.start)) + 1
  local finish_vcol = vim.fn.strdisplaywidth(line:sub(1, bp.finish + 1))
  local wininfo = vim.fn.getwininfo(win)[1]
  if not wininfo then return end
  local textwidth = wininfo.width - wininfo.textoff
  local vw = vim.fn.winsaveview()
  -- +2: the trailing " ║" / " │ " border sits 2 display columns past the cell data
  local new_leftcol = M._reveal_leftcol(vw.leftcol, textwidth, start_vcol, finish_vcol, 2)
  if new_leftcol then
    vw.leftcol = new_leftcol
    vim.fn.winrestview(vw)
  end
end

-- ── winbar: sticky header + badges ───────────────────────────────────────
-- One writer for 'winbar'. The watch/write badges came first and keep the
-- right edge; the sticky column header (view/sticky_header.lua) fills the rest.

--- Rebuild the winbar for bufnr: sticky column header plus watch/write badges.
function M._update_winbar(bufnr)
  local session = M._sessions[bufnr]
  if not session then return end
  -- Find the window showing this buffer
  local winid
  for _, wid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(wid) == bufnr then winid = wid; break end
  end
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end

  local badges = {}
  -- The mode of the session's own connection, not the ambient one: a grid
  -- outliving a :GripConnect must still say what it is connected to. Cached
  -- on the session because this function runs on every CursorMoved while
  -- current_mode() reads connections.json. Two things clear the cache, and
  -- between them they cover everything that can change the answer:
  -- M.render (requery, refresh) and M.invalidate_mode_cache,
  -- which connections.switch calls.
  if session._ro_mode == nil then
    session._ro_mode =
      require("dadbod-grip.connections").current_mode(session.url) == "ro"
  end
  if session._ro_mode then
    table.insert(badges, { text = "RO", hl = "GripReadonly" })
  end
  if session.watch_ms then
    local secs = session.watch_ms / 1000
    local label = secs == math.floor(secs) and tostring(math.floor(secs)) .. "s" or tostring(secs) .. "s"
    table.insert(badges, { text = "↺ " .. label, hl = "GripWatch" })
  end
  if session.write_mode then
    table.insert(badges, { text = "✎ WRITE", hl = "ErrorMsg" })
  end

  local sticky = require("dadbod-grip.config").values.sticky_header ~= false
  local view_state = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
  -- Buffer line 2 IS the column-name row. While it is still on screen the winbar
  -- would only show it a second time, so it goes blank instead of duplicating —
  -- blank rather than unset, because unsetting drops the line and shifts the
  -- whole grid by one row exactly when scrolling crosses this threshold.
  --
  -- The "does the whole grid fit" test is not redundant with the topline one: on
  -- Neovim 0.10 a window that has not been drawn yet reports topline == the
  -- cursor line (verified against v0.10.0, the CI baseline), which reads as
  -- "scrolled" for a grid that cannot scroll at all. A buffer shorter than the
  -- window always shows its header, whatever topline claims.
  local fits_in_window =
    vim.api.nvim_buf_line_count(bufnr) <= vim.api.nvim_win_get_height(winid)
  local hdr_on_screen = fits_in_window or (view_state.topline or 1) <= 2
  local hdr_line = sticky and not hdr_on_screen and session._render
    and session._render.lines and session._render.lines[2] or nil
  local bar
  if hdr_line then
    local wininfo = vim.fn.getwininfo(winid)[1]
    -- A winbar spans the full window width, but the buffer text starts after the
    -- gutter ('number', 'signcolumn', folds). textoff is that gutter: it comes
    -- off the width AND goes back on as a leading indent, or the mirrored header
    -- renders one gutter to the left of the columns it is labelling.
    local textoff = wininfo and wininfo.textoff or 0
    local width = wininfo and (wininfo.width - textoff) or 0
    bar = require("dadbod-grip.view.sticky_header").build(
      hdr_line, view_state.leftcol or 0, width,
      M._active_col_bp(bufnr, winid), badges, textoff)
  else
    local parts = {}
    for _, b in ipairs(badges) do
      table.insert(parts, "%#" .. b.hl .. "#" .. b.text .. "%#Normal#")
    end
    bar = #parts > 0 and ("  " .. table.concat(parts, "  ")) or ""
    -- Hold the line open while the feature is on, so it neither appears nor
    -- disappears as the header scrolls in and out of view.
    if bar == "" and sticky then bar = " " end
  end
  pcall(function() vim.wo[winid].winbar = bar end)
end

--- Drop every session's cached connection mode and redraw the winbars.
---
--- connections.switch() calls this: a switch changes what current_mode()
--- answers, for the connection being switched to and for any connection whose
--- session override it just cleared. The grid in the current window is
--- replaced by the welcome screen and takes its session with it, but a grid in
--- any other window survives -- the sidebar and the query pad both hold focus
--- at switch time, and a pinned grid is skipped by find_content_win() -- and
--- would otherwise keep rendering its stale badge off the cache until its next
--- requery. A badge that says RO on a writable connection is worse than none.
function M.invalidate_mode_cache()
  for bufnr, session in pairs(M._sessions) do
    session._ro_mode = nil
    if vim.api.nvim_buf_is_valid(bufnr) then M._update_winbar(bufnr) end
  end
end

--- Start a watch timer for bufnr at interval ms. Stops any existing timer.
local function _start_watch(bufnr, ms)
  local session = M._sessions[bufnr]
  if not session then return end
  -- Stop existing timer if any
  if session.watch_timer then
    pcall(function() session.watch_timer:stop(); session.watch_timer:close() end)
    session.watch_timer = nil
  end
  session.watch_ms = ms
  local timer = vim.uv.new_timer()
  session.watch_timer = timer
  timer:start(ms, ms, vim.schedule_wrap(function()
    local s = M._sessions[bufnr]
    if not s or not vim.api.nvim_buf_is_valid(bufnr) then
      pcall(function() timer:stop(); timer:close() end)
      return
    end
    -- Skip refresh when there are staged mutations pending
    local staged = s.state and (
      next(s.state.changes or {}) or
      next(s.state.deleted or {}) or
      next(s.state.inserted or {})
    )
    if staged then return end
    if s.on_refresh then s.on_refresh(bufnr) end
  end))
  M._update_winbar(bufnr)
end

--- Stop the watch timer for bufnr.
local function _stop_watch(bufnr)
  local session = M._sessions[bufnr]
  if not session then return end
  if session.watch_timer then
    pcall(function() session.watch_timer:stop(); session.watch_timer:close() end)
    session.watch_timer = nil
  end
  session.watch_ms = nil
  M._update_winbar(bufnr)
end

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
  pcall(vim.api.nvim_win_set_cursor, winid, { 4, #("║ ") })
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
      if opts.watch_ms then _start_watch(bufnr, opts.watch_ms) end
      M._update_winbar(bufnr)
    end)
  end

  return bufnr
end

-- ── JSON pretty-printer ──────────────────────────────────────────────────
-- Converts a decoded Lua value (from vim.fn.json_decode) into an indented
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

-- ── focused info float helper ────────────────────────────────────────────
-- Opens a focused float with q/Esc to close. Caller stays in grip buffer.
local function open_info_float(grip_win, lines, float_opts)
  -- nvim_buf_set_lines requires each element to contain no \n.
  -- Flatten any multi-line strings (e.g. cell values with embedded newlines).
  local flat = {}
  for _, l in ipairs(lines) do
    for _, sub in ipairs(vim.split(tostring(l), "\n", { plain = true })) do
      table.insert(flat, sub)
    end
  end

  local max_w = 0
  for _, l in ipairs(flat) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end

  local width = float_opts.width or math.min(math.max(max_w + 2, 30), 80)
  local height = float_opts.height or math.min(#flat, 30)
  local relative = float_opts.relative or "editor"

  -- Editor-relative floats are centered by ui.info_float (row/col left nil).
  local row, col
  if relative == "cursor" then
    row = float_opts.row or 1
    col = float_opts.col or 0
  end

  -- Buffer is created here, not by info_float: filetype must be set before the
  -- window exists so FileType autocmds see the same state as before.
  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, flat)
  if float_opts.filetype then
    vim.api.nvim_set_option_value("filetype", float_opts.filetype, { buf = popup_buf })
  end

  local win = ui.info_float({
    buf = popup_buf,
    relative = relative,
    row = row,
    col = col,
    width = width,
    height = height,
    title = float_opts.title or "",
    title_pos = "center",
    zindex = 50,
  })

  ui.dismiss_float({ win = win, buf = popup_buf, caller_win = grip_win, group = _ag })

  return win, popup_buf
end

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

--- Resolve the byte-position map for any grid line, including the header and
--- the type-annotation row. Returns nil for lines past the rendered rows
--- unless `fallback` asks for the first data row (then the header) instead.
--- @param r table    session._render
--- @param line number  1-indexed buffer line
--- @param fallback? boolean
--- @return table|nil  map of column name -> { start, finish } byte offsets
local function resolve_row_bp(r, line, fallback)
  local ds = r.data_start or 4
  local di = line - ds + 1
  if di < 1 then
    if ds == 5 and line == ds - 2 then return r.type_row_byte_positions end
    return r.hdr_byte_positions
  end
  local bp = r.byte_positions and r.byte_positions[di]
  if bp then return bp end
  if fallback then
    return (r.byte_positions and r.byte_positions[1]) or r.hdr_byte_positions
  end
  return nil
end

--- Name of the column at (line, col_nr), resolved from whichever row the cursor
--- is on: a data row, the header, or the type-annotation row.
--- Always go through this rather than pairing _snap_col with hdr_byte_positions
--- by hand. The rows do not share byte offsets -- a type name truncated with "…"
--- spends 3 bytes on 1 display cell, so every column after it sits elsewhere in
--- the type row than in the header -- and four call sites open-coded that pairing
--- with three of them reading the header unconditionally, which resolved the
--- wrong column whenever the cursor was on the type row.
--- @return string|nil  column name, or nil without render state or columns
function M._resolve_col_at(r, cols, line, col_nr)
  if not r or not cols or #cols == 0 then return nil end
  local ref_bp = resolve_row_bp(r, line, true)
  if not ref_bp then return nil end
  local snap = M._snap_col(cols, ref_bp, col_nr)
  return snap and snap.col_name or nil
end

--- Byte range of the cursor's column inside the header row, for the sticky
--- header to highlight. Defined here rather than next to M._update_winbar
--- because it needs resolve_row_bp, which is declared above.
--- @return table|nil  { start, finish } from hdr_byte_positions
function M._active_col_bp(bufnr, winid)
  local session = M._sessions[bufnr]
  local r = session and session._render
  if not r or not r.hdr_byte_positions then return nil end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
  if not ok then return nil end
  -- fallback: on the border/footer lines, keep labelling the column the cursor
  -- column falls in rather than dropping the highlight entirely.
  local ref_bp = resolve_row_bp(r, cursor[1], true)
  local snap = ref_bp and M._snap_col(r.visible_columns or {}, ref_bp, cursor[2]) or nil
  return snap and r.hdr_byte_positions[snap.col_name] or nil
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
  ctx.open_info_float = open_info_float
  ctx.resolve_row_bp  = resolve_row_bp
  ctx.reveal_col_edge = reveal_col_edge
  ctx.update_winbar   = M._update_winbar
  ctx.start_watch     = _start_watch
  ctx.stop_watch      = _stop_watch
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
    local ds = r.data_start or 4
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
