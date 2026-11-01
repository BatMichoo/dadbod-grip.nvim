-- sqlserver_pool_live_spec.lua: the SQL Server connection pool leaves no
-- session behind, checked from both ends: the pooled sqlcmd process has exited
-- and sys.dm_exec_sessions no longer lists its server session.
--
-- A session is identified by (session_id, login_time); session ids are reused,
-- login times are not. The observer queries run with pooling off, so they are
-- one-shot sqlcmd processes that never touch the pool under test.
--
-- Skips cleanly when GRIP_TEST_SQLSERVER_URL is unset (`just test-live
-- sqlserver-2025` sets it). To run against the Docker database:
--
--   just db-up sqlserver
--   GRIP_TEST_SQLSERVER_URL='sqlserver://sa:Grip-ci-2025!@127.0.0.1:11433/grip_test?encrypt=optional&trust_server_certificate=true' \
--     nvim --headless -u tests/minimal_init.lua -l tests/spec/sqlserver_pool_live_spec.lua

local URL = vim.env.GRIP_TEST_SQLSERVER_URL
local REQUIRED = vim.env.GRIP_REQUIRE_SQLSERVER == "1"

local function unavailable(reason)
  if REQUIRED then
    error("sqlserver_pool_live_spec: " .. reason .. " while GRIP_REQUIRE_SQLSERVER=1")
  end
  print("SKIP: sqlserver_pool_live_spec (" .. reason .. ")")
  print("\nsqlserver_pool_live_spec: 0 passed, 0 failed (skipped)")
end

if not URL or URL == "" then
  unavailable("GRIP_TEST_SQLSERVER_URL not set")
  return
end

local config = require("dadbod-grip.config")
local pool = require("dadbod-grip.adapters.sqlserver_pool")
local sqlserver = require("dadbod-grip.adapters.sqlserver")

if not sqlserver.ping(URL) then
  unavailable("database is unreachable")
  return
end

local pass, fail = 0, 0
local saved = {
  pool = config.values.sqlserver_pool,
  idle = config.values.sqlserver_pool_idle_timeout,
  timeout = config.values.timeout,
}

local function restore()
  config.values.sqlserver_pool = saved.pool
  config.values.sqlserver_pool_idle_timeout = saved.idle
  config.values.timeout = saved.timeout
end

