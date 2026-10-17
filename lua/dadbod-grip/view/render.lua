-- view/render.lua: turns a grid session into buffer lines and highlight
-- extmarks. Pure layout: no buffer or window is touched here.

local data      = require("dadbod-grip.data")
local ui        = require("dadbod-grip.ui")
local filetypes = require("dadbod-grip.filetypes")
local qmod      = require("dadbod-grip.query")

local M = {}

-- ── profiling (set GRIP_PROFILE=1 to enable) ───────────────────────────────
local PROFILE = os.getenv("GRIP_PROFILE")
local function profile(name, fn)
  if not PROFILE then return fn() end
  local start = vim.uv.hrtime()
  local result = fn()
  local elapsed = (vim.uv.hrtime() - start) / 1e6
  print(string.format("[grip] %s: %.1fms", name, elapsed))
  return result
end
M.profile = profile

-- ── constants ──────────────────────────────────────────────────────────────
local NULL_DISPLAY  = "·NULL·"
local BINARY_PREFIX = "<binary"
local MAX_COL_WIDTH = 40  -- overridden by setup opts

-- 1=sidebar/connections  2=query-pad/history  3=grid/table-picker
-- 4=ER diagram  5=stats  6=columns  7=fk  8=indexes  9=constraints
local VIEW_KEYS = require("dadbod-grip.keymaps").TAB_VIEWS
local VIEW_LABELS = require("dadbod-grip.view.meta_views").LABELS

local SEP_COL = "│"
local SEP_HDR = "═"
local SEP_MID = "╪"
local MID_L   = "╠"
local MID_R   = "╣"
local BOT_L   = "╚"
local BOT_R   = "╝"
local BOT_MID = "╧"

-- ── column width calculation ──────────────────────────────────────────────
-- truncate_display/pad_display live in ui.lua so properties.lua, profile.lua,
-- diff.lua and er_diagram.lua share one display-width truncation/padding
-- instead of each rolling byte-length arithmetic. The ASCII fast path and the
-- note on 'ambiwidth' moved there with the code they explain.
local truncate_display = ui.truncate_display
local pad_display = ui.pad_display

-- Returns two tables keyed by column name:
--   widths  — display width clamped to max_width (what the grid actually renders)
--   natural — true (unclamped) content width, used to cap slack expansion so a
--             column is never padded wider than the data it holds
local function calc_col_widths(columns, rows, max_width)
  local widths = {}
  local natural = {}
  for _, col in ipairs(columns) do
    -- +3 reserves space for stacked sort indicators (e.g. " ▲1") so the col name is never truncated
    local w = vim.fn.strdisplaywidth(col) + 3
    natural[col] = w
    widths[col] = math.min(w, max_width)
  end
  -- For large tables, sample first 100 + last 10 rows instead of scanning all
  local n = #rows
  local sample_end = n > 200 and 100 or n
  local function scan_row(row_data)
    for i, col in ipairs(columns) do
      local v = row_data[i] or ""
      local display = (v == nil or v == "") and NULL_DISPLAY or tostring(v)
      local dw = vim.fn.strdisplaywidth(display)
      if dw > natural[col] then natural[col] = dw end
      widths[col] = math.min(math.max(widths[col], dw), max_width)
    end
  end
  for ri = 1, sample_end do scan_row(rows[ri]) end
  if n > 200 then
    for ri = math.max(sample_end + 1, n - 9), n do scan_row(rows[ri]) end
  end
  return widths, natural
end

--- Hand leftover horizontal space to truncated columns so a narrow table fills
--- the window — but never widen a column past its true content (`natural`),
--- otherwise hiding columns just pads the survivors with dead space. Each column
--- grows by at most `per_col_cap`. Layout reserves +3 per column (separators /
--- sort markers). Mutates and returns `widths`. Pure/testable.
function M._distribute_slack(columns, widths, natural, configured_max, available, per_col_cap)
  local total = 0
  for _, col in ipairs(columns) do total = total + widths[col] + 3 end
  local slack = available - total
  if slack <= 0 then return widths end
  for _, col in ipairs(columns) do
    if slack <= 0 then break end
    if widths[col] >= configured_max then           -- column was truncated at the cap
      local room = math.min(natural[col] - widths[col], per_col_cap)
      if room > 0 then
        local extra = math.min(slack, room)
        widths[col] = widths[col] + extra
        slack = slack - extra
      end
    end
  end
  return widths
