-- view/export.lua: grid export to files and the clipboard (:GripExport, gX, gE, gy).

local data = require("dadbod-grip.data")
local db   = require("dadbod-grip.db")
local qmod = require("dadbod-grip.query")
local ui   = require("dadbod-grip.ui")
local esc  = require("dadbod-grip.sql").escape_literal

local M = {}

local function sessions()
  return require("dadbod-grip.view")._sessions
end

-- ── export formatter ─────────────────────────────────────────────────────
-- Pure function: rows is list-of-list (parallel to cols), nil values represent
-- SQL NULL. Rows may have holes, so every branch indexes `for ci = 1, #cols`
-- rather than iterating the row. Returns a list of strings (lines).
-- The single formatter behind :GripExport / gX (file), gE (clipboard) and gy
-- (markdown yank); `format` is one of csv, tsv, json, sql, markdown, grip.
local function format_export(rows, cols, format, table_name)
  local tbl = table_name or "_grip_result"

  if format == "csv" then
    local lines = { table.concat(cols, ",") }
    for _, row in ipairs(rows) do
      local parts = {}
      for ci = 1, #cols do
        local v = row[ci]
        local s = v or ""
        if tostring(s):find('[,"\n]') then
          s = '"' .. tostring(s):gsub('"', '""') .. '"'
        end
        table.insert(parts, tostring(s))
      end
      table.insert(lines, table.concat(parts, ","))
    end
    return lines

  elseif format == "json" then
    local objects = {}
    for _, row in ipairs(rows) do
      local obj_parts = {}
      for ci, col in ipairs(cols) do
        local v = row[ci]  -- may be nil
        local json_val
        if v == nil then
          json_val = "null"
        elseif tonumber(v) then
          json_val = tostring(v)
        elseif v == "true" or v == "false" then
          json_val = v
        else
          json_val = '"' .. tostring(v):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
        end
        table.insert(obj_parts, '    "' .. col .. '": ' .. json_val)
      end
      table.insert(objects, "  {\n" .. table.concat(obj_parts, ",\n") .. "\n  }")
    end
    local lines = {}
    local json_str = "[\n" .. table.concat(objects, ",\n") .. "\n]"
    for _, l in ipairs(vim.split(json_str, "\n", { plain = true })) do
      table.insert(lines, l)
    end
    return lines

  elseif format == "sql" then
    local sql_mod = require("dadbod-grip.sql")
    local col_list = table.concat(
      vim.tbl_map(function(c) return sql_mod.quote_ident(c) end, cols), ", ")
    local lines = {}
    for _, row in ipairs(rows) do
      local vals = {}
      for ci = 1, #cols do
        local v = row[ci]
        if v == nil then
          table.insert(vals, "NULL")
        else
          table.insert(vals, "'" .. esc(tostring(v)) .. "'")
        end
      end
      table.insert(lines, string.format(
        "INSERT INTO %s (%s) VALUES (%s);",
        sql_mod.quote_ident(tbl), col_list, table.concat(vals, ", ")))
    end
    return lines

  elseif format == "tsv" then
    local lines = { table.concat(cols, "\t") }
    for _, row in ipairs(rows) do
      local parts = {}
      for ci = 1, #cols do table.insert(parts, row[ci] or "") end
      table.insert(lines, table.concat(parts, "\t"))
    end
    return lines

  elseif format == "markdown" then
    local function pipe_esc(s) return (tostring(s):gsub("|", "\\|")) end
    local lines = {
      "| " .. table.concat(vim.tbl_map(pipe_esc, cols), " | ") .. " |",
      "| " .. table.concat(vim.tbl_map(function() return "---" end, cols), " | ") .. " |",
    }
    for _, row in ipairs(rows) do
      local parts = {}
      for ci = 1, #cols do table.insert(parts, pipe_esc(row[ci] or "")) end
      table.insert(lines, "| " .. table.concat(parts, " | ") .. " |")
    end
    return lines

  elseif format == "grip" then
    -- Box-drawing table matching the grid style. NULL shows as the word NULL,
    -- numeric cells are right-aligned.
    local widths = {}
    for ci, col in ipairs(cols) do
      widths[ci] = vim.fn.strdisplaywidth(col)
    end
    for _, row in ipairs(rows) do
      for ci = 1, #cols do
        widths[ci] = math.max(widths[ci], vim.fn.strdisplaywidth(tostring(row[ci] or "NULL")))
      end
    end
    local rule_parts = {}
    for ci = 1, #cols do
      table.insert(rule_parts, string.rep("═", widths[ci] + 2))
    end
    local hdr_parts = {}
    for ci, col in ipairs(cols) do
      local pad = widths[ci] - vim.fn.strdisplaywidth(col)
      table.insert(hdr_parts, " " .. col .. string.rep(" ", pad) .. " ")
    end
    local lines = {
      "╔" .. table.concat(rule_parts, "╤") .. "╗",
      "║" .. table.concat(hdr_parts, "│") .. "║",
      "╠" .. table.concat(rule_parts, "╪") .. "╣",
    }
    for _, row in ipairs(rows) do
      local row_parts = {}
      for ci = 1, #cols do
        local v = row[ci]
        local display = v or "NULL"
        local pad = widths[ci] - vim.fn.strdisplaywidth(display)
        if v and tonumber(v) then
          table.insert(row_parts, " " .. string.rep(" ", pad) .. display .. " ")
        else
          table.insert(row_parts, " " .. display .. string.rep(" ", pad) .. " ")
        end
      end
      table.insert(lines, "║" .. table.concat(row_parts, "│") .. "║")
    end
    table.insert(lines, "╚" .. table.concat(rule_parts, "╧") .. "╝")
    return lines
  end

  return {}