local function test(name, fn)
  -- Start every test from an empty pool with pooling on.
  pool.dispose_all()
  config.values.sqlserver_pool = true
  local ok, err = pcall(fn)
  restore()
  pool.dispose_all()
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(actual, expected, message)
  assert(actual == expected,
    (message or "") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

-- Long enough for a graceful logout (the pool allows 2 s before SIGKILL) and
-- for the server to notice a killed client's dropped TCP connection.
local GONE_MS = 5000

local SELF_SQL = "SELECT @@SPID, CONVERT(varchar(30), login_time, 126)"
  .. " FROM sys.dm_exec_sessions WHERE session_id = @@SPID"

--- The server session behind the pooled connection, as {spid, login}.
local function pooled_session()
  local result, err = sqlserver.query(SELF_SQL, URL)
  assert(result, "pooled session query failed: " .. tostring(err))
  return { spid = result.rows[1][1], login = result.rows[1][2] }
end

--- Whether the server still lists a session, asked over a one-shot connection.
local function session_alive(session)
  config.values.sqlserver_pool = false
  local result, err = sqlserver.query(string.format(
    "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE session_id = %d"
      .. " AND CONVERT(varchar(30), login_time, 126) = '%s'",
    tonumber(session.spid), session.login), URL)
  config.values.sqlserver_pool = true
  assert(result, "observer query failed: " .. tostring(err))
  return tonumber(result.rows[1][1]) > 0
end

local function assert_session_gone(session, label)
  local gone = vim.wait(GONE_MS, function() return not session_alive(session) end, 200)
  assert(gone, label .. ": server session " .. session.spid .. " still exists")
end

--- The only pool entry (every test starts from an empty pool).
local function only_entry()
  local entries = vim.tbl_values(pool._entries())
  eq(#entries, 1, "pool entries")
  return entries[1]
end

local function assert_process_exited(entry, label)
  local exited = vim.wait(GONE_MS, function() return entry.dead end, 20)
  assert(exited, label .. ": sqlcmd process (pid " .. tostring(entry.obj.pid) .. ") still running")
end

local function assert_pool_empty(label)
  eq(next(pool._entries()), nil, label .. ": pool still holds an entry")
end

test("repeated queries reuse one server session", function()
  local first = pooled_session()
  local entry = only_entry()
  local second = pooled_session()
  eq(second.spid, first.spid, "session id")
  eq(second.login, first.login, "login time")
  assert(only_entry() == entry, "a second process was spawned")
end)

test("dispose_all ends the process and the server session", function()
  local session = pooled_session()
  local entry = only_entry()
  assert(session_alive(session), "pooled session not visible to the observer")
  pool.dispose_all()
  assert_process_exited(entry, "dispose_all")
  assert_pool_empty("dispose_all")
  assert_session_gone(session, "dispose_all")
end)

test("closing the last tab that used a connection ends its session", function()
  vim.cmd("tabnew")
  local session = pooled_session()
  local entry = only_entry()
  vim.cmd("tabclose")
  assert_process_exited(entry, "tabclose")
  assert_pool_empty("tabclose")
  assert_session_gone(session, "tabclose")
end)

test("closing one of two tabs keeps the session for the other", function()
  local session = pooled_session()
  local entry = only_entry()
  vim.cmd("tabnew")
  pooled_session()
  vim.cmd("tabclose")
  vim.wait(500)
  assert(not entry.dead, "process exited while a tab still uses it")
  assert(session_alive(session), "session closed while a tab still uses it")
  eq(pooled_session().login, session.login, "query after tabclose used the same session")
end)

test("idle timeout ends the session", function()
  config.values.sqlserver_pool_idle_timeout = 300
  local session = pooled_session()
  local entry = only_entry()
  assert_process_exited(entry, "idle timeout")
  assert_pool_empty("idle timeout")
  assert_session_gone(session, "idle timeout")
end)

test("a timed-out query kills the process and frees the session", function()
  local session = pooled_session()
  local entry = only_entry()
  config.values.timeout = 1000
  local result, err = sqlserver.query("WAITFOR DELAY '00:00:30'; SELECT 1", URL)
  config.values.timeout = saved.timeout
  eq(result, nil, "timed-out query result")
  assert(tostring(err):find("timed out", 1, true), "unexpected error: " .. tostring(err))
  assert_process_exited(entry, "timeout")
  assert_pool_empty("timeout")
  assert_session_gone(session, "timeout")
end)

test("a fatal server error drops the process and the session", function()
  local session = pooled_session()
  local entry = only_entry()
  local result = sqlserver.query("RAISERROR('grip pool fatal probe', 20, 1) WITH LOG", URL)
  eq(result, nil, "fatal query result")
  assert_process_exited(entry, "fatal")
  assert_pool_empty("fatal")
  assert_session_gone(session, "fatal")
  -- The next query starts a fresh session instead of reusing the dead one.
  local fresh = pooled_session()
  assert(fresh.spid ~= session.spid or fresh.login ~= session.login,
    "query after a fatal error reused the dropped session")
end)

test("quitting Neovim ends pooled sessions and their processes", function()
  -- The child reports its session through a file: a headless child's stdout
  -- is not a reliable channel.
  local child_script = vim.fn.tempname() .. ".lua"
  local report = vim.fn.tempname()
  vim.fn.writefile({
    "require('dadbod-grip.config').values.sqlserver_pool = true", -- minimal_init turns it off
    "local pool = require('dadbod-grip.adapters.sqlserver_pool')",
    "local r = assert(require('dadbod-grip.adapters.sqlserver').query([[" .. SELF_SQL .. "]],"
      .. " vim.env.GRIP_TEST_SQLSERVER_URL))",
    "local entry = vim.tbl_values(pool._entries())[1]",
    "vim.fn.writefile({ r.rows[1][1], r.rows[1][2], tostring(entry.obj.pid) }, vim.env.GRIP_CHILD_REPORT)",
  }, child_script)
  local child = vim.system({
    vim.v.progpath, "--headless", "-u", "tests/minimal_init.lua",
    "-c", "luafile " .. child_script, "-c", "qa!",
  }, { text = true, env = { GRIP_CHILD_REPORT = report } }):wait(30000)
  os.remove(child_script)
  local lines = vim.fn.filereadable(report) == 1 and vim.fn.readfile(report) or {}
  os.remove(report)
  eq(child.code, 0, "child nvim exit code")
  local spid, login, pid = lines[1], lines[2], lines[3]
  assert(pid, "child reported no session (stderr: " .. vim.inspect(child.stderr) .. ")")

  local exited = vim.wait(GONE_MS, function()
    return vim.uv.kill(tonumber(pid), 0) ~= 0
  end, 50)
  assert(exited, "sqlcmd process " .. pid .. " outlived Neovim")
  assert_session_gone({ spid = spid, login = login }, "Neovim exit")
end)

print(string.format("\nsqlserver_pool_live_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
