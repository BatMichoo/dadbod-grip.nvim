-- format_spec.lua: unit tests for the pure Lua SQL formatter.
-- All tests call M._format_lua directly; no external tools required.

local fmt = require("dadbod-grip.format")
local f   = fmt._format_lua

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

local function has(s, pat, plain)
  if plain then
    assert(s:find(pat, 1, true), "expected to find literal: " .. pat .. "\nin:\n" .. s)
  else
    assert(s:match(pat), "expected to match pattern: " .. pat .. "\nin:\n" .. s)
  end
end

local function hasnt(s, pat)
  assert(not s:match(pat), "expected NOT to match pattern: " .. pat .. "\nin:\n" .. s)
end

local function count_matches(s, pat)
  local _, n = s:gsub(pat, "")
  return n
end

-- ── Basic keyword uppercasing and clause layout ────────────────────────────

test("uppercases SELECT and puts FROM on a new line", function()
  local out = f("select id, name from users")
  has(out, "SELECT")
  has(out, "\nFROM")
end)

test("indents SELECT columns with 2-space prefix after comma", function()
  local out = f("select id, name, email from users")
  has(out, ",\n  ")
  has(out, "SELECT")
  has(out, "\nFROM")
end)

test("puts WHERE on a new line", function()
  local out = f("select * from users where active = 1")
  has(out, "\nWHERE")
end)

test("indents AND in WHERE clause on new line", function()
  local out = f("select * from u where a=1 and b=2")
  has(out, "\n  AND")
end)

test("indents OR in WHERE clause on new line", function()
  local out = f("select * from u where a=1 or b=2")
  has(out, "\n  OR")
end)

-- ── DECLARE and data type names ────────────────────────────────────────────

test("uppercases lowercase DECLARE and type names", function()
  local out = f("declare @n int = 1; declare @s nvarchar(50)")
  has(out, "DECLARE @n INT", true)
  has(out, "DECLARE @s NVARCHAR(50)", true)
end)

test("variables stay one token", function()
  local out = f("select @@rowcount, @id where col @> '{1}'")
  has(out, "@@rowcount", true)
  has(out, "@id", true)
  has(out, "@>", true)
  hasnt(out, "@ ")
end)

test("type names keep their argument list attached", function()
  local out = f("select cast(x as decimal(10, 2)), cast(y as varchar(max)) from t")
  has(out, "DECIMAL(10, 2)", true)
  has(out, "VARCHAR(max)", true)
  hasnt(out, "DECIMAL %(")
end)

test("uppercases multi-word types", function()
  local out = f("select cast(ts as timestamp with time zone), cast(d as double precision) from t")
  has(out, "TIMESTAMP WITH TIME ZONE", true)
  has(out, "DOUBLE PRECISION", true)
end)

-- ── String literals: keywords inside must NOT trigger newlines ─────────────

test("does not split on FROM inside a string literal", function()
  local out = f("select * from u where x = 'hello from world'")
  has(out, "'hello from world'", true)
  -- The real FROM gets exactly one clause newline
  assert(count_matches(out, "\nFROM") == 1, "expected exactly 1 newline-FROM, got:\n" .. out)
end)

test("does not uppercase keywords inside string literal", function()
  local out = f("select 'select from where' as x from t")
  has(out, "'select from where'", true)
end)

-- ── Double-quoted identifiers ──────────────────────────────────────────────

test("does not uppercase keyword inside double-quoted identifier", function()
  local out = f('select "FROM" as col from users')
  has(out, '"FROM"', true)
  has(out, "\nFROM")
end)

test("preserves double-quoted identifier with spaces", function()
  local out = f('select "my column" from t')
  has(out, '"my column"', true)
end)

-- ── Line comments ──────────────────────────────────────────────────────────

test("preserves line comments verbatim", function()
  local out = f("-- this is a comment\nselect 1")
  has(out, "-- this is a comment", true)
end)

test("does not uppercase keywords inside line comments", function()
  local out = f("-- select from where\nselect 1")
  has(out, "-- select from where", true)
end)

-- ── Block comments ─────────────────────────────────────────────────────────

test("preserves block comments and does not treat inner FROM as clause", function()
  local out = f("select /* from here */ id from t")
  has(out, "/* from here */", true)
  assert(count_matches(out, "\nFROM") == 1, "expected exactly 1 newline-FROM, got:\n" .. out)
end)

