-- adapter_spec.lua: unit tests for adapter URL parsing, output parsing, SQL rewriting
local mysql = require("dadbod-grip.adapters.mysql")
local sqlite = require("dadbod-grip.adapters.sqlite")
local duckdb = require("dadbod-grip.adapters.duckdb")
local pg = require("dadbod-grip.adapters.postgresql")
local adapters = require("dadbod-grip.adapters")
local sqlserver = require("dadbod-grip.adapters.sqlserver")

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

local function contains(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. pattern .. "'")
end

local function has_arg(args, flag, msg)
  for _, a in ipairs(args) do
    if a == flag then return end
  end
  error((msg or "") .. ": expected args to contain '" .. flag .. "'")
end

local function last_arg(args)
  return args._stdin or args[#args]
end

-- ── mock helpers ──────────────────────────────────────────────────────────────

local function with_system_mock(stdout, stderr, code, fn)
  local orig = vim.system
  vim.system = function(_args, _opts, cb)
    local r = { stdout = stdout, stderr = stderr or "", code = code or 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
end

local function capture_system_args(stdout, fn)
  local captured
  local orig = vim.system
  vim.system = function(args, opts, cb)
    captured = args
    captured._stdin = opts and opts.stdin
    local r = { stdout = stdout or "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
  return captured
end

--- Same as capture_system_args but also returns the opts vim.system was
--- called with, so a test can inspect opts.env (e.g. a password delivered
--- via the environment instead of argv).
local function capture_system_call(stdout, fn)
  local captured_args, captured_opts, call_count = nil, nil, 0
  local orig = vim.system
  vim.system = function(args, opts, cb)
    call_count = call_count + 1
    captured_args = args
    captured_opts = opts
    local r = { stdout = stdout or "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
  return captured_args, captured_opts, call_count
end

local function with_executable(fn)
  local orig = vim.fn.executable
  vim.fn.executable = function() return 1 end
  local ok, err = pcall(fn)
  vim.fn.executable = orig
  if not ok then error(err) end
end

-- ── MySQL parse_url ──────────────────────────────────────────────────────────

test("mysql parse_url: full URL parses all fields", function()
  local r = mysql._parse_url("mysql://alice:secret@db.host:3307/mydb")
  eq(r.user, "alice", "user")
  eq(r.pass, "secret", "pass")
  eq(r.host, "db.host", "host")
  eq(r.port, "3307", "port")
  eq(r.dbname, "mydb", "dbname")
end)

test("mysql parse_url: URL without port defaults to 3306", function()
  local r = mysql._parse_url("mysql://user:pass@host/db")
  eq(r.port, "3306", "port")
  eq(r.host, "host", "host")
end)

test("mysql parse_url: URL without auth", function()
  local r = mysql._parse_url("mysql://localhost:3306/mydb")
  eq(r.user, nil, "user")
  eq(r.pass, nil, "pass")
  eq(r.host, "localhost", "host")
  eq(r.dbname, "mydb", "dbname")
end)

test("mysql parse_url: @ in password uses last-@ rule", function()
  local r = mysql._parse_url("mysql://user:p@ss@host/db")
  eq(r.user, "user", "user")
  eq(r.pass, "p@ss", "pass")
  eq(r.host, "host", "host")
  eq(r.dbname, "db", "dbname")
end)

test("mysql parse_url: URL without dbname", function()
  local r = mysql._parse_url("mysql://user:pass@host:3306")
  eq(r.dbname, nil, "dbname should be nil")
  eq(r.host, "host", "host")
end)

test("mysql parse_url: mariadb scheme", function()
  local r = mysql._parse_url("mariadb://user:pass@host/db")
  eq(r.user, "user", "user")
  eq(r.dbname, "db", "dbname")
end)

test("mysql parse_url: empty string returns nil", function()
  local r = mysql._parse_url("")
  eq(r, nil, "empty")
end)

test("mysql parse_url: malformed returns nil", function()
  local r = mysql._parse_url("just-a-host")
  eq(r, nil, "malformed")
end)

-- ── SQLite extract_path ──────────────────────────────────────────────────────

test("sqlite extract_path: relative path", function()
  eq(sqlite._extract_path("sqlite:relative/path.db"), "relative/path.db")
end)

test("sqlite extract_path: absolute path", function()
  eq(sqlite._extract_path("sqlite:/absolute/path.db"), "/absolute/path.db")
end)

test("sqlite extract_path: triple-slash absolute", function()
  eq(sqlite._extract_path("sqlite:///absolute/path.db"), "/absolute/path.db")
end)

test("sqlite extract_path: tilde expansion", function()
  local home = os.getenv("HOME") or ""
  eq(sqlite._extract_path("sqlite:~/test.db"), home .. "/test.db")
end)

test("sqlite extract_path: bare sqlite: returns nil", function()
  eq(sqlite._extract_path("sqlite:"), nil)
end)

test("sqlite extract_path: non-sqlite scheme returns nil", function()
  eq(sqlite._extract_path("postgres://localhost/db"), nil)
end)

-- ── DuckDB extract_path ──────────────────────────────────────────────────────

test("duckdb extract_path: relative path", function()
  eq(duckdb._extract_path("duckdb:path.db"), "path.db")
end)

test("duckdb extract_path: absolute path", function()
  eq(duckdb._extract_path("duckdb:/absolute.db"), "/absolute.db")
end)

test("duckdb extract_path: triple-slash absolute", function()
  eq(duckdb._extract_path("duckdb:///absolute"), "/absolute")
end)

test("duckdb extract_path: memory returns :memory:", function()
  eq(duckdb._extract_path("duckdb::memory:"), ":memory:")
end)

test("duckdb extract_path: bare duckdb: returns :memory:", function()
  eq(duckdb._extract_path("duckdb:"), ":memory:")
end)

-- ── PostgreSQL affected-row parsing ──────────────────────────────────────────

test("pg execute: UPDATE 5 parses affected rows", function()
  with_executable(function()
    with_system_mock("UPDATE 5\n", "", 0, function()
      local result, err = pg.execute("UPDATE users SET x=1", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 5, "affected")
    end)
  end)
end)

test("pg execute: INSERT 0 1 parses affected rows", function()
  with_executable(function()
    with_system_mock("INSERT 0 1\n", "", 0, function()
      local result, err = pg.execute("INSERT INTO t VALUES (1)", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 1, "affected")
    end)
  end)
end)

test("pg execute: DELETE 3 parses affected rows", function()
  with_executable(function()
    with_system_mock("DELETE 3\n", "", 0, function()
      local result, err = pg.execute("DELETE FROM t WHERE x=1", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
    end)
  end)
end)

test("pg execute: empty stdout parses as 0 affected", function()
  with_executable(function()
    with_system_mock("", "", 0, function()
      local result, err = pg.execute("DO $$ BEGIN END $$", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 0, "affected")
    end)
  end)
end)

-- ── PostgreSQL .psqlrc bypass ────────────────────────────────────────────

test("pg query: passes -X to skip .psqlrc", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      pg.query("SELECT 1", "postgresql://localhost/db")
    end)
    has_arg(args, "-X", "query should pass -X")
  end)
end)

test("pg query: stdin errors stop psql with a nonzero exit", function()
  with_executable(function()
    local args = capture_system_args("", function()
      pg.query("SELECT * FROM missing_table", "postgresql://localhost/db")
    end)
    has_arg(args, "--set=ON_ERROR_STOP=1", "stdin errors must preserve -c exit behavior")
  end)
end)

test("pg ping: passes -X to skip .psqlrc", function()
  with_executable(function()
    local args = capture_system_args("", function()
      pg.ping("postgresql://localhost/db")
    end)
    has_arg(args, "-X", "ping should pass -X")
  end)
end)

-- ── PostgreSQL routines ─────────────────────────────────────────────────

test("pg list_routines: queries pg_proc and parses functions/procedures", function()
  with_executable(function()
    local csv = table.concat({
      "source_id,schema,name,identity_arguments,kind",
      "12345,public,user_display_name,user_id integer,function",
      "23456,admin,audit_touch,,procedure",
      "",
    }, "\n")
    local args = capture_system_args(csv, function()
      local routines, err = pg.list_routines("postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(#routines, 2, "routine count")
      eq(routines[1].name, "user_display_name", "public routine name is bare")
      eq(routines[1].display, "user_display_name(user_id integer)", "function display")
      eq(routines[1].type, "function", "function type")
      eq(routines[1].source_id, "12345", "function source id")
      eq(routines[2].name, "admin.audit_touch", "non-public routine is schema-qualified")
      eq(routines[2].display, "admin.audit_touch()", "procedure display")
      eq(routines[2].type, "procedure", "procedure type")
    end)
    local sql_arg = last_arg(args)
    contains(sql_arg, "pg_proc", "routine list queries pg_proc")
    contains(sql_arg, "pg_namespace", "routine list queries schemas")
  end)
end)

test("pg get_routine_source: can select exact routine by oid source id", function()
  with_executable(function()
    local csv = "source\n\"CREATE OR REPLACE FUNCTION overloaded(value text)\nRETURNS text\nLANGUAGE sql\nAS $$ SELECT value; $$\"\n"
    local source, err
    local args = capture_system_args(csv, function()
      source, err = pg.get_routine_source("98765", "postgresql://localhost/db")
    end)
    assert(not err, "should not error: " .. tostring(err))
    contains(source, "overloaded(value text)", "source contains selected overload")
    local sql_arg = last_arg(args)
    contains(sql_arg, "p.oid = 98765::oid", "source query filters by oid")
  end)
end)

test("pg get_routine_source: uses pg_get_functiondef and preserves source text", function()
  with_executable(function()
    local csv = "source\n\"CREATE OR REPLACE FUNCTION user_display_name(user_id integer)\nRETURNS text\nLANGUAGE sql\nAS $$ SELECT 'user'; $$\"\n"
    local source, err
    local args = capture_system_args(csv, function()
      source, err = pg.get_routine_source("user_display_name", "postgresql://localhost/db")
    end)
    assert(not err, "should not error: " .. tostring(err))
    contains(source, "CREATE OR REPLACE FUNCTION", "source contains function DDL")
    contains(source, "RETURNS text", "source preserves multiline body")
    local sql_arg = last_arg(args)
    contains(sql_arg, "pg_get_functiondef", "source query uses pg_get_functiondef")
    contains(sql_arg, "user_display_name", "source query filters by routine")
  end)
end)

test("pg list_routines: strips bare IN mode from procedure arguments", function()
  with_executable(function()
    local csv = table.concat({
      "source_id,schema,name,identity_arguments,kind",
      '23456,public,mark_order_status,"IN order_id integer, IN new_status text",procedure',
      '34567,public,swap_vals,"INOUT a integer, INOUT b integer",procedure',
      "",
    }, "\n")
    capture_system_args(csv, function()
      local routines, err = pg.list_routines("postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(routines[1].display, "mark_order_status(order_id integer, new_status text)",
        "IN mode stripped for display parity with functions")
      eq(routines[1].arguments, "order_id integer, new_status text", "arguments field cleaned")
      eq(routines[2].display, "swap_vals(INOUT a integer, INOUT b integer)",
        "INOUT mode is meaningful and kept")
    end)
  end)
end)

-- ── PostgreSQL EXPLAIN safety ────────────────────────────────────────────
-- ANALYZE executes the statement; it must only be added for read-only SQL.

test("pg explain: SELECT uses ANALYZE for actual timings", function()
  with_executable(function()
    local args = capture_system_args("QUERY PLAN\nSeq Scan\n", function()
      pg.explain("SELECT * FROM users", "postgresql://localhost/db")
    end)
    contains(last_arg(args), "EXPLAIN (FORMAT TEXT, ANALYZE) SELECT", "SELECT gets ANALYZE")
  end)
end)

test("pg explain: UPDATE/DELETE/INSERT never use ANALYZE (would execute the DML)", function()
  with_executable(function()
    for _, stmt in ipairs({
      "UPDATE users SET age = 1 WHERE id = 1",
      "DELETE FROM users WHERE id = 1",
      "INSERT INTO users (name) VALUES ('x')",
    }) do
      local args = capture_system_args("QUERY PLAN\nSeq Scan\n", function()
        pg.explain(stmt, "postgresql://localhost/db")
      end)
      local sql_arg = last_arg(args)
      assert(not sql_arg:find("ANALYZE", 1, true),
        "no ANALYZE for: " .. stmt .. " (got: " .. sql_arg .. ")")
      contains(sql_arg, "EXPLAIN (FORMAT TEXT) ", "plain EXPLAIN used")
    end
  end)
end)

test("pg explain: WITH gets plain EXPLAIN (may contain data-modifying CTEs)", function()
  with_executable(function()
    local args = capture_system_args("QUERY PLAN\nSeq Scan\n", function()
      pg.explain("WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone",
        "postgresql://localhost/db")
    end)
    assert(not last_arg(args):find("ANALYZE", 1, true), "no ANALYZE for WITH")
  end)
end)

-- ── SQLite .sqliterc bypass ─────────────────────────────────────────────

test("sqlite query: uses the null device to skip .sqliterc", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      sqlite.query("SELECT 1", "sqlite:test.db")
    end)
    for i, arg in ipairs(args) do
      if arg == "-init" then
        eq(args[i + 1], vim.fn.has("win32") == 1 and "NUL" or "/dev/null", "empty init file")
        return
      end
    end
    error("query should pass -init")
  end)
end)

test("sqlite stops at the first failed statement so transactions roll back", function()
  with_executable(function()
    local args = capture_system_args("", function()
      sqlite.execute("BEGIN; SELECT 1; COMMIT;", "sqlite:test.db")
    end)
    has_arg(args, "-bail", "sqlite should stop before COMMIT after an error")
  end)
end)

-- ── SQL Server adapter ───────────────────────────────────────────────────

test("adapter registry resolves sqlserver and mssql URLs", function()
  local a1, err1 = adapters.resolve("sqlserver://sa:pw@localhost:1433/grip_test")
  assert(a1 == sqlserver, "sqlserver adapter mismatch: " .. tostring(err1))
  local a2, err2 = adapters.resolve("mssql://sa:pw@localhost/grip_test")
  assert(a2 == sqlserver, "mssql adapter mismatch: " .. tostring(err2))
end)

test("sqlserver parse_url: full URL parses all fields", function()
  local r = sqlserver._parse_url("sqlserver://sa:secret@db.host:14330/grip_test")
  eq(r.user, "sa", "user")
  eq(r.pass, "secret", "pass")
  eq(r.host, "db.host", "host")
  eq(r.port, "14330", "port")
  eq(r.dbname, "grip_test", "dbname")
  eq(r.encrypt, "mandatory", "certificate-validating encryption is the default")
end)

test("sqlserver TLS URL options map to sqlcmd for both schemes", function()
  for _, scheme in ipairs({ "sqlserver", "mssql" }) do
    local parsed = assert(sqlserver._parse_url(scheme
      .. "://sa:secret@db.host:1433/grip_test?encrypt=strict&server_certificate=%2Ftmp%2Fdb+cert.pem"))
    eq(parsed.dbname, "grip_test", scheme .. " dbname excludes query")
    eq(parsed.encrypt, "strict", scheme .. " strict parsed")
    eq(parsed.server_certificate, "/tmp/db cert.pem", scheme .. " certificate decoded")
    local args = sqlserver._sqlcmd_args(parsed, "SELECT 1")
    has_arg(args, "-Ns", scheme .. " strict encryption")
    has_arg(args, "-J", scheme .. " certificate pinning")
    has_arg(args, "/tmp/db cert.pem", scheme .. " certificate path")
  end
end)

test("sqlserver TLS defaults to validation and allows explicit local trust", function()
  local secure = assert(sqlserver._parse_url("sqlserver://sa:pw@db/app"))
  has_arg(sqlserver._sqlcmd_args(secure, "SELECT 1"), "-Nm", "secure default")

  local local_dev = assert(sqlserver._parse_url(
    "sqlserver://sa:pw@localhost/app?encrypt=optional&trust_server_certificate=true"))
  local args = sqlserver._sqlcmd_args(local_dev, "SELECT 1")
  has_arg(args, "-No", "optional encryption")
  has_arg(args, "-C", "explicit certificate bypass")
end)

test("sqlserver_max_type_width maps to -y only for go-sqlcmd", function()
  local grip = require("dadbod-grip")
  local parsed = assert(sqlserver._parse_url("sqlserver://sa:pw@db/app"))
  local function y_value(args)
    for i, a in ipairs(args) do
      if a == "-y" then return args[i + 1] end
    end
  end

  sqlserver._set_go_sqlcmd(true)
  grip.setup({})
  eq(y_value(sqlserver._sqlcmd_args(parsed, "SELECT 1")), nil, "off by default")

  grip.setup({ sqlserver_max_type_width = 0 })
  local args = sqlserver._sqlcmd_args(parsed, "SELECT 1")
  eq(y_value(args), "0", "0 means unlimited")
  has_arg(args, "-W", "-W kept alongside -y")

  sqlserver._set_go_sqlcmd(false)
  eq(y_value(sqlserver._sqlcmd_args(parsed, "SELECT 1")), nil,
    "mssql-tools sqlcmd rejects -y with -W")

  local ok = pcall(grip.setup, { sqlserver_max_type_width = 9000 })
  assert(not ok, "out-of-range width rejected")

  sqlserver._set_go_sqlcmd(nil)
  grip.setup({})
end)

test("sqlserver stdin terminates the final batch with GO exactly once", function()
  local stdin = sqlserver._sqlcmd_stdin("SELECT 1")
  contains(stdin, "SET NOCOUNT ON;", "session settings kept")
  eq(stdin:sub(-12), "SELECT 1\nGO\n", "unterminated batch gets GO for go-sqlcmd")

  local already = sqlserver._sqlcmd_stdin("SELECT 1\nGO\n")
  local _, count = already:gsub("\nGO\n", "")
  eq(count, 1, "existing trailing GO not doubled")

  local lower = sqlserver._sqlcmd_stdin("SELECT 1\ngo")
  _, count = lower:gsub("\n[Gg][Oo]\n", "")
  eq(count, 1, "lowercase trailing go not doubled")
end)

test("sqlserver authentication URL option maps to --authentication-method", function()
  local parsed = assert(sqlserver._parse_url(
    "sqlserver://db.database.windows.net/app?authentication=ActiveDirectoryDefault"))
  eq(parsed.authentication, "ActiveDirectoryDefault", "method parsed")
  local args = sqlserver._sqlcmd_args(parsed, "SELECT 1")
  has_arg(args, "--authentication-method", "method flag")
  has_arg(args, "ActiveDirectoryDefault", "method value")
  for _, arg in ipairs(args) do
    assert(arg ~= "-E", "integrated auth must not be combined with an authentication method")
  end
  eq(next(sqlserver._sqlcmd_env(parsed)), nil, "no password channel without a user")

  local sp = assert(sqlserver._parse_url(
    "mssql://app-id:secret@db/app?authentication=ActiveDirectoryServicePrincipal"))
  args = sqlserver._sqlcmd_args(sp, "SELECT 1")
  has_arg(args, "-U", "user kept for methods that take one")
  has_arg(args, "ActiveDirectoryServicePrincipal", "method value")
  eq(sqlserver._sqlcmd_env(sp).SQLCMDPASSWORD, "secret", "secret stays in the environment")

  local plain = assert(sqlserver._parse_url("sqlserver://db/app"))
  has_arg(sqlserver._sqlcmd_args(plain, "SELECT 1"), "-E", "integrated auth stays the default")

  local bad, err = sqlserver._parse_url("sqlserver://db/app?authentication=Default%20-Q")
  eq(bad, nil, "non-name method rejected")
  contains(err, "authentication method", "error names the option")
end)

test("sqlserver rejects unsafe or contradictory TLS URL values before spawning", function()
  local parsed, err = sqlserver._parse_url("sqlserver://sa:pw@db/app?encrypt=maybe")
  eq(parsed, nil, "invalid encryption rejected")
  contains(err, "optional, mandatory, or strict", "valid values named")

  parsed, err = sqlserver._parse_url(
    "mssql://sa:pw@db/app?server_certificate=%2Ftmp%2Fdb.pem&trust_server_certificate=true")
  eq(parsed, nil, "pinning and bypass cannot be combined")
  contains(err, "cannot be combined", "conflict explained")
end)

test("sqlserver translates shared LIMIT pagination to OFFSET/FETCH", function()
  eq(sqlserver._normalize_query_sql('SELECT * FROM "orders" LIMIT 25'),
    'SELECT * FROM "orders" ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 25 ROWS ONLY',
    "first page gets a deterministic legal ordering")
  eq(sqlserver._normalize_query_sql(
      'SELECT * FROM "orders" ORDER BY "total" ASC LIMIT 25 OFFSET 50'),
    'SELECT * FROM "orders" ORDER BY "total" ASC OFFSET 50 ROWS FETCH NEXT 25 ROWS ONLY',
    "sort and page offset preserved")
  eq(sqlserver._normalize_query_sql("SELECT TOP 5 * FROM users"),
    "SELECT TOP 5 * FROM users", "native SQL Server query unchanged")
end)

test("sqlserver query: parses sqlcmd tab output", function()
  with_executable(function()
    local out = table.concat({
      "id\tname",
      "--\t----",
      "1\tAlice",
      "2\tNULL",
      "",
      "(2 rows affected)",
      "",
    }, "\n")
    with_system_mock(out, "", 0, function()
      local result, err = sqlserver.query("SELECT id, name FROM users", "sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.columns[1], "id", "first column")
      eq(result.columns[2], "name", "second column")
      eq(result.rows[1][2], "Alice", "first row value")
      eq(result.rows[2][2], "", "NULL becomes empty string")
    end)
  end)
end)

test("sqlserver query: builds sqlcmd args for non-interactive use", function()
  with_executable(function()
    local args, opts = capture_system_call("id\n--\n1\n", function()
      sqlserver.query("SELECT 1", "sqlserver://sa:pw@localhost:1433/grip_test")
    end)
    has_arg(args, "sqlcmd", "uses sqlcmd")
    has_arg(args, "-S", "sets server")
    has_arg(args, "-d", "sets database")
    has_arg(args, "-U", "sets user")
    assert(not vim.tbl_contains(args, "-Q"), "query must not use -Q")
    for _, a in ipairs(args) do
      assert(not tostring(a):find("pw", 1, true), "password in argv: " .. tostring(a))
    end
    eq(opts.env.SQLCMDPASSWORD, "pw", "password delivered via env instead")
    contains(opts.stdin, "SELECT 1", "query delivered via stdin")
  end)
end)

test("sqlserver query: sends one complete multi-batch block in one invocation", function()
  with_executable(function()
    local block = table.concat({
      "CREATE TABLE #grip_scope (id INT NOT NULL);",
      "GO",
      "INSERT INTO #grip_scope VALUES (7);",
      "GO",
      "SELECT id FROM #grip_scope;",
    }, "\n")
    local _, opts, calls = capture_system_call("id\n--\n7\n", function()
      local result, err = sqlserver.query(block, "sqlserver://sa:pw@localhost/grip_test")
      assert(result, err)
    end)
    eq(calls, 1, "one sqlcmd process")
    contains(opts.stdin, block, "complete block delivered through one stdin")
  end)
end)

test("sqlserver list_tables: parses table and view rows", function()
  with_executable(function()
    local out = table.concat({
      "table_name\ttable_type",
      "----------\t----------",
      "users\ttable",
      "no_pk_view\tview",
      "",
    }, "\n")
    with_system_mock(out, "", 0, function()
      local result, err = sqlserver.list_tables("sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(#result, 2, "two objects")
      eq(result[1].name, "users", "table name")
      eq(result[1].type, "table", "table type")
      eq(result[2].type, "view", "view type")
    end)
  end)
end)

test("sqlserver execute: parses affected rows from (N rows affected)", function()
  with_executable(function()
    with_system_mock("\n(3 rows affected)\n", "", 0, function()
      local result, err = sqlserver.execute("UPDATE users SET x=1", "sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
    end)
  end)
end)

test("sqlserver execute: does not send SET NOCOUNT ON (would suppress the row count)", function()
  with_executable(function()
    local args = capture_system_args("\n(1 rows affected)\n", function()
      sqlserver.execute("UPDATE users SET x=1", "sqlserver://sa:pw@localhost/grip_test")
    end)
    local sql_arg = last_arg(args)
    assert(not sql_arg:find("NOCOUNT", 1, true), "execute must not set NOCOUNT: " .. sql_arg)
  end)
end)

test("sqlserver query: still sends SET NOCOUNT ON (keeps row count out of the grid)", function()
  with_executable(function()
    local args = capture_system_args("id\n--\n1\n", function()
      sqlserver.query("SELECT 1", "sqlserver://sa:pw@localhost:1433/grip_test")
    end)
    contains(last_arg(args), "SET NOCOUNT ON", "query must still set NOCOUNT")
  end)
end)

test("sqlserver enables double-quoted identifiers for every command", function()
  with_executable(function()
    local query_args = capture_system_args("id\n--\n1\n", function()
      sqlserver.query('SELECT * FROM "orders"', "sqlserver://sa:pw@localhost/grip_test")
    end)
    contains(last_arg(query_args), "SET QUOTED_IDENTIFIER ON", "query session")

    local exec_args = capture_system_args("\n(1 rows affected)\n", function()
      sqlserver.execute('UPDATE "orders" SET "status" = \'done\' WHERE "id" = 1',
        "sqlserver://sa:pw@localhost/grip_test")
    end)
    contains(last_arg(exec_args), "SET QUOTED_IDENTIFIER ON", "execute session")
  end)
end)

test("sqlserver leaves ordinary user transaction semantics unchanged", function()
  with_executable(function()
    local query_args = capture_system_args("id\n--\n1\n", function()
      sqlserver.query("SELECT 1", "sqlserver://sa:pw@localhost/grip_test")
    end)
    assert(not last_arg(query_args):find("SET XACT_ABORT ON", 1, true),
      "query session must not force XACT_ABORT")

    local exec_args = capture_system_args("\n(1 rows affected)\n", function()
      sqlserver.execute("UPDATE users SET id = id", "sqlserver://sa:pw@localhost/grip_test")
    end)
    assert(not last_arg(exec_args):find("SET XACT_ABORT ON", 1, true),
      "execute session must not force XACT_ABORT")
  end)
end)

test("sqlserver get_primary_keys: parses key columns", function()
  with_executable(function()
    local out = table.concat({
      "column_name",
      "-----------",
      "tenant_id",
      "user_id",
      "",
    }, "\n")
    with_system_mock(out, "", 0, function()
      local result, err = sqlserver.get_primary_keys("composite_pk", "sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(#result, 2, "two primary key columns")
      eq(result[1], "tenant_id", "first pk")
      eq(result[2], "user_id", "second pk")
    end)
  end)
end)

-- ── MySQL DEFAULT VALUES rewriting ───────────────────────────────────────────

test("mysql execute: DEFAULT VALUES is rewritten", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("INSERT INTO t DEFAULT VALUES", "mysql://root@localhost/test")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    contains(sql_arg, "() VALUES ()", "DEFAULT VALUES rewrite")
    assert(not sql_arg:find("DEFAULT VALUES", 1, true), "DEFAULT VALUES should be gone")
  end)
end)

test("mysql execute: non-DEFAULT-VALUES SQL unchanged", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("INSERT INTO t (name) VALUES ('x')", "mysql://root@localhost/test")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    contains(sql_arg, "VALUES ('x')", "SQL unchanged")
  end)
end)

test("mysql execute: appends SELECT ROW_COUNT() after stripping trailing semicolons", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "ROW_COUNT()\n1\n", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("UPDATE t SET x=1;\n", "mysql://root@localhost/test")
    vim.system = orig
    contains(last_arg(captured_args), "UPDATE t SET x=1\n; SELECT ROW_COUNT();",
      "one statement separator, comment-safe newline")
  end)
end)

test("mysql execute: affected row parsing from ROW_COUNT() output", function()
  with_executable(function()
    with_system_mock("ROW_COUNT()\n3\n", "", 0, function()
      local result, err = mysql.execute("UPDATE t SET x=1", "mysql://root@localhost/test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
      eq(result.message, "3 row(s) affected", "message")
    end)
  end)
end)

test("mysql execute: 0 rows affected", function()
  with_executable(function()
    with_system_mock("ROW_COUNT()\n0\n", "", 0, function()
      local result = mysql.execute("UPDATE t SET x=1 WHERE 1=0", "mysql://root@localhost/test")
      eq(result.affected, 0, "affected")
    end)
  end)
end)

test("mysql execute: an earlier result set is not mistaken for the count", function()
  with_executable(function()
    -- A leading SELECT prints its own rows; only the trailing ROW_COUNT() counts.
    with_system_mock("id\n7\n8\nROW_COUNT()\n2\n", "", 0, function()
      local result = mysql.execute("SELECT id FROM t; UPDATE t SET x=1", "mysql://root@localhost/test")
      eq(result.affected, 2, "affected")
    end)
  end)
end)

test("mysql execute: ROW_COUNT() of -1 (no DML) is reported as 0", function()
  with_executable(function()
    with_system_mock("ROW_COUNT()\n-1\n", "", 0, function()
      local result = mysql.execute("SELECT 1", "mysql://root@localhost/test")
      eq(result.affected, 0, "negative count clamped")
    end)
  end)
end)

-- ── SQLite PRAGMA quoting ────────────────────────────────────────────────────

test("sqlite get_primary_keys: table name is quoted in PRAGMA", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    sqlite.get_primary_keys("users", "sqlite:test.db")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    contains(sql_arg, '"users"', "table name should be quoted")
  end)
end)

test("sqlite get_primary_keys: embedded quote is escaped", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    sqlite.get_primary_keys('my"table', "sqlite:test.db")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    -- Double-quote escaping: my"table becomes my""table inside quotes
    contains(sql_arg, 'my""table', "embedded quote should be doubled")
  end)
end)

-- ── DuckDB httpfs extension loading ─────────────────────────────────────────

test("duckdb query: SQL with HTTP URL prepends INSTALL/LOAD httpfs", function()
  with_executable(function()
    local args, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT * FROM 'https://example.com/data.csv'", "duckdb::memory:")
    end)
    assert(not vim.tbl_contains(args, "-c"), "DuckDB SQL must not be in argv")
    contains(opts.stdin, "INSTALL httpfs", "should prepend INSTALL httpfs")
    contains(opts.stdin, "LOAD httpfs", "should prepend LOAD httpfs")
    contains(opts.stdin, "https://example.com/data.csv", "original SQL preserved")
  end)
end)

test("duckdb query: SQL without HTTP URL does not prepend httpfs", function()
  with_executable(function()
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT * FROM users", "duckdb::memory:")
    end)
    assert(not opts.stdin:find("httpfs", 1, true), "should not contain httpfs: " .. opts.stdin)
  end)
end)