end

local function current_export_rows(session)
  local rows = {}
  local cols = session.state.columns or {}
  local ordered = session._render and session._render.ordered
  if not ordered then return session.state.rows or {}, cols end
  for _, row_idx in ipairs(ordered) do
    local row = {}
    for ci, col in ipairs(cols) do
      row[ci] = data.effective_value(session.state, row_idx, col)
    end
    rows[#rows + 1] = row
  end
  return rows, cols
end

local function matching_count(session)
  if not session.query_spec then return nil, "All-row export requires a query-backed result" end
  local result, err = db.query(qmod.build_count_sql(session.query_spec), session.url)
  if not result then return nil, err or "Count query failed" end
  return tonumber(result.rows and result.rows[1] and result.rows[1][1]) or 0
end

--- Provide the rows to export. Only a result Grip capped (a table opened with
--- TOP N that filled the cap) asks whether to fetch every row instead.
local function request_export_rows(session, destination, callback)
  local cap = session.query_spec and session.query_spec.limit
  local choose = cap and #session.state.rows >= cap and vim.ui.select
    or function(_, _, cb) cb("Shown rows") end
  choose({ "Shown rows", "All matching rows" }, { prompt = "Export scope:" }, function(scope)
    if not scope then return end

    local rows, cols, count
    if scope == "All matching rows" then
      local count_err
      count, count_err = matching_count(session)
      if count == nil then
        vim.notify("Export failed: " .. tostring(count_err or "all-row count unavailable"),
          vim.log.levels.ERROR)
        return
      end
      if destination == "clipboard" and count > 100000 then
        vim.notify("Clipboard export is limited to 100,000 rows; export to a file instead",
          vim.log.levels.WARN)
        return
      end
      if count > 10000 and not ui.confirm(string.format(
          "Export %d matching rows? (y/N): ", count)) then return end

      if not session.query_spec then
        vim.notify("Export failed: all-row export requires a query-backed result", vim.log.levels.ERROR)
        return
      end
      local result, err = db.query(
        qmod.build_sql(session.query_spec, { uncapped = true }), session.url)
      if not result then
        vim.notify("Export failed: " .. tostring(err or "query failed"), vim.log.levels.ERROR)
        return
      end
      rows, cols = result.rows or {}, result.columns or session.state.columns or {}
      local fetched_count = #rows
      if destination == "clipboard" and fetched_count > 100000 then
        vim.notify("Clipboard export is limited to 100,000 rows; export to a file instead",
          vim.log.levels.WARN)
        return
      end
      if count <= 10000 and fetched_count > 10000 and not ui.confirm(string.format(
          "Export %d matching rows? (y/N): ", fetched_count)) then return end
      count = fetched_count
    else
      rows, cols = current_export_rows(session)
      count = #rows
      if destination == "clipboard" and count > 100000 then
        vim.notify("Clipboard export is limited to 100,000 rows; export to a file instead",
          vim.log.levels.WARN)
        return
      end
      if count > 10000 and not ui.confirm(string.format(
          "Export %d rows? (y/N): ", count)) then return end
    end

    if count == 0 then
      vim.notify("No rows to export", vim.log.levels.WARN)
      return
    end
    callback(rows, cols, scope)
  end)
end

--- Stream an export to a same-directory temporary file, then atomically rename
--- it into place. Any formatter/write/rename failure removes only the temp file.
local function write_export_file(rows, cols, format, table_name, path)
  local temp = string.format("%s.grip-tmp-%d-%d", path, vim.fn.getpid(), vim.uv.hrtime())
  local file, open_err = io.open(temp, "wb")
  if not file then return nil, open_err end

  local ok, write_err = xpcall(function()
    local function write_lines(lines)
      if #lines == 0 then return end
      local wrote, err = file:write(table.concat(lines, "\n"), "\n")
      if not wrote then error(err or "write failed", 0) end
    end

    local batch_size = 1000
    if format == "json" then write_lines({ "[" }) end
    local first_batch = true
    for start = 1, #rows, batch_size do
      local batch = {}
      for i = start, math.min(start + batch_size - 1, #rows) do batch[#batch + 1] = rows[i] end
      local lines = format_export(batch, cols, format, table_name)
      if format == "csv" and not first_batch then table.remove(lines, 1) end
      if format == "json" then
        table.remove(lines, 1)
        table.remove(lines, #lines)
        if not first_batch and #lines > 0 then lines[1] = "," .. lines[1] end
      end
      write_lines(lines)
      first_batch = false
    end
    if format == "json" then write_lines({ "]" }) end
    local closed, close_err = file:close()
    if not closed then error(close_err or "close failed", 0) end
  end, debug.traceback)

  if not ok then
    pcall(function() file:close() end)
    vim.fn.delete(temp)
    return nil, write_err
  end
  local renamed, rename_err = vim.uv.fs_rename(temp, path)
  if not renamed then
    vim.fn.delete(temp)
    return nil, rename_err or "atomic rename failed"
  end
  return true
end

function M.export_to_clipboard(bufnr)
  local session = sessions()[bufnr]
  if not session or not session.state then
    vim.notify("No grip result to export", vim.log.levels.WARN)
    return
  end
  request_export_rows(session, "clipboard", function(rows, cols)
    local formats = { "CSV", "TSV", "JSON", "SQL INSERT", "Markdown", "Grip Table" }
    vim.ui.select(formats, { prompt = "Export format:" }, function(choice)
      if not choice then return end
      local ids = {
        ["CSV"] = "csv", ["TSV"] = "tsv", ["JSON"] = "json",
        ["SQL INSERT"] = "sql", ["Markdown"] = "markdown", ["Grip Table"] = "grip",
      }
      local output = table.concat(format_export(
        rows, cols, ids[choice], session.state.table_name or "table_name"), "\n")
      vim.fn.setreg("+", output)
      vim.notify(string.format("Exported %d rows as %s to clipboard", #rows, choice),
        vim.log.levels.INFO)
    end)
  end)
end

--- Export the shown rows, or all matching rows, to a file.
--- Called by gX keymap and :GripExport command.
function M.do_export(bufnr)
  local session = sessions()[bufnr]
  if not session or not session.state then
    vim.notify("No grip result to export", vim.log.levels.WARN)
    return
  end

  request_export_rows(session, "file", function(rows, cols)
    -- Scope is intentionally chosen before format.
    local fmt = ui.input({ prompt = "Export format [csv/json/sql]: " })
    if not fmt then return end
    fmt = fmt:lower()
    if fmt ~= "csv" and fmt ~= "json" and fmt ~= "sql" then
      vim.notify("Unknown format: " .. fmt .. " (use csv, json, or sql)", vim.log.levels.ERROR)
      return
    end

    local ext = fmt == "sql" and "sql" or fmt
    local path = ui.input({
      prompt = "Save to: ",
      default = vim.fn.getcwd() .. "/grip_export." .. ext,
      completion = "file",
    })
    if not path then return end

    local ok, err = write_export_file(
      rows, cols, fmt, session.query_spec and session.query_spec.table_name, path)
    if ok then
      vim.notify(string.format("Exported %d rows → %s", #rows, path), vim.log.levels.INFO)
    else
      vim.notify("Export failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

M.format_export = format_export
M.request_export_rows = request_export_rows
M.write_export_file = write_export_file

return M
