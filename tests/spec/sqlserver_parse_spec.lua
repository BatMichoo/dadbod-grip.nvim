-- sqlserver_parse_spec.lua: sqlcmd -W -s "\t" output into columns and rows.

local ss = require("dadbod-grip.adapters.sqlserver")
local parse = ss._parse_sqlcmd_table

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  assert(vim.deep_equal(a, b), (msg or "") .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end

test("plain table", function()
  local r = parse("id\tname\n--\t----\n1\talice\n2\tbob\n")
  eq(r.columns, { "id", "name" })
  eq(r.rows, { { "1", "alice" }, { "2", "bob" } })
end)

test("NULL becomes empty, leading spaces are kept", function()
  local r = parse("a\tb\n-\t-\nNULL\t  x\n")
  eq(r.rows, { { "", "  x" } })
end)

test("a value with newlines stays one row", function()
  local r = parse("id\tnote\tn\n--\t----\t-\n1\tline one\n\nline three\t5\n2\tok\t6\n")
  eq(r.rows, { { "1", "line one\n\nline three", "5" }, { "2", "ok", "6" } })
end)

test("a row of dashes is data, not a separator", function()
  local r = parse("a\tb\n-\t-\n-\t--\n1\t2\n")
  eq(r.rows, { { "-", "--" }, { "1", "2" } })
end)

test("empty result keeps its columns", function()
  local r = parse("id\tname\n--\t----\n\n")
  eq(r.columns, { "id", "name" })
  eq(r.rows, {})
end)

test("only the first result set is read", function()
  local r = parse("a\tb\n-\t-\n1\t2\n\nc\n-\n3\n")
  eq(r.columns, { "a", "b" })
  eq(r.rows, { { "1", "2" } })
end)

test("single column: empty string row and trailing blank", function()
  local r = parse("v\n-\nx\n\ny\n\n")
  eq(r.rows, { { "x" }, { "" }, { "y" } })
end)

test("CRLF output", function()
  local r = parse("a\tb\r\n-\t-\r\n1\t2\r\n")
  eq(r.rows, { { "1", "2" } })
end)

test("rows-affected line ends the rows", function()
  local r = parse("a\tb\n-\t-\n1\t2\n\n(1 row affected)\n")
  eq(r.rows, { { "1", "2" } })
end)

-- ── sorting/filtering a raw query: the _grip subquery ──────────────────────
local wrap = ss._normalize_wrapped
local q = require("dadbod-grip.query")

local function sorted(raw)
  return q.build_sql(q.toggle_sort(q.new_raw(raw), "id"))
end

test("inner ORDER BY gets OFFSET 0 ROWS", function()
  eq(wrap(sorted("SELECT id FROM t ORDER BY name")),
    'SELECT * FROM (SELECT id FROM t ORDER BY name\nOFFSET 0 ROWS) AS _grip ORDER BY "id" ASC')
end)

test("ORDER BY inside a subquery or string is not top-level", function()
  local raw = "SELECT id, (SELECT TOP 1 x FROM u ORDER BY x) AS y FROM t WHERE n = 'order by'"
  eq(wrap(sorted(raw)), sorted(raw))
end)

test("TOP and OFFSET queries are left alone", function()
  eq(wrap(sorted("SELECT TOP 5 id FROM t ORDER BY id")), sorted("SELECT TOP 5 id FROM t ORDER BY id"))
  local off = "SELECT id FROM t ORDER BY id OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY"
  eq(wrap(sorted(off)), sorted(off))
end)

test("a CTE moves in front of the wrapper", function()
  eq(wrap(sorted("WITH a AS (SELECT 1 AS id) SELECT id FROM a")),
    'WITH a AS (SELECT 1 AS id) SELECT * FROM (SELECT id FROM a) AS _grip ORDER BY "id" ASC')
end)

test("a trailing -- comment does not swallow the closing parenthesis", function()
  eq(sorted("SELECT id FROM t -- note"),
    'SELECT * FROM (SELECT id FROM t -- note\n) AS _grip ORDER BY "id" ASC')
end)

test("plain queries pass through", function()
  eq(wrap("SELECT * FROM t"), "SELECT * FROM t")
end)

print(string.format("\nsqlserver_parse_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