test("duckdb query: attachment setup rows cannot replace query results", function()
  local output = table.concat({
    "Success",
    "true",
    "_grip_boundary",
    "__dadbod_grip_result_boundary__",
    "count_star()",
    "15",
  }, "\n") .. "\n"
  eq(duckdb._strip_csv_setup(output), "count_star()\n15\n", "setup output stripped")
end)

test("duckdb query: httpfs timeout is at least 30 seconds", function()
  with_executable(function()
    local captured_opts
    local orig = vim.system
    vim.system = function(a, opts, cb)
      captured_opts = opts
      local r = { stdout = "col\nval\n", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.query("SELECT * FROM 'https://example.com/data.csv'", "duckdb::memory:")
    vim.system = orig
    assert(captured_opts.timeout >= 30000, "timeout should be >= 30000, got " .. tostring(captured_opts.timeout))
  end)
end)

test("duckdb query: http URL also triggers httpfs", function()
  with_executable(function()
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT * FROM 'http://example.com/data.csv'", "duckdb::memory:")
    end)
    contains(opts.stdin, "httpfs", "http should also trigger httpfs")
  end)
end)

-- ── DuckDB scanner extension install timeout ────────────────────────────────
-- The ATTACH prefix carries "INSTALL <scanner>" into every query on an attached
-- connection, and the first one has to fetch that extension from
-- extensions.duckdb.org -- the same cost the httpfs block above already buys
-- headroom for. Without it the fetch has to fit inside the 10s query timeout,
-- which is what took CI's test (stable) down on the run for 010d91d: duckdb
-- killed at 124, and 13 assertions failing about catalogs that were never
-- attached. The headroom is deliberately not unconditional -- a warm INSTALL is
-- a local no-op, and an unreachable database should still fail in 10s, not 60.