-- ── Dollar-quoted strings (PostgreSQL) ────────────────────────────────────

test("preserves dollar-quoted string content", function()
  local out = f("select * from t where body = $$hello FROM world$$")
  has(out, "$$hello FROM world$$", true)
  has(out, "\nFROM")
end)

test("preserves tagged dollar-quoted string", function()
  local out = f("select $func$SELECT 1$func$ as x from t")
  has(out, "$func$SELECT 1$func$", true)
end)

-- ── Parenthesis depth: keywords inside parens are NOT clause-level ─────────

test("does not add newline before FROM inside a subquery", function()
  local out = f("select * from (select id from t where active = 1) s")
  -- Only the outer FROM gets a newline
  assert(count_matches(out, "\nFROM") == 1, "expected exactly 1 newline-FROM, got:\n" .. out)
end)

test("does not add newline before WHERE inside a subquery", function()
  local out = f("select * from (select id from t where id > 1) s where s.id < 100")
  assert(count_matches(out, "\nWHERE") == 1, "expected exactly 1 newline-WHERE, got:\n" .. out)
end)

test("does not add newline before ORDER BY inside OVER window", function()
  local out = f("select sum(x) over (partition by y order by z) from t")
  has(out, "\nFROM")
  -- ORDER BY inside OVER should not start with a newline
  hasnt(out, "\nORDER BY z")
end)

test("does not add newline before FROM inside IN subquery", function()
  local out = f("select * from t where id in (select id from t2)")
  assert(count_matches(out, "\nFROM") == 1, "expected exactly 1 newline-FROM, got:\n" .. out)
end)

-- ── CTE (Common Table Expressions) ────────────────────────────────────────

test("puts WITH as first keyword (no leading newline)", function()
  local out = f("with cte as (select id from t) select * from cte")
  has(out, "^WITH")
  has(out, "\nSELECT")
  has(out, "\nFROM")
end)

test("CTE body inner keywords stay inline (not top-level clauses)", function()
  local out = f("with cte as (select id from t where id > 0) select * from cte")
  -- Only the main query FROM (at depth 0) gets a clause newline
  assert(count_matches(out, "\nFROM") == 1, "expected exactly 1 newline-FROM, got:\n" .. out)
end)

test("multiple CTEs separated with comma-newline-indent", function()
  local out = f("with a as (select 1), b as (select 2) select * from a, b")
  has(out, ",\n  b")
end)

-- ── Multi-word clause keywords ─────────────────────────────────────────────

test("puts GROUP BY on its own line", function()
  local out = f("select x, count(*) from t group by x")
  has(out, "\nGROUP BY")
end)

test("puts ORDER BY on its own line", function()
  local out = f("select * from t order by id desc")
  has(out, "\nORDER BY")
end)

test("puts INNER JOIN on its own line", function()
  local out = f("select * from a inner join b on a.id = b.a_id")
  has(out, "\nINNER JOIN")
end)

test("puts LEFT JOIN on its own line", function()
  local out = f("select * from a left join b on a.id = b.a_id")
  has(out, "\nLEFT JOIN")
end)

test("puts LEFT OUTER JOIN on its own line", function()
  local out = f("select * from a left outer join b on a.id = b.a_id")
  has(out, "\nLEFT OUTER JOIN")
end)

test("puts RIGHT OUTER JOIN on its own line", function()
  local out = f("select * from a right outer join b on a.id = b.a_id")
  has(out, "\nRIGHT OUTER JOIN")
end)

-- ── DuckDB federation: dot notation must survive ───────────────────────────

test("preserves schema.table dot notation without spaces", function()
  local out = f("select * from memory.main.users")
  has(out, "memory.main.users", true)
end)

test("preserves double-quoted federated table name", function()
  local out = f('select * from "attached_db"."main"."orders"')
  has(out, '"attached_db"."main"."orders"', true)
end)

-- ── UNION / INTERSECT / EXCEPT ────────────────────────────────────────────

test("puts UNION on its own line", function()
  local out = f("select 1 union select 2")
  has(out, "\nUNION")
end)

test("puts UNION ALL on its own line", function()
  local out = f("select 1 union all select 2")
  has(out, "\nUNION ALL")
end)

test("puts EXCEPT on its own line", function()
  local out = f("select 1 except select 2")
  has(out, "\nEXCEPT")
end)

-- ── DML statements ────────────────────────────────────────────────────────

