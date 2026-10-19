-- query_pad_spec.lua: unit tests for query_pad.sync_query
-- Tests the replace-vs-append logic without any DB I/O.
dofile("tests/minimal_init.lua")

local qp = require("dadbod-grip.query_pad")

local pass, fail = 0, 0

local function eq(a, b, msg)
  if a == b then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected: %s\n  got:      %s", msg, tostring(b), tostring(a)))
  end
end

-- Helper: create a scratch buffer, wire it as the pad, return bufnr.
-- We expose _set_pad_bufnr for testing only.
local function make_pad()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].modifiable = true
  qp._set_pad_bufnr(bufnr)
  return bufnr
end

local function get_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- ── sync_query: populate empty pad ──────────────────────────────────────────

do
  local b = make_pad()
  set_lines(b, {})
  qp.sync_query("SELECT * FROM users")
  local lines = get_lines(b)
  eq(lines[1], "SELECT * FROM users", "empty pad: line 1 is the SQL")
  eq(#lines, 1, "empty pad: exactly 1 line")
end

-- ── sync_query: replace hint-only pad ───────────────────────────────────────

do
  local b = make_pad()
  set_lines(b, { "-- C-CR:run  go:tables", "" })
  qp.sync_query("SELECT * FROM orders")
  local lines = get_lines(b)
  eq(lines[1], "SELECT * FROM orders", "hint pad: line 1 is the SQL")
  eq(#lines, 1, "hint pad: exactly 1 line after replace")
end

-- ── sync_query: user content is never touched ───────────────────────────────
-- Browsing tables must not add queries below the user's SQL: C-CR runs the whole
-- buffer, so anything appended would run with it.

do
  local b = make_pad()
  set_lines(b, { "SELECT id FROM users" })
  qp.sync_query("SELECT * FROM orders")
  local lines = get_lines(b)
  eq(#lines, 1, "user content: nothing appended")
  eq(lines[1], "SELECT id FROM users", "user content: query untouched")
end

do
  -- user SQL with blank lines and the hint line stays exactly as written
  local b = make_pad()
  local mine = {
    "-- C-CR:run  go:tables",
    "",
    "SELECT id, name FROM customers",
    "",
    "WHERE active = true",
  }
  set_lines(b, mine)
  qp.sync_query("SELECT * FROM orders")
  qp.sync_query("SELECT * FROM products")
  eq(table.concat(get_lines(b), "\n"), table.concat(mine, "\n"),
    "hint+content: buffer unchanged after several syncs")
end

-- ── sync_query: consecutive auto-syncs replace the last one ───────────────────

do
  local b = make_pad()
  set_lines(b, { "-- C-CR:run", "" })  -- fresh hint-only pad
  qp.sync_query('SELECT * FROM "A"')
  qp.sync_query('SELECT * FROM "B"')
  qp.sync_query('SELECT * FROM "C"')
  local lines = get_lines(b)
  eq(lines[1], 'SELECT * FROM "C"', "pure-nav: only the latest table remains")
  eq(#lines, 1, "pure-nav: exactly one query, no accumulation")
end

-- ── sync_query: once edited, the query is the user's ──────────────────────────

do
  local b = make_pad()
  set_lines(b, { "-- C-CR:run", "" })
  qp.sync_query('SELECT * FROM "A"')                     -- auto
  set_lines(b, { [[SELECT * FROM "A" WHERE id = 1]] })  -- user edits it
  qp.sync_query('SELECT * FROM "B"')                     -- left alone
  qp.sync_query('SELECT * FROM "C"')                     -- still left alone
  local lines = get_lines(b)
  eq(#lines, 1, "edited: nothing appended")
  eq(lines[1], [[SELECT * FROM "A" WHERE id = 1]], "edited: user's edit preserved")
end

do
  -- user adds to our query: the whole thing becomes theirs
  local b = make_pad()
  set_lines(b, {})
  qp.sync_query('SELECT * FROM "A"')
  set_lines(b, { 'SELECT * FROM "A"', "", "SELECT 2" })
  qp.sync_query('SELECT * FROM "B"')
  eq(table.concat(get_lines(b), "\n"), 'SELECT * FROM "A"\n\nSELECT 2',
    "extended: our query plus user's addition left alone")
end

do
  -- clearing the pad hands it back to sync
  local b = make_pad()
  set_lines(b, { "SELECT 1" })
  qp.sync_query("SELECT * FROM orders")  -- user content: no-op
  set_lines(b, {})
  qp.sync_query("SELECT * FROM orders")
  eq(get_lines(b)[1], "SELECT * FROM orders", "cleared: empty pad is populated again")
end

-- ── sync_query: no-op on blank/whitespace sql ────────────────────────────────

do
  local b = make_pad()
  set_lines(b, { "SELECT 1" })
  qp.sync_query("   ")
  local lines = get_lines(b)
  eq(#lines, 1, "whitespace sql: pad unchanged")
  eq(lines[1], "SELECT 1", "whitespace sql: content preserved")
end

-- ── sync_query: no-op when pad bufnr is nil ──────────────────────────────────

do
  qp._set_pad_bufnr(nil)
  local ok = pcall(qp.sync_query, "SELECT 1")
  eq(ok, true, "nil pad bufnr: no error thrown")
end

-- ── _has_real_content: pure helper tests ─────────────────────────────────────

do
  -- empty table
  eq(qp._has_real_content({}), false, "hrc: empty lines = no content")
  -- single blank line
  eq(qp._has_real_content({ "" }), false, "hrc: single blank = no content")
  -- whitespace only
  eq(qp._has_real_content({ "   " }), false, "hrc: whitespace only = no content")
  -- hint-only (single)
  eq(qp._has_real_content({ "-- C-CR:run  go:tables" }), false, "hrc: hint line only = no content")
  -- hint + blank line
  eq(qp._has_real_content({ "-- C-CR:run  go:tables", "" }), false, "hrc: hint+blank = no content")
  eq(qp._has_real_content({ "-- F5:run block or buffer  gn:notebooks", "" }), false,
    "hrc: F5 hint = no content")
  eq(qp._has_real_content({ "-- S-F5:run block or buffer", "SELECT 1" }), true,
    "hrc: a remapped run key's hint is still the hint")
  -- hint + real SQL
  eq(qp._has_real_content({ "-- C-CR:run  go:tables", "", "SELECT 1" }), true, "hrc: hint+sql = has content")
  -- real SQL (no hint)
  eq(qp._has_real_content({ "SELECT id FROM users" }), true, "hrc: plain sql = has content")
  -- multi-line SQL
  eq(qp._has_real_content({ "SELECT *", "FROM orders", "WHERE id = 1" }), true, "hrc: multiline sql = has content")
end

-- ── _block_under_cursor ───────────────────────────────────────────────────────

-- Helper: create a buffer with lines, open it in a window, position cursor.
-- Returns bufnr. The window is set as current so nvim_win_get_cursor(0) works.
local function buf_with_cursor(lines, cursor_line)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor", width = 80, height = 20, row = 0, col = 0, style = "minimal",
  })
  vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
  return bufnr, win
end

local function close_win(win)
  if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
end

do
  -- cursor inside a ```sql block
  local lines = {
    "# Header",
    "Some text.",
    "```sql",
    "SELECT 1",
    "FROM dual",
    "```",
    "More text.",
  }
  local b, w = buf_with_cursor(lines, 4)
  local result = qp._block_under_cursor(b)
  eq(result, "SELECT 1\nFROM dual", "block_under_cursor: cursor inside block returns SQL")
  close_win(w)
end

do
  -- cursor on the opening fence line: still extracts the block below it
  local lines = { "```sql", "SELECT 2", "```" }
  local b, w = buf_with_cursor(lines, 1)
  local result = qp._block_under_cursor(b)
  eq(result, "SELECT 2", "block_under_cursor: cursor on opening fence extracts block below")
  close_win(w)
end

do
  -- cursor outside any block (plain text)
  local lines = { "Some prose.", "No SQL here." }
  local b, w = buf_with_cursor(lines, 1)
  local result = qp._block_under_cursor(b)
  eq(result, nil, "block_under_cursor: cursor outside block returns nil")
  close_win(w)
end

do
  -- cursor on the closing fence
  local lines = { "```sql", "SELECT 3", "```" }
  local b, w = buf_with_cursor(lines, 3)
  local result = qp._block_under_cursor(b)
  eq(result, nil, "block_under_cursor: cursor on closing fence returns nil")
  close_win(w)
end

do
  -- multiple blocks: cursor in second block returns only second block
  local lines = {
    "```sql",
    "SELECT 1",
    "```",
    "Text between blocks.",
    "```sql",
    "SELECT 2",
    "FROM t",
    "```",
  }
  local b, w = buf_with_cursor(lines, 6)
  local result = qp._block_under_cursor(b)
  eq(result, "SELECT 2\nFROM t", "block_under_cursor: cursor in second block returns second block")
  close_win(w)
end

do
  -- non-sql fence (```python) does not match
  local lines = { "```python", "print('hi')", "```" }
  local b, w = buf_with_cursor(lines, 2)
  local result = qp._block_under_cursor(b)
  eq(result, nil, "block_under_cursor: non-sql fence returns nil")
  close_win(w)
end

do
  -- unclosed block (no closing fence) returns nil
  local lines = { "```sql", "SELECT 4" }
  local b, w = buf_with_cursor(lines, 2)
  local result = qp._block_under_cursor(b)
  eq(result, nil, "block_under_cursor: unclosed block returns nil")
  close_win(w)
end

-- ── _pad_sql_to_run ──────────────────────────────────────────────────────────
-- Regression: C-CR must run the whole buffer. Blank lines between (or inside)
-- statements must never cut the SQL down to the paragraph under the cursor.

do
  -- blank lines between statements: cursor anywhere runs everything
  local lines = {
    "CREATE TABLE t (id INT);",
    "",
    "INSERT INTO t VALUES (1);",
    "",
    "SELECT * FROM t;",
  }
  local b, w = buf_with_cursor(lines, 3)
  eq(qp._pad_sql_to_run(b), table.concat(lines, "\n"),
    "pad_sql_to_run: blank-line-separated statements all run")
  close_win(w)
end

do
  -- blank line inside one statement (between CTEs) keeps it intact
  local lines = {
    "WITH a AS (SELECT 1 AS x),",
    "",
    "b AS (SELECT 2 AS x)",
    "",
    "SELECT * FROM a UNION ALL SELECT * FROM b",
  }
  local b, w = buf_with_cursor(lines, 1)
  eq(qp._pad_sql_to_run(b), table.concat(lines, "\n"),
    "pad_sql_to_run: statement with inner blank lines kept whole")
  close_win(w)
end

do
  -- hint line is stripped, surrounding blanks trimmed
  local lines = { "-- F5:run block or buffer", "", "SELECT 1;", "", "SELECT 2;", "" }
  local b, w = buf_with_cursor(lines, 5)
  eq(qp._pad_sql_to_run(b), "SELECT 1;\n\nSELECT 2;",
    "pad_sql_to_run: hint excluded")
  close_win(w)
end

do
  -- a ```sql fence under the cursor still wins (notebook mode)
  local lines = { "# notes", "```sql", "SELECT 1", "```", "", "```sql", "SELECT 2", "```" }
  local b, w = buf_with_cursor(lines, 3)
  eq(qp._pad_sql_to_run(b), "SELECT 1", "pad_sql_to_run: markdown fence takes priority")
  close_win(w)
end

do
  -- hint-only buffer → nil
  local lines = { "-- C-CR:run block or buffer", "" }
  local b, w = buf_with_cursor(lines, 1)
  eq(qp._pad_sql_to_run(b), nil, "pad_sql_to_run: no real SQL returns nil")
  close_win(w)
end

-- ── key hint is virtual text, only while the pad is empty ────────────────────

do
  local b = make_pad()
  local function hints()
    return vim.api.nvim_buf_get_extmarks(b, qp._hint_ns, 0, -1, { details = true })
  end
  set_lines(b, { "" })
  qp._refresh_hint(b)
  local marks = hints()
  eq(#marks, 1, "hint: shown on an empty pad")
  eq(marks[1][4].virt_text[1][1]:match(":run block or buffer") ~= nil, true,
    "hint: virtual text names the run key")
  eq(table.concat(get_lines(b), "\n"), "", "hint: not written into the buffer")
  set_lines(b, { "SELECT 1" })
  qp._refresh_hint(b)
  eq(#hints(), 0, "hint: cleared once the pad has text")
  set_lines(b, { "", "  " })
  qp._refresh_hint(b)
  eq(#hints(), 1, "hint: back when the pad is blank again")
end

-- ── syntax: formatter words are highlighted under regex SQL syntax ───────────

do
  vim.cmd("syntax on")
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "declare @n NVarChar(50) = IsNull(x, 0)" })
  vim.api.nvim_buf_call(b, function() vim.bo.filetype = "sql" end)
  qp._add_syntax_words(b)
  local function grp(col)
    return vim.api.nvim_buf_call(b, function()
      return vim.fn.synIDattr(vim.fn.synID(1, col, 1), "name")
    end)
  end
  eq(grp(1), "sqlStatement", "syntax: declare is a statement")
  eq(grp(12), "sqlType", "syntax: NVarChar is a type, any case")
  eq(grp(27), "sqlFunction", "syntax: IsNull is a function, any case")
  pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- ── quitting Neovim never asks to save the pad ──────────────────────────────

do
  local b = make_pad()
  set_lines(b, { "SELECT 1" })
  vim.bo[b].modified = true
  vim.api.nvim_exec_autocmds("ExitPre", {})
  eq(vim.bo[b].modified, false, "ExitPre clears the pad's modified flag")
end

print(string.format("\nquery_pad_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