test("duckdb query: a cold scanner INSTALL gets the network timeout", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:cold_scanner.db"
  duckdb._attach_unchecked(url, "sqlite:legacy.db", "legacy")
  with_executable(function()
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT * FROM legacy.orders", url)
    end)
    assert(opts.timeout >= 60000,
      "a cold scanner fetch needs >= 60000, got " .. tostring(opts.timeout))
  end)
  duckdb.detach(url, "legacy")
end)

test("duckdb query: a scanner installed earlier this session keeps the default timeout", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:warm_scanner.db"
  duckdb._attach_unchecked(url, "sqlite:legacy.db", "legacy")
  with_executable(function()
    -- Arrange: one clean exit, which is what marks the scanner installed.
    capture_system_call("col\nval\n", function() duckdb.query("SELECT 1", url) end)
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT 1", url)
    end)
    eq(opts.timeout, 60000, "a warm scanner must not buy network headroom")
  end)
  duckdb.detach(url, "legacy")
end)

test("duckdb query: a query with no attachments keeps the default timeout", function()
  duckdb._forget_installed_extensions()
  with_executable(function()
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT 1", "duckdb::memory:")
    end)
    eq(opts.timeout, 60000, "an unattached query has no INSTALL to wait for")
  end)
end)

test("duckdb query: a scanner whose query failed keeps the network timeout next time", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:failed_scanner.db"
  duckdb._attach_unchecked(url, "postgres:dbname=sales", "pg")
  with_executable(function()
    -- A non-zero exit says nothing about whether the fetch got through, so it
    -- must not be remembered as an install that succeeded.
    with_system_mock("", 'Extension "postgres_scanner" not found', 1, function()
      duckdb.query("SELECT 1", url)
    end)
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT 1", url)
    end)
    assert(opts.timeout >= 60000,
      "a failed install must not count as installed, got " .. tostring(opts.timeout))
  end)
  duckdb.detach(url, "pg")
