-- column_set_spec.lua: multi-cursor column set (grid_column_set).
-- From normal mode, stage the same value for the current column across ALL
-- visible rows of the current page (bulk-edit a status field without SQL or
-- a visual selection). Mirror of the visual-mode batch edit (grid_v_edit),
-- but scoped to the rendered page instead of a selection.
--
-- Covered:
--   * all visible rows staged
--   * staged-deleted rows skipped
--   * staged-inserted rows included
--   * read-only guard (no PK)
--   * NULL sentinel (editor.NULL_VALUE stages NULL)
--   * only the current page is touched when the table has more rows
--   * confirm prompt above 50 rows (cancel aborts)
--   * editor title / cancel behaviour / default keymap

local db     = require("dadbod-grip.db")
local data   = require("dadbod-grip.data")
local qmod   = require("dadbod-grip.query")
local view   = require("dadbod-grip.view")
local editor = require("dadbod-grip.editor")

local url = "sqlite:tests/seed_sqlite.db"

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

local function truthy(a, msg)
  assert(a, (msg or "") .. ": expected truthy, got " .. tostring(a))
end

local function contains(s, pattern, msg)
  assert(type(s) == "string" and s:find(pattern, 1, true),
    (msg or "") .. ": expected '" .. tostring(s) .. "' to contain '" .. pattern .. "'")
end

-- ── grid helpers (mirror fk_reverse_spec setup style) ─────────────────────

local function cleanup_grids()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    local wins = vim.api.nvim_tabpage_list_wins(0)
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end

--- Open a real grid for a table (same result shape init.lua builds).
local function open_grid(tbl, limit)
  local spec = qmod.new_table(tbl, limit or 100)
  local sql_str = qmod.build_sql(spec)
  local result, err = db.query(sql_str, url)
  assert(result, "query failed for " .. tbl .. ": " .. tostring(err))
  result.primary_keys = db.get_primary_keys(tbl, url) or {}
  result.table_name = tbl
  result.url = url
  result.sql = sql_str
  local state = data.new(result)
  local bufnr = view.open(state, url, sql_str)
  view._sessions[bufnr].query_spec = spec
  return bufnr
end

--- Open a grid straight from a synthetic state (no DB round-trip).
local function open_state_grid(query_result)
  local state = data.new(query_result)
  return view.open(state, query_result.url or url, query_result.sql or "SELECT 1")
end

--- Put the cursor on a given data row (1-based render order) and column.
local function cursor_to(bufnr, row_order, col_name)
  local r = view._sessions[bufnr]._render
  local line = (r.data_start or 4) + row_order - 1
  local bp = r.byte_positions[row_order][col_name]
  assert(bp, "no byte position for column " .. col_name)
  vim.api.nvim_win_set_cursor(0, { line, bp.start })
end

--- Run fn with vim.notify captured; returns list of messages.
local function with_notify(fn)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m, _) table.insert(msgs, tostring(m)) end
  local ok, err = pcall(fn)
  vim.notify = orig
  if not ok then error(err) end
  return msgs
end

--- Run fn with editor.open stubbed to immediately answer `answer`.
--- answer == false means "cancel" (callback never fires, like q/<Esc>).
--- Returns { called, title, initial } describing the stubbed invocation.
local function with_editor(answer, fn)
  local info = { called = false }
  local orig = editor.open
  editor.open = function(title, initial, cb, _opts)
    info.called = true
    info.title = title
    info.initial = initial
    if answer ~= false then cb(answer) end
  end
  local ok, err = pcall(fn)
  editor.open = orig
  if not ok then error(err) end
  return info
end

--- Run fn with vim.fn.confirm stubbed to return `choice`.
--- Returns { called, msg } describing the stubbed invocation.
local function with_confirm(choice, fn)
  local info = { called = false }
  local orig = vim.fn.confirm
  vim.fn.confirm = function(msg, ...)
    info.called = true
    info.msg = msg
    return choice
  end
  local ok, err = pcall(fn)
  vim.fn.confirm = orig
  if not ok then error(err) end
  return info
end

-- ── all visible rows staged ────────────────────────────────────────────────

