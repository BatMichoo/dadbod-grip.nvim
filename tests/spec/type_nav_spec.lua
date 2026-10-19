-- type_nav_spec.lua: RED test: w/b/Tab navigation on header and type rows
local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function cleanup()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_list_wins(0)[#vim.api.nvim_tabpage_list_wins(0)], true)
  end
end

-- Helper: open a grid with type row enabled
local function open_with_types()
  local state = data.new({
    columns = { "id", "name", "age" },
    rows = { { "1", "alice", "30" }, { "2", "bob", "25" } },
    primary_keys = { "id" },
    table_name = "users",
    url = "sqlite:test.db",
    sql = "SELECT * FROM users",
  })
  local bufnr = view.open(state, "sqlite:test.db", "SELECT * FROM users", {})
  local session = view._sessions[bufnr]
  -- Enable type row
  session.show_types = true
  session._column_info = {
    { column_name = "id", data_type = "INTEGER" },
    { column_name = "name", data_type = "TEXT" },
    { column_name = "age", data_type = "INTEGER" },
  }
  view.render(bufnr, session.state)
  return bufnr, session
end

-- Helper: call nav_col via the w keymap callback
local function press_w(bufnr)
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  for _, m in ipairs(maps) do
    if m.lhs == "w" and m.callback then
      m.callback()
      return true
    end
  end
  return false
end

local function press_b(bufnr)
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  for _, m in ipairs(maps) do
    if m.lhs == "b" and m.callback then
      m.callback()
      return true
    end
  end
  return false
end

-- ── Tests ──

test("w keymap exists on grid buffer", function()
  cleanup()
  local bufnr = open_with_types()
  local found = false
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == "w" then found = true end
  end
  assert(found, "w keymap registered")
  cleanup()
end)

test("w on the first data row moves to next column", function()
  cleanup()
  local bufnr = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  -- hint, title, header, type, separator, then data
  local ds = view._sessions[bufnr]._render.data_start
  vim.api.nvim_win_set_cursor(win, { ds, 4 }) -- first data row, col at "id"
  press_w(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(win)
  eq(cursor[1], ds, "stays on the first data row")
  assert(cursor[2] > 4, "moved to next column (col " .. cursor[2] .. " > 4)")
  cleanup()
end)

test("w on header row moves to next column", function()
  cleanup()
  local bufnr = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  local hdr = view._sessions[bufnr]._render.hdr_row
  vim.api.nvim_win_set_cursor(win, { hdr, 4 }) -- header row, first column
  press_w(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(win)
  eq(cursor[1], hdr, "stays on header row")
  assert(cursor[2] > 4, "moved to next column on header (col " .. cursor[2] .. " > 4)")
  cleanup()
end)

test("w on type row moves to next column", function()
  cleanup()
  local bufnr = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  local type_row = view._sessions[bufnr]._render.type_row
  vim.api.nvim_win_set_cursor(win, { type_row, 4 }) -- type row, first column
  press_w(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(win)
  eq(cursor[1], type_row, "stays on type row")
  assert(cursor[2] > 4, "moved to next column on type row (col " .. cursor[2] .. " > 4)")
  cleanup()
end)

test("b on type row moves to previous column", function()
  cleanup()
  local bufnr = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  local r = view._sessions[bufnr]._render
  local cols = r.visible_columns
  local ref_bp = r.byte_positions[1]
  -- Start at last column
  local last_col_start = ref_bp[cols[#cols]].start
  vim.api.nvim_win_set_cursor(win, { r.type_row, last_col_start })
  press_b(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(win)
  eq(cursor[1], r.type_row, "stays on type row")
  assert(cursor[2] < last_col_start, "moved back (col " .. cursor[2] .. " < " .. last_col_start .. ")")
  cleanup()
end)

test("w cycles through all 3 columns on type row", function()
  cleanup()
  local bufnr = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { view._sessions[bufnr]._render.type_row, 4 }) -- type row, col 1

  local positions = { vim.api.nvim_win_get_cursor(win)[2] }
  press_w(bufnr)
  table.insert(positions, vim.api.nvim_win_get_cursor(win)[2])
  press_w(bufnr)
  table.insert(positions, vim.api.nvim_win_get_cursor(win)[2])

  -- All 3 positions should be different
  assert(positions[1] ~= positions[2], "pos 1 != pos 2")
  assert(positions[2] ~= positions[3], "pos 2 != pos 3")
  assert(positions[1] ~= positions[3], "pos 1 != pos 3")
  -- Should be ascending
  assert(positions[1] < positions[2], "ascending: " .. positions[1] .. " < " .. positions[2])
  assert(positions[2] < positions[3], "ascending: " .. positions[2] .. " < " .. positions[3])
  cleanup()
end)

test("w on readonly header row works", function()
  cleanup()
  local state = data.new({
    columns = { "id", "name" },
    rows = { { "1", "alice" } },
    primary_keys = {},  -- no PKs = readonly
    table_name = nil,
    url = "sqlite:test.db",
    sql = "SELECT * FROM users",
  })
  local bufnr = view.open(state, "sqlite:test.db", "SELECT * FROM users", {})
  local session = view._sessions[bufnr]
  assert(session.state.readonly, "is readonly")

  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { session._render.hdr_row, 4 }) -- header row
  local before = vim.api.nvim_win_get_cursor(win)[2]
  press_w(bufnr)
  local after = vim.api.nvim_win_get_cursor(win)[2]
  assert(after > before, "w moved cursor on readonly header (from " .. before .. " to " .. after .. ")")
  cleanup()
end)

print(string.format("\ntype_nav_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