end

-- ── cell display formatting ───────────────────────────────────────────────
local function format_cell(value, width, is_null_staged)
  if is_null_staged or value == nil then
    local s = pad_display(NULL_DISPLAY, width)
    return s, "GripNull"
  end
  value = tostring(value)
  if value:sub(1, #BINARY_PREFIX) == BINARY_PREFIX then
    local s = pad_display(value, width, false)
    return s, "GripReadonly"
  end
  local display = value ~= "" and value:gsub("\n", "↵"):gsub("\r", "") or NULL_DISPLAY
  local hl = value == "" and "GripNull" or nil
  return pad_display(display, width), hl
end

--- Classify a cell value for conditional formatting.
--- Returns hl_group string or nil. Only for clean, non-null cells.
local function classify_cell(value, data_type)
  if value == nil or value == "" then return nil end
  local val_lower = value:lower()

  -- Boolean detection
  if data_type then
    local dt = data_type:lower()
    if dt:match("bool") or dt:match("tinyint%(1%)") then
      if val_lower == "t" or val_lower == "true" or val_lower == "1" or val_lower == "yes" then
        return "GripBoolTrue"
      elseif val_lower == "f" or val_lower == "false" or val_lower == "0" or val_lower == "no" then
        return "GripBoolFalse"
      end
    end
  end
  -- Detect explicit true/false without type info
  if val_lower == "true" or val_lower == "t" then return "GripBoolTrue" end
  if val_lower == "false" or val_lower == "f" then return "GripBoolFalse" end

  -- Negative numbers
  local num = tonumber(value)
  if num and num < 0 then return "GripNegative" end

  -- URLs and emails
  if value:match("^https?://") or value:match("^[%w%.%-]+@[%w%.%-]+%.[%w]+$") then
    return "GripUrl"
  end

  -- Dates in the past (requires data_type)
  if data_type then
    local dt = data_type:lower()
    if dt:match("date") or dt:match("timestamp") then
      local y, m, d = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
      if y then
        local date_str = string.format("%04d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d))
        if date_str < os.date("%Y-%m-%d") then
          return "GripDatePast"
        end
      end
    end
  end

  return nil
end

-- ── border line builders ──────────────────────────────────────────────────
local function border_line(columns, widths, left, mid, sep, right, min_inner)
  local parts = { left }
  if #columns == 0 and min_inner and min_inner > 0 then
    table.insert(parts, string.rep(sep, min_inner))
  else
    for i, col in ipairs(columns) do
      table.insert(parts, string.rep(sep, widths[col] + 2))
      if i < #columns then
        table.insert(parts, mid)
      end
    end
  end
  table.insert(parts, right)
  return table.concat(parts)
end

-- Returns true when the grid allows editing: either a table with detected
-- primary keys, or a local file in write mode (CSV, parquet, etc.).
local function is_editable(session)
  if not session or not session.state then return false end
  if not session.state.readonly then return true end
  return session.write_mode == true
    and filetypes.write_format(session.file_path) ~= nil
end

-- Build the title bar with connection/table info and staged count.
local function title_line(session, columns, widths, total_width)
  local staged = data.count_staged(session.state)
  local badges = {}
  if staged > 0 then table.insert(badges, staged .. " staged") end
  -- Metadata views: show view name as badge; suppress "read-only: no PK" noise
  if session.current_view and session.current_view ~= "records" then
    local vn = session.current_view
    local full_labels = {
      columns="Columns", fk="Foreign Keys", indexes="Indexes",
      constraints="Constraints", stats="Column Stats", history="History", explain="Explain",
    }
    table.insert(badges, full_labels[vn] or vn)
  elseif not is_editable(session) then
    table.insert(badges, session.state.readonly_badge or "read-only: no PK")
  end
  if session.query_spec and qmod.has_filters(session.query_spec) then
    table.insert(badges, "filtered")
  end
  local hidden_count = 0
  if session.hidden_columns then
    for _ in pairs(session.hidden_columns) do hidden_count = hidden_count + 1 end
  end
  if hidden_count > 0 then table.insert(badges, hidden_count .. " hidden") end
  local right_info = #badges > 0 and (" [" .. table.concat(badges, " | ") .. "] ") or " "

  -- Build title with connection name and breadcrumb for FK navigation
  local conn_label
  local conn_mod = require("dadbod-grip.connections")
  local conn_info = conn_mod.current()
  if conn_info and conn_info.name then
    conn_label = conn_info.name
  elseif session.url then
    conn_label = session.url:match("([^/]+)$") or session.url
  end
  local base_name = session._mutation_title
    or session.state.table_name
    or "(query result)"
  if session.nav_stack and #session.nav_stack > 0 then
    local crumbs = {}
    for _, frame in ipairs(session.nav_stack) do
      table.insert(crumbs, frame.table_name or "?")
    end
    table.insert(crumbs, base_name)
    base_name = table.concat(crumbs, " > ")
  end

  -- Progressive fit: try full title, then drop connection, then truncate
  local inner = total_width - 4  -- ╔═(2) + ═╗(2) = 4 border display cols
  local right_trimmed = right_info:gsub(" $", "")
  local right_dw = vim.fn.strdisplaywidth(right_trimmed)
  local available = inner - right_dw

  -- If badges alone overflow, drop them
  if available < 6 then
    right_trimmed = ""
    right_dw = 0
    available = inner
  end

  -- Try: table @ connection
  local title_text = base_name
  if conn_label and conn_label ~= "" then
    title_text = base_name .. " @ " .. conn_label
  end
  local title = " " .. title_text .. " "
  local title_dw = vim.fn.strdisplaywidth(title)

  -- If too wide, drop connection name
  if title_dw > available and conn_label then
    title = " " .. base_name .. " "
    title_dw = vim.fn.strdisplaywidth(title)
  end

  -- If still too wide, truncate
  if title_dw > available and available > 4 then
    title = truncate_display(title, available)
    title_dw = vim.fn.strdisplaywidth(title)
  end

  -- If still too wide (e.g. available <= 4: very narrow grid), show gH hint if it fits
  if title_dw > available then
    if inner >= 4 then
      title = " gH "
      title_dw = 4
    else
      title = ""
      title_dw = 0
    end
    right_trimmed = ""
    right_dw = 0
  end

  local filler = math.max(0, inner - title_dw - right_dw)
  return "╔═" .. title .. string.rep("═", filler) .. right_trimmed .. "═╗"
end

-- ── main render ──────────────────────────────────────────────────────────
-- Returns {lines=[], extmarks=[{row, col, end_col, hl_group}]}
local function build_render(session, opts)
  local configured_max = (opts and opts.max_col_width) or MAX_COL_WIDTH
  local st = session.state
  local hidden = session.hidden_columns or {}
  local columns = {}
  for _, col in ipairs(st.columns) do
    if not hidden[col] then table.insert(columns, col) end
  end
  if #columns == 0 then columns = st.columns end  -- never hide all
  local ordered = data.get_ordered_rows(st)

  -- Build data type map for conditional formatting
  local cond_type_map = {}
  if session._column_info then
    for _, ci in ipairs(session._column_info) do
      cond_type_map[ci.column_name] = ci.data_type
    end
  end

  -- Resolve every cell's effective value exactly once. `effs` keeps the raw
  -- value (nil = NULL, which the render loop and the highlight loop both need
  -- to distinguish from ""), `display_rows` is the string view that
  -- calc_col_widths consumes. Both are indexed by column position, so nil
  -- holes in `effs` are fine — nothing iterates them with ipairs/#.
  local effs = {}
  local display_rows = {}
  for di, row_idx in ipairs(ordered) do
    local er, dr = {}, {}
    for i, col in ipairs(columns) do
      local eff = data.effective_value(st, row_idx, col)
      er[i] = eff
      dr[i] = eff or ""
    end
    effs[di] = er
    display_rows[di] = dr
  end

  -- Auto-fit: compute natural widths first (clamped to configured max);
  -- `natural_widths` keeps the true unclamped content width for slack capping.
  local widths, natural_widths = calc_col_widths(columns, display_rows, configured_max)

  -- Apply per-column width overrides (set by = keymap)
  if session.col_width_overrides then
    for col, override_w in pairs(session.col_width_overrides) do
      if widths[col] ~= nil then widths[col] = override_w end
    end
  end

  -- Smart auto-fit: if the table is narrower than the window, hand the leftover
  -- space to truncated columns — but never past their real content width, so
  -- hiding columns doesn't balloon the survivors with empty padding.
  if #columns > 0 then
    local available = vim.o.columns - 4  -- borders + padding
    M._distribute_slack(columns, widths, natural_widths, configured_max, available, 20)
  end

  -- Total visual width of content area
  local total_inner = 0
  for _, col in ipairs(columns) do total_inner = total_inner + widths[col] + 3 end
  if #columns > 0 then total_inner = total_inner - 1 end  -- no trailing sep
  -- For tables with 0 columns, use a minimum width for the "(empty result)" message
  if #columns == 0 then total_inner = math.max(total_inner, 20) end
  local total_width = total_inner + 2  -- + borders

  local lines = {}
  local marks = {}  -- {line_idx (1-based), byte_start, byte_end, hl}

  local function push_mark(line_idx, byte_start, byte_end, hl)
    table.insert(marks, { line = line_idx - 1, col = byte_start, end_col = byte_end, hl = hl })
  end

  -- ── Title row ──
  local title = title_line(session, columns, widths, total_width)
  table.insert(lines, title)
  push_mark(#lines, 0, #title, "GripBorder")

  -- ── Header row ──
  local hdr_parts = { "║" }
  local qspec = session.query_spec
  -- Computed during assembly using #padded (byte length), not widths[col] (display width).
  -- Sort arrows (▲/▼ = 3 bytes, 1 display char) and ellipsis (… = 3 bytes) diverge from display
  -- widths; using display widths causes cursor positions to drift by 2 bytes per UTF-8 char.
  local hdr_byte_positions = {}
  if #columns == 0 then
    table.insert(hdr_parts, string.rep(" ", total_inner))
  else
    table.insert(hdr_parts, " ")
    local hbp = 4  -- "║ " = 3 + 1 bytes
    for i, col in ipairs(columns) do
      local is_ro = st.readonly and not is_editable(session)
      local prefix = is_ro and "~" or ""
      local sort_ind = qspec and qmod.get_sort_indicator(qspec, col) or nil
      local suffix = sort_ind and " " .. sort_ind or ""
      local label = prefix .. col .. suffix
      local w = widths[col]
      local lw = vim.fn.strdisplaywidth(label)
      if lw > w then
        label, lw = truncate_display(label, w)
      end
      local padded = label .. string.rep(" ", w - lw)
      hdr_byte_positions[col] = { start = hbp, finish = hbp + #padded - 1 }
      hbp = hbp + #padded
      table.insert(hdr_parts, padded)
      if i < #columns then
        local col_sep = " " .. SEP_COL .. " "
        table.insert(hdr_parts, col_sep)
        hbp = hbp + #col_sep
      end
    end
    table.insert(hdr_parts, " ")
  end
  table.insert(hdr_parts, "║")
  local hdr_line = table.concat(hdr_parts)
  table.insert(lines, hdr_line)
  push_mark(#lines, 0, #hdr_line, "GripHeader")

  -- ── Type annotation row (T toggle) ──
  local has_type_row = false
  local type_row_byte_positions = nil
  if session.show_types and session._column_info then
    local type_map = {}
    for _, ci in ipairs(session._column_info) do
      type_map[ci.column_name] = ci.data_type
    end
    local type_parts = { "║ " }
    -- Track byte positions separately: "║ " = 4 bytes (3+1), then each cell's ACTUAL byte width.
    -- Type names truncated with "…" (3 bytes, 1 display char) diverge from hdr_byte_positions.
    type_row_byte_positions = {}
    local tbp = 4  -- after "║ "
    for i, col in ipairs(columns) do
      local dtype = type_map[col] or ""
      local w = widths[col]
      local dw = vim.fn.strdisplaywidth(dtype)
      if dw > w then
        dtype, dw = truncate_display(dtype, w)
      end
      local padded = dtype .. string.rep(" ", w - dw)
      type_row_byte_positions[col] = { start = tbp, finish = tbp + #padded - 1 }
      tbp = tbp + #padded
      table.insert(type_parts, padded)
      if i < #columns then
        local col_sep = " " .. SEP_COL .. " "
        table.insert(type_parts, col_sep)
        tbp = tbp + #col_sep
      end
    end
    table.insert(type_parts, " ║")
    local type_line = table.concat(type_parts)
    table.insert(lines, type_line)
    push_mark(#lines, 0, #type_line, "GripNull")
    has_type_row = true
  end

  -- ── Separator after header ──
  local sep_line = border_line(columns, widths, MID_L, SEP_MID, SEP_HDR, MID_R, total_inner)
  table.insert(lines, sep_line)
  push_mark(#lines, 0, #sep_line, "GripBorder")

  -- Byte-length constants for UTF-8 box-drawing chars (║=3 bytes, │=3 bytes)
  local ROW_PREFIX = "║ "
  local ROW_PREFIX_BYTES = #ROW_PREFIX  -- 4 bytes (3+1)
  local COL_SEP = " " .. SEP_COL .. " "
  local row_byte_positions = {}  -- [row_order_idx] = {col_name = {start, finish}}


  -- ── Data rows ──
  if #ordered == 0 then
    local msg_s = total_inner >= 16 and " (empty result) " or total_inner >= 9 and " (empty) " or ""
    if #msg_s > total_inner then msg_s = "" end
    local pad_total = total_inner - #msg_s
    local pad_left = math.floor(pad_total / 2)
    local pad_right = pad_total - pad_left
    local empty_line = "║" .. string.rep(" ", pad_left) .. msg_s .. string.rep(" ", pad_right) .. "║"
    table.insert(lines, empty_line)
  else
    for di, row_idx in ipairs(ordered) do
      local status = data.row_status(st, row_idx)
      local row_effs = effs[di]
      local row_parts = { ROW_PREFIX }
      local line_byte_positions = {}  -- {col_name = {start, finish}}
      local byte_pos = ROW_PREFIX_BYTES  -- after "║ " (4 bytes, not 2)

      for i, col in ipairs(columns) do
        local eff = row_effs[i]
        local w = widths[col]
        -- format_cell also returns a highlight group, but the authoritative
        -- one is computed in the highlight pass below; ignore it here.
        local cell_str = format_cell(eff, w, eff == nil)

        line_byte_positions[col] = { start = byte_pos, finish = byte_pos + #cell_str - 1 }

        table.insert(row_parts, cell_str)
        byte_pos = byte_pos + #cell_str

        if i < #columns then
          local sep = COL_SEP
          table.insert(row_parts, sep)
          byte_pos = byte_pos + #sep  -- same byte width (5) for both separators
        end
      end

      row_byte_positions[di] = line_byte_positions

      table.insert(row_parts, " ║")
      local row_line = table.concat(row_parts)
      table.insert(lines, row_line)

      local li = #lines
      -- Apply per-cell highlights
      for i, col in ipairs(columns) do
        local bp = line_byte_positions[col]
        if bp then
          local eff = row_effs[i]
          local cell_hl
          if status == "deleted" then
            cell_hl = "GripDeleted"
          elseif status == "inserted" then
            cell_hl = "GripInserted"
          elseif status == "modified" and st.changes[row_idx] and st.changes[row_idx][col] ~= nil then
            -- NULL_SENTINEL = staged to be cleared → red fg (value absent) on blue bg (modified)
            if st.changes[row_idx][col] == data.NULL_SENTINEL then
              cell_hl = "GripNullStaged"
            else
              cell_hl = "GripModified"
            end
          elseif eff == nil or eff == "" then
            cell_hl = "GripNull"
          else
            cell_hl = classify_cell(eff, cond_type_map[col])
          end
          if cell_hl then
            push_mark(li, bp.start, bp.finish + 1, cell_hl)
          end
        end
      end
    end
  end

  -- ── Bottom border ──
  local bot_line = border_line(columns, widths, BOT_L, BOT_MID, SEP_HDR, BOT_R, total_inner)
  table.insert(lines, bot_line)
  push_mark(#lines, 0, #bot_line, "GripBorder")

  -- ── Status line ──
  local staged_count = data.count_staged(st)
  local status_parts = {}

  -- Row count, and the cap when Grip's own TOP N may have cut the result short
  local row_str = #st.rows .. " rows"
  local cap = session.query_spec and session.query_spec.limit
  if cap and #st.rows >= cap then row_str = row_str .. " (TOP " .. cap .. ")" end
  table.insert(status_parts, row_str)

  local timing_str
  if session.elapsed_ms then
    local action = session.last_action or "query"
    timing_str = session.elapsed_ms .. "ms " .. action
    table.insert(status_parts, timing_str)
  end
  if staged_count > 0 then table.insert(status_parts, staged_count .. " staged") end
  if st.readonly and not is_editable(session) then table.insert(status_parts, "read-only") end
  local hidden_n = 0
  if session.hidden_columns then
    for _ in pairs(session.hidden_columns) do hidden_n = hidden_n + 1 end
  end
  if hidden_n > 0 then table.insert(status_parts, hidden_n .. " hidden") end

  local status_str = " " .. table.concat(status_parts, "  │  ")
  table.insert(lines, status_str)
  -- Highlight timing badge: query=yellow, applied=green
  if timing_str then
    local ts, te = status_str:find(timing_str, 1, true)
    if ts then
      local action = session.last_action or "query"
      local timing_hl = (action == "query") and "GripStatusOk" or "GripBoolTrue"
      push_mark(#lines, ts - 1, te, timing_hl)
    end
  end
  -- Highlight "N staged" segment in GripStatusChg color
  if staged_count > 0 then
    local staged_text = staged_count .. " staged"
    local s, e = status_str:find(staged_text, 1, true)
    if s then push_mark(#lines, s - 1, e, "GripStatusChg") end
  end

  -- ── Filter lines (one per active clause: always fully visible, never truncated) ──
  if session.query_spec and #session.query_spec.filters > 0 then
    for _, f in ipairs(session.query_spec.filters) do
      local fline = " \xE2\x96\xBE " .. f.clause  -- ▾ clause
      table.insert(lines, fline)
      -- Dim the ▾ bullet (space + ▾(3 bytes) + space = bytes 0–4)
      push_mark(#lines, 0, 5, "GripColType")
    end
  end

  -- ── Hint line ──
  local hints
  local cv = session.current_view
  if cv and cv ~= "records" then
    -- Metadata view: compact tab bar with current view marked (▶)
    local parts = {}
    for i = 4, 9 do
      local vn = VIEW_KEYS[i]
      local label = VIEW_LABELS[vn] or vn
      if vn == cv then
        table.insert(parts, "▶" .. i .. ":" .. label)
      else
        table.insert(parts, i .. ":" .. label)
      end
    end
    hints = " " .. table.concat(parts, "  ") .. "  │  r:refresh  q:query  ?:help"
  elseif session.pending_mutation then
    local mt = session.pending_mutation.type or "SQL"
    hints = " a:execute " .. mt .. "  U:cancel  gs:preview SQL  q:query"
  elseif st.readonly and not is_editable(session) then
    hints = " r:refresh  Tab/w:col  gy:markdown  gq:saved  q:query  gL:pin  gJ:switch  4-9:views  ?:help"
  else
    hints = " i:edit  c:clone  d:delete  a:apply  r:refresh  gq:saved  q:query  gL:pin  gJ:switch  4-9:views  ?:help"
  end
  table.insert(lines, hints)

  local data_start = has_type_row and 5 or 4
  return { lines = lines, marks = marks, widths = widths, ordered = ordered, byte_positions = row_byte_positions, hdr_byte_positions = hdr_byte_positions, type_row_byte_positions = type_row_byte_positions, data_start = data_start, visible_columns = columns }
end

M.NULL_DISPLAY = NULL_DISPLAY
M.build_render = build_render
M.is_editable = is_editable
M.classify_cell = classify_cell
M.format_cell = format_cell
M.truncate_display = truncate_display

return M
