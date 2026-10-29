-- view/column_highlight.lua: Cursor-column highlight autocmd.
-- Called by view._setup_keymaps(). Everything it needs from view.lua
-- arrives through ctx, so this module never requires view.

local M = {}

--- Highlight the column under the cursor, header row included. Keyed on the
--- _render table so a redraw invalidates the cache by itself.
function M.setup(bufnr, ctx)
  local view = ctx.view
  local resolve_row_bp = ctx.resolve_row_bp
  local augroup = ctx.augroup
  local col_hl_ns = ctx.col_hl_ns
  -- Lifted out of the callback below: the autocmd lives as long as the buffer
  -- does, and capturing ctx would keep the whole helper set alive with it when
  -- the accessor is the only part of it this module ever reaches for.
  local get_session = ctx.session

  vim.api.nvim_create_autocmd("CursorMoved", {
    group  = augroup,
    buffer = bufnr,
    callback = function()
      local session = get_session()
      if not session or not session._render then return end
      local r = session._render
      local vis_cols = r.visible_columns or (session.state and session.state.columns) or {}
      if #vis_cols == 0 then return end

      local cursor = vim.api.nvim_win_get_cursor(0)
      local ref_bp = resolve_row_bp(r, cursor[1])
      local snap = ref_bp and view._snap_col(vis_cols, ref_bp, cursor[2]) or nil
      local col_name = snap and snap.col_name or nil

      -- Nothing to redo while the cursor stays in the same column: j/k on a
      -- 1000-row page used to clear the namespace and re-set 1001 extmarks on
      -- every keypress. Keyed on the _render table, which render() replaces
      -- wholesale, so a redraw invalidates this cache by itself.
      local cached = session._col_hl
      if cached and cached.render == r and cached.col == col_name then return end
      session._col_hl = { render = r, col = col_name }

      vim.api.nvim_buf_clear_namespace(bufnr, col_hl_ns, 0, -1)
      if not col_name then return end

      -- Highlight header row (line 2 = index 1)
      local hdr_bp = r.hdr_byte_positions and r.hdr_byte_positions[col_name]
      if hdr_bp then
        vim.api.nvim_buf_set_extmark(bufnr, col_hl_ns, 1, hdr_bp.start, {
          end_col = hdr_bp.finish + 1,
          hl_group = "GripColHighlight",
          priority = 50,
        })
      end

      -- Highlight all data rows
      local ds = r.data_start or 4
      local ordered = r.ordered or {}
      for i = 1, #ordered do
        local bp_row = r.byte_positions and r.byte_positions[i]
        if bp_row then
          local bp = bp_row[col_name]
          if bp then
            vim.api.nvim_buf_set_extmark(bufnr, col_hl_ns, ds + i - 2, bp.start, {
              end_col = bp.finish + 1,
              hl_group = "GripColHighlight",
              priority = 50,
            })
          end
        end
      end
    end,
  })
end

return M
