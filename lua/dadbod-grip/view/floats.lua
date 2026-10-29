-- view/floats.lua: the floating windows a grid opens: the Live SQL preview,
-- the focused info float (q/Esc to close), and closing them all.

local data = require("dadbod-grip.data")
local sql  = require("dadbod-grip.sql")
local ui   = require("dadbod-grip.ui")

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripFloats", { clear = true })

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
      noautocmd = true,
    })
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

-- ── focused info float helper ────────────────────────────────────────────
-- Opens a focused float with q/Esc to close. Caller stays in grip buffer.
function M.open_info_float(grip_win, lines, float_opts)
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

return M
