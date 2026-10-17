-- pad_statement_spec.lua: what grip.open runs for text from the query pad.
-- A statement led by a comment, or one that is not SELECT/DML/DDL (EXEC,
-- DECLARE, ...), runs as written; only a bare name opens a table.
-- Uses tests/seed_sqlite.db.

local grip = require("dadbod-grip")
local db = require("dadbod-grip.db")
local view = require("dadbod-grip.view")

local url = "sqlite:tests/seed_sqlite.db"
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local function ran(text)
  local seen = {}
  local real_query, real_notify = db.query, vim.notify
  db.query = function(sql, u) seen[#seen + 1] = sql; return real_query(sql, u) end
  vim.notify = function() end
  local ok, err = pcall(grip.open, text, url, { from_pad = true })
  db.query, vim.notify = real_query, real_notify
  for bufnr in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  assert(ok, err)
  return seen[1]
end

test("a comment before SELECT runs the SELECT as written", function()
  local q = "-- note\nSELECT * FROM users"
  assert(ran(q) == q, "got " .. tostring(ran(q)))
  local b = "/* x */ SELECT 1 AS a"
  assert(ran(b) == b, "block comment")
end)

test("other statements run as written, not as a table name", function()
  local q = "DECLARE @x int = 1; SELECT @x"
  assert(ran(q) == q, "got " .. tostring(ran(q)))
end)

test("a bare name still opens the table", function()
  local sql = ran("users")
  assert(sql and sql:match('^SELECT %* FROM "users"'), "got " .. tostring(sql))
end)

print(string.format("\npad_statement_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