test("column set: stages the value for every visible row", function()
  cleanup_grids()
  local bufnr = open_grid("users")       -- 15 rows, single page
  cursor_to(bufnr, 1, "age")
  local msgs = with_notify(function()
    with_editor("99", function() view._column_set(bufnr) end)
  end)
  local st = view._sessions[bufnr].state
  local n = #st.rows
  eq(n, 15, "all 15 users on the page")
  for ri = 1, n do
    eq(data.effective_value(st, ri, "age"), "99", "row " .. ri .. " age staged")
  end
  local found
  for _, m in ipairs(msgs) do
    if m:find("15 rows", 1, true) and m:find("age", 1, true) then found = m end
  end
  truthy(found, "notify mentions 15 rows and the column")
  cleanup_grids()
end)

test("column set: editor title says what is happening", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  cursor_to(bufnr, 2, "name")
  local info = with_editor("x", function()
    with_notify(function() view._column_set(bufnr) end)
  end)
  eq(info.title, "Set 15 rows (name)", "editor title")
  cleanup_grids()
end)

test("column set: initial editor value is the cell under cursor", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  cursor_to(bufnr, 1, "name")            -- row 1 = Alice
  local info = with_editor(false, function()
    with_notify(function() view._column_set(bufnr) end)
  end)
  truthy(info.called, "editor opened")
  eq(info.initial, "Alice", "prefilled with current cell value")
  cleanup_grids()
end)

test("column set: cancelling the editor stages nothing", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  cursor_to(bufnr, 1, "age")
  with_editor(false, function()
    with_notify(function() view._column_set(bufnr) end)
  end)
  local st = view._sessions[bufnr].state
  eq(data.count_staged(st), 0, "no staged changes after cancel")
  cleanup_grids()
end)

-- ── staged-deleted rows skipped, staged-inserted rows included ────────────

test("column set: rows staged as deleted are skipped", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  local session = view._sessions[bufnr]
  view.apply_edit(bufnr, data.toggle_delete(session.state, 2))
  cursor_to(bufnr, 1, "age")
  with_editor("77", function()
    with_notify(function() view._column_set(bufnr) end)
  end)
  local st = view._sessions[bufnr].state
  eq(st.changes[2], nil, "deleted row 2 not touched")
  eq(data.effective_value(st, 1, "age"), "77", "row 1 staged")
  eq(data.effective_value(st, 3, "age"), "77", "row 3 staged")
  cleanup_grids()
end)

test("column set: staged-inserted rows are included", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  local session = view._sessions[bufnr]
  view.apply_edit(bufnr, data.insert_row_with_values(session.state, 1, { name = "Zed" }))
  local st0 = view._sessions[bufnr].state
  local ins_idx
  for idx in pairs(st0.inserted) do ins_idx = idx end
  truthy(ins_idx, "insert staged")
  cursor_to(bufnr, 1, "age")
  with_editor("55", function()
    with_notify(function() view._column_set(bufnr) end)
  end)
  local st = view._sessions[bufnr].state
  eq(st.inserted[ins_idx].values.age, "55", "inserted row got the value")
  eq(data.effective_value(st, 1, "age"), "55", "original row got the value")
  cleanup_grids()
end)

-- ── read-only guard ────────────────────────────────────────────────────────

test("column set: read-only grid notifies and never opens the editor", function()
  cleanup_grids()
  local bufnr = open_state_grid({
    columns = { "id", "status" },
    rows = { { "1", "new" }, { "2", "old" } },
    primary_keys = {},                    -- no PK -> readonly
    table_name = "no_pk",
    url = url,
  })
  cursor_to(bufnr, 1, "status")
  local info
  local msgs = with_notify(function()
    info = with_editor("x", function() view._column_set(bufnr) end)
  end)
  eq(info.called, false, "editor not opened on read-only grid")
  local found
  for _, m in ipairs(msgs) do
    if m:find("Read-only: no primary key detected", 1, true) then found = m end
  end
  truthy(found, "read-only notify (same text as sibling actions)")
  eq(data.count_staged(view._sessions[bufnr].state), 0, "nothing staged")
  cleanup_grids()
end)

-- ── NULL sentinel ──────────────────────────────────────────────────────────