end)

test("duckdb attach: validating a scanner-backed DSN gets the network timeout", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:attach_scanner.db"
  local _, opts = capture_system_call("42\n", function()
    duckdb.attach(url, "md:cloud_db", "cloud")
  end)
  assert(opts.timeout >= 60000,
    "attach validation runs the very first INSTALL, got " .. tostring(opts.timeout))
  duckdb.detach(url, "cloud")
end)

test("duckdb attach: a DSN with no scanner keeps the default validation timeout", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:attach_plain.db"
  local _, opts = capture_system_call("42\n", function()
    duckdb.attach(url, "/tmp/plain.duckdb", "plain")
  end)
  eq(opts.timeout, 60000, "no scanner means no fetch to wait for")
  duckdb.detach(url, "plain")
end)

test("duckdb attach: validation fails fast without opening the main database", function()
  duckdb._forget_installed_extensions()
  local args = capture_system_call("42\n", function()
    duckdb.attach("duckdb:attach_flags.db", "/tmp/plain.duckdb", "plain")
  end)
  eq(table.concat(args, " "), "duckdb -bail", "in-memory validation argv")
  duckdb.detach("duckdb:attach_flags.db", "plain")
end)

test("duckdb attach: plain validation honors the configured timeout", function()
  local grip = require("dadbod-grip")
  grip.setup({ timeout = 4321 })
  local ok, err = pcall(function()
    local url = "duckdb:attach_configured_timeout.db"
    local _, opts = capture_system_call("42\n", function()
      duckdb.attach(url, "/tmp/plain.duckdb", "plain")
    end)
    eq(opts.timeout, 4321, "configured timeout")
    duckdb.detach(url, "plain")
  end)
  grip.setup({})
  if not ok then error(err) end
end)

