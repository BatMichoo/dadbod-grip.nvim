-- Unit tests for sqlserver_pool.lua. Tests the pure logic (framing, key
-- generation, serialization) against a fake spawner; protocol correctness
-- against real sqlcmd depends on the live integration tests.

local pool = require("dadbod-grip.adapters.sqlserver_pool")

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  assert(vim.deep_equal(a, b), (msg or "") .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end

-- Test: key_for collapses host/port/dbname/user/auth/encrypt/trust/cert.
test("key_for: identical connections produce same key", function()
  local p1 = { host = "srv", port = "1433", dbname = "db", user = "sa", encrypt = "mandatory", pass = "secret1" }
  local p2 = { host = "srv", port = "1433", dbname = "db", user = "sa", encrypt = "mandatory", pass = "secret2" }
  eq(pool.key_for(p1), pool.key_for(p2), "different passwords still produce same key")
end)

-- Test: key_for differentiates connections by identity fields.
test("key_for: different hosts produce different keys", function()
  local p1 = { host = "srv1", port = "1433", dbname = "db", user = "sa" }
  local p2 = { host = "srv2", port = "1433", dbname = "db", user = "sa" }
  assert(pool.key_for(p1) ~= pool.key_for(p2), "different hosts should differ")
end)

-- Test: _extract_until_sentinel handles present/absent/partial tokens.
test("_extract_until_sentinel: finds sentinel", function()
  local buf = "result1\nresult2\n\x01MARKER\x01extra"
  local before, found = pool._extract_until_sentinel(buf, "\x01MARKER\x01")
  eq(before, "result1\nresult2\n", "extracts content before sentinel")
  assert(found, "should mark as found")
end)

test("_extract_until_sentinel: sentinel not found", function()
  local buf = "result1\nresult2\n"
  local before, found = pool._extract_until_sentinel(buf, "\x01MISSING\x01")
  eq(before, buf, "returns whole buffer when sentinel absent")
  assert(not found, "should mark as not found")
end)

-- Test: dispose_all clears pool.
test("M.dispose_all: clears pool", function()
  pool._entries()[pool.key_for({ host = "test" })] = nil
  pool.dispose_all()
  assert(vim.tbl_count(pool._entries()) == 0, "pool should be empty after dispose_all")
end)

local cfg = require("dadbod-grip.config").values
local parsed = { host = "fake", port = "1433", dbname = "db", user = "sa" }
local key = pool.key_for(parsed)
local function args_fn() return { "sqlcmd" } end
local function env_fn() return {} end

-- Fake sqlcmd without -b: answers each sentinel batch with the PRINT token on
-- stdout, after `respond(sql)` output for the script before it.
local function marker_spawner(respond, seen_args)
  return function(args, opts)
    if seen_args then vim.list_extend(seen_args, args) end
    return {
      write = function(_, payload)
        local script = payload:match("^(.-)\nGO\nPRINT '")
        local token = payload:match("PRINT '([^']*)'")
        opts.stdout(nil, (respond(script) or "") .. token .. "\n")
      end,
      kill = function() end,
    }
  end
end

local function with_pool(fn)
  local saved_pool = cfg.sqlserver_pool
  cfg.sqlserver_pool = true
  local ok, err = pcall(fn)
  pool._set_spawner(nil)
  pool.dispose_all()
  cfg.sqlserver_pool = saved_pool
  if not ok then error(err, 0) end
end

local MSG_208 = "Msg 208, Level 16, State 1, Server s, Line 1\nInvalid object name 'x'.\n"

test("run: pooled argv drops -b", function()
  with_pool(function()
    local seen = {}
    pool._set_spawner(marker_spawner(function() end, seen))
    pool.run(key, parsed, "SELECT 1", 1000, function() return { "sqlcmd", "-b", "-W" } end, env_fn)
    eq(seen, { "sqlcmd", "-W" }, "argv")
  end)
end)

test("run: server error header fails the batch but keeps the session", function()
  with_pool(function()
    pool._set_spawner(marker_spawner(function(sql)
      if sql == "SELECT * FROM x" then return MSG_208 end
      if sql == "SELECT 1" then return "v\n-\n1\n" end
    end))
    local stdout, stderr, code = pool.run(key, parsed, "SELECT * FROM x", 1000, args_fn, env_fn)
    eq(code, 1, "error exit code")
    eq(stdout, MSG_208, "error text on stdout")
    eq(stderr, "", "stderr")
    local entry = pool._entries()[key]
    assert(entry and not entry.dead, "entry should survive a server error")

    stdout, _, code = pool.run(key, parsed, "SELECT 1", 1000, args_fn, env_fn)
    eq(code, 0, "next batch succeeds")
    eq(stdout, "v\n-\n1\n", "next batch stdout")
    assert(pool._entries()[key] == entry, "same entry reused")
  end)
end)

test("run: lookalike result rows and level 10 messages are not errors", function()
  with_pool(function()
    pool._set_spawner(marker_spawner(function()
      return "a\tb\n-\t-\nMsg 1, Level 16, State 1, Server s, Line 1\tx\nMsg 1, Level 16, fake\n"
        .. "Msg 50000, Level 10, State 1, Server s, Line 1\njust info\n"
    end))
    local _, _, code = pool.run(key, parsed, "SELECT 1", 1000, args_fn, env_fn)
    eq(code, 0, "exit code")
  end)
end)

-- go-sqlcmd hangs after a fatal (level >= 20) error instead of exiting; the
-- pool must give up at once rather than wait out the query timeout.
test("run: fatal error stops waiting and drops the entry", function()
  with_pool(function()
    pool._set_spawner(function(_, opts, on_exit)
      return {
        write = function()
          opts.stdout(nil, "Msg 50000, Level 20, State 1, Server s, Line 1\nfatal\n")
        end,
        kill = function() on_exit({ code = -1 }) end,
      }
    end)
    local started = vim.uv.now()
    local stdout, _, code = pool.run(key, parsed, "RAISERROR('fatal', 20, 1) WITH LOG", 10000, args_fn, env_fn)
    assert(vim.uv.now() - started < 3000, "waited " .. (vim.uv.now() - started) .. "ms")
    eq(code, 1, "exit code")
    assert(stdout:match("^Msg 50000, Level 20"), "stdout: " .. vim.inspect(stdout))
    assert(pool._entries()[key] == nil, "entry should be dropped")
  end)
end)

-- Test: when sqlcmd exits before the sentinel (crash, mssql-tools on a fatal
-- error), the batch's "Msg NNNN" output must reach the caller instead of a
-- generic desync error.
test("run: process exiting on server error returns its output", function()
  local saved_pool = cfg.sqlserver_pool
  cfg.sqlserver_pool = true
  pool._set_spawner(function(_, opts, on_exit)
    return {
      write = function()
        opts.stdout(nil, "Msg 208, Level 16, State 1, Line 1\nInvalid object name 'x'.\n")
        on_exit({ code = 1 })
      end,
      kill = function() end,
    }
  end)
  local stdout, _, code = pool.run(key, parsed, "SELECT * FROM x", 1000, args_fn, env_fn)
  pool._set_spawner(nil)
  cfg.sqlserver_pool = saved_pool
  eq(code, 1, "exit code")
  assert(stdout:match("^Msg 208"), "stdout should carry server message, got " .. vim.inspect(stdout))
  assert(pool._entries()[key] == nil, "dead entry should be dropped")
end)

-- Test: a failed respawn of a dead entry returns an error (no nil-index crash)
-- and removes the dead entry so later callers do not wait on it.
test("run: respawn failure drops dead entry", function()
  local saved_pool = cfg.sqlserver_pool
  cfg.sqlserver_pool = true
  local dead = { key = key, dead = true, tabs = {}, buf = "", stderr_buf = "", batch_counter = 0 }
  pool._entries()[key] = dead
  pool._set_spawner(function() error("spawn refused") end)
  local ok, stdout, stderr, code = pcall(pool.run, key, parsed, "SELECT 1", 1000, args_fn, env_fn)
  pool._set_spawner(nil)
  cfg.sqlserver_pool = saved_pool
  assert(ok, "run should not raise: " .. tostring(stdout))
  eq(code, 1, "exit code")
  assert(stderr:match("^Failed to respawn sqlcmd"), "stderr: " .. vim.inspect(stderr))
  assert(pool._entries()[key] == nil, "dead entry should be dropped")
  assert(not dead.busy, "dead entry should not stay busy")
end)

pool.dispose_all()

print(string.format("\nSQL Server pool: %d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