test("column set: editor NULL sentinel stages NULL for every visible row", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  cursor_to(bufnr, 1, "email")
  with_editor(editor.NULL_VALUE, function()
    with_notify(function() view._column_set(bufnr) end)
  end)
  local st = view._sessions[bufnr].state
  truthy(st.changes[1], "row 1 has a staged change")
  eq(data.effective_value(st, 1, "email"), nil, "row 1 email staged NULL")
  eq(data.effective_value(st, 5, "email"), nil, "row 5 email staged NULL")
  cleanup_grids()
end)

-- ── pagination: only the current page is touched ──────────────────────────

test("column set: only the visible page is staged when more rows exist", function()
  cleanup_grids()
  local bufnr = open_grid("users", 5)    -- 15 users, page size 5
  local session = view._sessions[bufnr]
  eq(#session.state.rows, 5, "page holds 5 of 15 rows")
  cursor_to(bufnr, 1, "age")
  local msgs = with_notify(function()
    with_editor("11", function() view._column_set(bufnr) end)
  end)
  local st = view._sessions[bufnr].state
  local staged = 0
  for _ in pairs(st.changes) do staged = staged + 1 end
  eq(staged, 5, "exactly the 5 visible rows staged")
  local found
  for _, m in ipairs(msgs) do
    if m:find("5 rows", 1, true) then found = m end
  end
  truthy(found, "notify counts only the visible page")
  cleanup_grids()
end)

-- ── confirm above 50 rows ──────────────────────────────────────────────────

local function big_state_grid(n)
  local rows = {}
  for i = 1, n do rows[i] = { tostring(i), "pending" } end
  return open_state_grid({
    columns = { "id", "status" },
    rows = rows,
    primary_keys = { "id" },
    table_name = "big",
    url = url,
  })
end

test("column set: >50 visible rows asks for confirmation; cancel aborts", function()
  cleanup_grids()
  local bufnr = big_state_grid(60)
  cursor_to(bufnr, 1, "status")
  local editor_info
  local confirm_info = with_confirm(2, function()   -- 2 = Cancel
    editor_info = with_editor("done", function()
      with_notify(function() view._column_set(bufnr) end)
    end)
  end)
  truthy(confirm_info.called, "confirm prompted for 60 rows")
  contains(confirm_info.msg, "status", "prompt names the column")
  contains(confirm_info.msg, "60", "prompt names the row count")
  eq(editor_info.called, false, "editor not opened after cancel")
  eq(data.count_staged(view._sessions[bufnr].state), 0, "nothing staged")
  cleanup_grids()
end)

test("column set: >50 rows confirmed stages all of them", function()
  cleanup_grids()
  local bufnr = big_state_grid(60)
  cursor_to(bufnr, 1, "status")
  with_confirm(1, function()                        -- 1 = Yes
    with_editor("done", function()
      with_notify(function() view._column_set(bufnr) end)
    end)
  end)
  local st = view._sessions[bufnr].state
  eq(data.effective_value(st, 1, "status"), "done", "row 1 staged")
  eq(data.effective_value(st, 60, "status"), "done", "row 60 staged")
  cleanup_grids()
end)

test("column set: 50 or fewer rows never prompts", function()
  cleanup_grids()
  local bufnr = big_state_grid(50)
  cursor_to(bufnr, 1, "status")
  local confirm_info = with_confirm(2, function()
    with_editor("done", function()
      with_notify(function() view._column_set(bufnr) end)
    end)
  end)
  eq(confirm_info.called, false, "no confirm at exactly 50 rows")
  eq(data.effective_value(view._sessions[bufnr].state, 50, "status"), "done", "staged")
  cleanup_grids()
end)

-- ── keymap registration ────────────────────────────────────────────────────

test("grid_column_set has a collision-free default key", function()
  local km = require("dadbod-grip.keymaps")
  truthy(km.defaults.grid_column_set, "default key exists")
  local key = km.defaults.grid_column_set
  for action, k in pairs(km.defaults) do
    if action ~= "grid_column_set" and not action:match("^sidebar_")
      and not action:match("^qpad_") and not action:match("^grid_v_") then
      assert(k ~= key, "key '" .. tostring(key) .. "' collides with " .. action)
    end
  end
end)

--- Summary
print(string.format("\ncolumn_set_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