test("preserves INSERT INTO structure", function()
  local out = f("insert into users (name, email) values ('alice', 'a@example.com')")
  has(out, "INSERT INTO", true)
  has(out, "VALUES", true)
end)

test("preserves UPDATE SET structure", function()
  local out = f("update users set name = 'bob' where id = 1")
  has(out, "UPDATE", true)
  has(out, "SET", true)
  has(out, "\nWHERE")
end)

test("preserves DELETE FROM structure without extra newline inside", function()
  local out = f("delete from users where id = 1")
  has(out, "DELETE FROM", true)
  has(out, "\nWHERE")
end)

-- ── Multi-statement ────────────────────────────────────────────────────────

test("handles semicolon-separated statements", function()
  local out = f("select 1; select 2")
  has(out, ";", true)
  assert(count_matches(out, "SELECT") == 2, "expected 2 SELECT keywords, got:\n" .. out)
end)

-- ── DuckDB-specific and additional clauses ────────────────────────────────

test("uppercases HAVING and puts it on its own line", function()
  local out = f("select x, count(*) from t group by x having count(*) > 1")
  has(out, "\nHAVING")
end)

test("uppercases LIMIT and OFFSET on their own lines", function()
  local out = f("select * from t limit 10 offset 20")
  has(out, "\nLIMIT")
  has(out, "\nOFFSET")
end)

test("uppercases QUALIFY (DuckDB-specific keyword)", function()
  local out = f("select * from t qualify row_number() over (order by id) = 1")
  has(out, "\nQUALIFY")
end)

-- ── Edge cases ────────────────────────────────────────────────────────────

test("returns empty string for empty input", function()
  assert(f("") == "", "empty string should return empty string")
  assert(f("   ") == "", "whitespace-only should return empty string")
  assert(f("\n\t\n") == "", "newlines-only should return empty string")
end)

test("does not crash on nil input", function()
  assert(f(nil) == "", "nil should return empty string")
end)

test("handles SELECT * without columns to indent", function()
  local out = f("select * from t")
  has(out, "SELECT", true)
  has(out, "*", true)
  has(out, "\nFROM")
end)

test("no leading newline on first keyword", function()
  local out = f("select 1")
  assert(not out:match("^\n"), "should not start with newline, got:\n" .. out)
end)

-- ── Multi-char operators are never split ───────────────────────────────────
-- Regression: the three-char branch used to sit *below* the two-char branch,
-- so "->>" tokenized as "->" + ">" and came out as "-> >". Several two-char
-- PostgreSQL operators were missing from the list entirely.

local function keeps_operator(op, sql)
  test("keeps " .. op .. " intact", function()
    local out = f(sql)
    has(out, op, true)
    -- No space inserted inside the operator itself.
    for k = 1, #op - 1 do
      hasnt(out, vim.pesc(op:sub(1, k)) .. "%s+" .. vim.pesc(op:sub(k + 1)))
    end
  end)
end

keeps_operator("->>", "select data ->> 'name' from t")
keeps_operator("#>>", "select data #>> '{a,b}' from t")
keeps_operator("->",  "select data -> 'k' from t")
keeps_operator("#>",  "select data #> '{a}' from t")
keeps_operator("@>",  "select * from t where a @> b")
keeps_operator("<@",  "select * from t where a <@ b")
keeps_operator("&&",  "select * from t where tags && ARRAY['a']")
keeps_operator("<<",  "select * from t where ip << '10.0.0.0/8'")
keeps_operator(">>",  "select * from t where net >> ip")
keeps_operator("@@",  "select * from t where tsv @@ q")
keeps_operator("!~",  "select * from t where a !~ 'x'")
keeps_operator("~*",  "select * from t where a ~* 'x'")
keeps_operator("!~*", "select * from t where a !~* 'x'")
keeps_operator("<=>", "select * from t where a <=> b")
keeps_operator("::",  "select id::text from t")
keeps_operator("!=",  "select * from t where a != b")
keeps_operator("<>",  "select * from t where a <> b")
keeps_operator("<=",  "select * from t where a <= b")
keeps_operator(">=",  "select * from t where a >= b")
keeps_operator("||",  "select a || b from t")

test("chained jsonb path operators survive", function()
  local out = f("select payload -> 'user' ->> 'email' from events")
  has(out, "-> 'user' ->> 'email'", true)
end)

-- ── summary ──────────────────────────────────────────────────────────────

print(string.format("format_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
