-- view/cells.lua: map the cursor to a grid cell, and back from a cell's byte
-- span to the screen (horizontal reveal). Works on session._render, the
-- layout build_render records: data_start, ordered rows and byte positions.

local data = require("dadbod-grip.data")

local M = {}

local function view() return require("dadbod-grip.view") end

-- ── cursor → cell mapping ─────────────────────────────────────────────────
-- M.get_cell(bufnr) → {row_idx, col_name, col_idx, value} | nil
function M.get_cell(bufnr)
  local session = view()._sessions[bufnr]
  if not session or not session._render then return nil end

  local r = session._render
  local st = session.state
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_nr = cursor[1]  -- 1-based
  local col_nr  = cursor[2]  -- 0-based byte offset

  -- Data rows start at line 4 (title, header, sep) or 5 (with type row)
  local data_start = r.data_start or 5
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
--- The hint/title/header/type/separator rows sit above this range and the
--- footer sits below it; visual-mode navigation reuses this so `G`/`j`/`k` stop at the
--- last data row instead of overshooting onto the footer (issue #20). Pure/testable.
function M._clamp_data_line(r, line)
  local ds = r.data_start or 5
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
function M.reveal_col_edge(win, buf, lnum, bp)
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

--- Resolve the byte-position map for any grid line, including the header and
--- the type-annotation row. Returns nil for lines past the rendered rows
--- unless `fallback` asks for the first data row (then the header) instead.
--- @param r table    session._render
--- @param line number  1-indexed buffer line
--- @param fallback? boolean
--- @return table|nil  map of column name -> { start, finish } byte offsets
function M.resolve_row_bp(r, line, fallback)
  local ds = r.data_start or 5
  local di = line - ds + 1
  if di < 1 then
    if r.type_row and line == r.type_row then return r.type_row_byte_positions end
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
  local ref_bp = M.resolve_row_bp(r, line, true)
  if not ref_bp then return nil end
  local snap = M._snap_col(cols, ref_bp, col_nr)
  return snap and snap.col_name or nil
end

--- Byte range of the cursor's column inside the header row, for the sticky
--- header to highlight.
--- @return table|nil  { start, finish } from hdr_byte_positions
function M._active_col_bp(bufnr, winid)
  local session = view()._sessions[bufnr]
  local r = session and session._render
  if not r or not r.hdr_byte_positions then return nil end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
  if not ok then return nil end
  -- fallback: on the border/footer lines, keep labelling the column the cursor
  -- column falls in rather than dropping the highlight entirely.
  local ref_bp = M.resolve_row_bp(r, cursor[1], true)
  local snap = ref_bp and M._snap_col(r.visible_columns or {}, ref_bp, cursor[2]) or nil
  return snap and r.hdr_byte_positions[snap.col_name] or nil
end

return M