-- ── SQLite get_constraints ───────────────────────────────────────────────────

test("sqlite get_constraints: queries sqlite_master with table name", function()
  local captured_args
  local orig = vim.system
  vim.system = function(a, o, cb)
    captured_args = a
    captured_args._stdin = o and o.stdin
    local r = { stdout = "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  sqlite.get_constraints("users", "sqlite:test.db")
  vim.system = orig
  local sql_arg = last_arg(captured_args)
  contains(sql_arg, "sqlite_master", "queries sqlite_master")
  contains(sql_arg, "users", "filters by table name")
end)

test("sqlite get_constraints: parses UNIQUE constraint from DDL", function()
  local ddl = "sql\nCREATE TABLE users (\n  id INTEGER,\n  email TEXT,\n  UNIQUE (email)\n)"
  with_system_mock(ddl, "", 0, function()
    local result = sqlite.get_constraints("users", "sqlite:test.db")
    local found_unique = false
    for _, c in ipairs(result) do
      if c.type == "UNIQUE" then found_unique = true end
    end
    assert(found_unique, "should detect UNIQUE constraint in DDL")
  end)
end)

test("sqlite get_constraints: parses CHECK constraint from DDL", function()
  local ddl = "sql\nCREATE TABLE users (\n  id INTEGER,\n  age INTEGER,\n  CHECK (age > 0)\n)"
  with_system_mock(ddl, "", 0, function()
    local result = sqlite.get_constraints("users", "sqlite:test.db")
    local found_check = false
    for _, c in ipairs(result) do
      if c.type == "CHECK" then found_check = true end
    end
    assert(found_check, "should detect CHECK constraint in DDL")
  end)
end)

test("sqlite get_constraints: falls back to DDL entry when no named constraints", function()
  local ddl = "sql\nCREATE TABLE simple (id INTEGER, name TEXT)"
  with_system_mock(ddl, "", 0, function()
    local result = sqlite.get_constraints("simple", "sqlite:test.db")
    eq(#result, 1, "one fallback entry")
    eq(result[1].type, "DDL", "fallback type is DDL")
    contains(result[1].definition, "CREATE TABLE", "definition contains DDL")
  end)
end)

test("sqlite get_constraints: returns empty for empty DDL output", function()
  with_system_mock("", "", 0, function()
    local result = sqlite.get_constraints("empty", "sqlite:test.db")
    eq(#result, 0, "empty list for empty output")
  end)
end)

-- ── DuckDB get_constraints ───────────────────────────────────────────────────

test("duckdb get_constraints: queries duckdb_constraints() for table", function()
  with_executable(function()
    local captured_opts
    local orig = vim.system
    vim.system = function(_a, opts, cb)
      captured_opts = opts
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.get_constraints("users", "duckdb::memory:")
    vim.system = orig
    contains(captured_opts.stdin, "duckdb_constraints", "queries duckdb_constraints()")
    contains(captured_opts.stdin, "users", "filters by table name")
  end)
end)

test("duckdb get_constraints: filters by schema name", function()
  with_executable(function()
    local captured_opts
    local orig = vim.system
    vim.system = function(_a, opts, cb)
      captured_opts = opts
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.get_constraints("myschema.users", "duckdb:test.db")
    vim.system = orig
    contains(captured_opts.stdin, "myschema", "includes schema filter")
    contains(captured_opts.stdin, "users", "includes table filter")
  end)
end)

test("duckdb get_constraints: parses CSV output into constraint rows", function()
  with_executable(function()
    local csv = "constraint_name,constraint_type,definition\nemail_unique,UNIQUE,email\nage_check,CHECK,age > 0\n"
    with_system_mock(csv, "", 0, function()
      local result = duckdb.get_constraints("users", "duckdb::memory:")
      eq(#result, 2, "two constraints parsed")
      eq(result[1].name, "email_unique", "first constraint name")
      eq(result[1].type, "UNIQUE", "first constraint type")
      eq(result[2].name, "age_check", "second constraint name")
      eq(result[2].type, "CHECK", "second constraint type")
    end)
  end)
end)

test("duckdb get_constraints: returns empty list on query failure", function()
  with_executable(function()
    with_system_mock("", "Error: table not found", 1, function()
      local result, err = duckdb.get_constraints("missing", "duckdb::memory:")
      eq(#result, 0, "empty list on error")
      -- The error is swallowed on purpose: a non-zero exit here usually means the
      -- server predates duckdb_constraints(), which must degrade to "no
      -- constraints", not surface as a failure. Pinned so a later "let's
      -- propagate the error" change has to face that trade-off deliberately.
      eq(err, nil, "query failure reports no error")
    end)
  end)
end)

-- ── MySQL sql_mode: NO_BACKSLASH_ESCAPES ─────────────────────────────────────

test("mysql query: stdin session setup includes NO_BACKSLASH_ESCAPES", function()
  with_executable(function()
    local args, opts = capture_system_call("id\n1\n", function()
      mysql.query("SELECT 1", "mysql://root@localhost/test")
    end)
    assert(not table.concat(args, " "):find("--init-command", 1, true), "no init command in argv")
    contains(opts.stdin, "NO_BACKSLASH_ESCAPES", "query sql_mode setup")
    contains(opts.stdin, "SELECT 1", "query delivered via stdin")
  end)
end)

test("mysql execute: stdin session setup includes NO_BACKSLASH_ESCAPES", function()
  with_executable(function()
    local captured_args, captured_opts
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_opts = o
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("UPDATE t SET x=1 WHERE id=1", "mysql://root@localhost/test")
    vim.system = orig
    assert(not table.concat(captured_args, " "):find("--init-command", 1, true), "no init command in argv")
    contains(captured_opts.stdin, "NO_BACKSLASH_ESCAPES", "execute sql_mode setup")
    contains(captured_opts.stdin, "UPDATE t SET x=1", "statement delivered via stdin")
  end)
end)

-- ── MySQL query flags ────────────────────────────────────────────────────────
-- MySQL and MariaDB are driven identically: --batch for both.

test("mysql query: uses --batch flag", function()
  with_executable(function()
    local args = capture_system_args("id\t1\n", function()
      mysql.query("SELECT 1", "mysql://root@localhost/test")
    end)
    has_arg(args, "--batch", "MySQL should use --batch")
  end)
end)

-- ── MySQL column types come from COLUMN_TYPE ─────────────────────────────────
-- Rebuilding the type from DATA_TYPE + CHARACTER_MAXIMUM_LENGTH/NUMERIC_PRECISION
-- renders enum(7), float(12) and longtext(4294967295) -- shaped like DDL, wrong.

local function assert_uses_column_type(sql, label)
  contains(sql, "c.COLUMN_TYPE AS data_type", label .. " selects COLUMN_TYPE")
  assert(not sql:find("NUMERIC_PRECISION", 1, true),
    label .. " must not rebuild the type from NUMERIC_PRECISION")
  assert(not sql:find("CHARACTER_MAXIMUM_LENGTH", 1, true),
    label .. " must not rebuild the type from CHARACTER_MAXIMUM_LENGTH")
end

test("mysql get_column_info: type comes from COLUMN_TYPE verbatim", function()
  local tsv = table.concat({
    "column_name\tdata_type\tis_nullable\tcolumn_default\tconstraints",
    "feeling\tenum('happy','sad','neutral')\tYES\t\t",
    "approx_float\tfloat\tYES\t\t",
    "maria_id\tint(11) unsigned\tNO\t\t",
    "unit_price\tdecimal(10,2)\tNO\t\tPRI",
  }, "\n") .. "\n"

  local args, cols
  with_executable(function()
    args = capture_system_args(tsv, function()
      cols = mysql.get_column_info("type_zoo", "mysql://root:pass@localhost/testdb")
    end)
  end)

  assert_uses_column_type(last_arg(args), "get_column_info SQL")
  eq(cols[1].data_type, "enum('happy','sad','neutral')", "enum list")
  eq(cols[2].data_type, "float", "float without a bogus precision")
  eq(cols[3].data_type, "int unsigned", "MariaDB integer width removed; modifier kept")
  eq(cols[4].data_type, "decimal(10,2)", "decimal keeps precision and scale")
  eq(cols[4].constraints, "PRIMARY KEY", "COLUMN_KEY still maps to a constraint label")
end)

-- ── duckdb: main catalog name ───────────────────────────────────────────────
-- DuckDB names the main catalog after the file's basename without extension,
-- and calls the in-memory one "memory". The column/PK/table queries all
-- filter on that name as a string literal, so getting ":memory:" wrong there
-- makes every one of them match nothing.

test("duckdb _main_catalog_name: :memory: maps to DuckDB's 'memory' catalog", function()
  eq(duckdb._main_catalog_name(":memory:"), "memory", "in-memory catalog is named 'memory'")
end)

test("duckdb _main_catalog_name: file paths keep the basename without extension", function()
  eq(duckdb._main_catalog_name("/data/softrear.duckdb"), "softrear", "absolute path")
  eq(duckdb._main_catalog_name("softrear.db"), "softrear", "relative path")
  eq(duckdb._main_catalog_name("/data/noext"), "noext", "no extension")
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nadapter_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
