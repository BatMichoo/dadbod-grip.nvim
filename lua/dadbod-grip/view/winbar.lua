-- view/winbar.lua: the grid window's winbar, its single writer.

local M = {}

local function view() return require("dadbod-grip.view") end

-- ── winbar: sticky header + badges ───────────────────────────────────────
-- One writer for 'winbar'. The watch/write badges came first and keep the
-- right edge; the sticky column header (view/sticky_header.lua) fills the rest.

--- Rebuild the winbar for bufnr: sticky column header plus watch/write badges.
function M._update_winbar(bufnr)
  local session = view()._sessions[bufnr]
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
  -- Buffer line hdr_row (under the hint line and the title) IS the column-name
  -- row. While it is still on screen the winbar would only show it a second
  -- time, so it goes blank instead of duplicating —
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
  local hdr_row = session._render and session._render.hdr_row or 3
  local hdr_on_screen = fits_in_window or (view_state.topline or 1) <= hdr_row
  local hdr_line = sticky and not hdr_on_screen and session._render
    and session._render.lines and session._render.lines[hdr_row] or nil
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
      require("dadbod-grip.view.cells")._active_col_bp(bufnr, winid), badges, textoff)
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
  for bufnr, session in pairs(view()._sessions) do
    session._ro_mode = nil
    if vim.api.nvim_buf_is_valid(bufnr) then M._update_winbar(bufnr) end
  end
end

return M
