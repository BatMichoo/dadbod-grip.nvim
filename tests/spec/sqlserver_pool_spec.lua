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

-- Test: key_for collapses host/port/dbname/user/auth/encrypt/trust/cert/password.
test("key_for: identical connections produce same key", function()
  local p1 = { host = "srv", port = "1433", dbname = "db", user = "sa", encrypt = "mandatory", pass = "secret" }
  local p2 = { host = "srv", port = "1433", dbname = "db", user = "sa", encrypt = "mandatory", pass = "secret" }
  eq(pool.key_for(p1), pool.key_for(p2), "same connection")
end)

-- Test: key_for differentiates connections by identity fields.
test("key_for: different hosts produce different keys", function()
  local p1 = { host = "srv1", port = "1433", dbname = "db", user = "sa" }
  local p2 = { host = "srv2", port = "1433", dbname = "db", user = "sa" }
  assert(pool.key_for(p1) ~= pool.key_for(p2), "different hosts should differ")
end)

-- Test: a wrong password must not reuse a session another password opened,
-- and the key must not carry the secret itself.
test("key_for: different passwords produce different keys without the secret", function()
  local p1 = { host = "srv", user = "sa", pass = "secret1" }
  local p2 = { host = "srv", user = "sa", pass = "secret2" }
  assert(pool.key_for(p1) ~= pool.key_for(p2), "different passwords should differ")
  assert(not pool.key_for(p1):find("secret1", 1, true), "key contains the password")
end)

local cfg = require("dadbod-grip.config").values
local parsed = { host = "fake", port = "1433", dbname = "db", user = "sa" }
local key = pool.key_for(parsed)
local function args_fn() return { "sqlcmd" } end
local function env_fn() return {} end

-- Fake sqlcmd without -b. Each batch write gets `respond(script, proc)` output
-- followed by the sentinel line, delivered in `chunk`-byte pieces when set.
-- Closing stdin (write(nil)) or kill() ends the fake process.
local function fake_sqlcmd(respond, opts)
  opts = opts or {}
  local procs = {}
  local spawner = function(args, sys_opts, on_exit)
    local proc = { args = args, writes = {}, killed = false }
    local function exit(code)
      if proc.exited then return end
      proc.exited = true
      on_exit({ code = code })
    end
    proc.exit = exit
    proc.stdout = function(data) sys_opts.stdout(nil, data) end
    proc.obj = {
      write = function(_, payload)
        if payload == nil then return exit(0) end
        proc.writes[#proc.writes + 1] = payload
        local script = payload:match("^(.-)\nGO\nIF @@TRANCOUNT")
        local token = payload:match("PRINT '([^']*)'")
        local out = (respond and respond(script, proc) or "") .. token .. "\n" .. (opts.after or "")
        local size = opts.chunk or #out
        for i = 1, #out, size do sys_opts.stdout(nil, out:sub(i, i + size - 1)) end
      end,
      kill = function() proc.killed = true; exit(-1) end,
    }
    procs[#procs + 1] = proc
    return proc.obj
  end
  return spawner, procs
end

local function with_pool(fn)
  local saved_pool, saved_idle = cfg.sqlserver_pool, cfg.sqlserver_pool_idle_timeout
  cfg.sqlserver_pool = true
  local ok, err = pcall(fn)
  pool.dispose_all()
  pool._set_spawner(nil)
  cfg.sqlserver_pool, cfg.sqlserver_pool_idle_timeout = saved_pool, saved_idle
  if not ok then error(err, 0) end
end

local function run(sql, timeout_ms)
  return pool.run(parsed, sql, timeout_ms or 1000, args_fn, env_fn)
end

local MSG_208 = "Msg 208, Level 16, State 1, Server s, Line 1\nInvalid object name 'x'.\n"

test("M.dispose_all: clears pool", function()
  with_pool(function()
    pool._set_spawner(fake_sqlcmd())
    run("SELECT 1")
    assert(pool._entries()[key], "entry should exist before dispose_all")
  end)
  assert(vim.tbl_count(pool._entries()) == 0, "pool should be empty after dispose_all")
end)

test("run: pooled argv drops -b", function()
  with_pool(function()
    local spawner, procs = fake_sqlcmd()
    pool._set_spawner(spawner)
    pool.run(parsed, "SELECT 1", 1000, function() return { "sqlcmd", "-b", "-W" } end, env_fn)
    eq(procs[1].args, { "sqlcmd", "-W" }, "argv")
  end)
end)

-- The rollback safety net shares the sentinel batch: one write, one round trip.
test("run: one write per batch, rollback before the sentinel", function()
  with_pool(function()
    local spawner, procs = fake_sqlcmd(function() return "v\n-\n1\n" end)
    pool._set_spawner(spawner)
    local stdout, _, code = run("SELECT 1")
    eq(code, 0, "exit code")
    eq(stdout, "v\n-\n1\n", "stdout")
    eq(#procs[1].writes, 1, "writes")
    assert(procs[1].writes[1]:match("^SELECT 1\nGO\nIF @@TRANCOUNT > 0 ROLLBACK TRANSACTION\nPRINT '"),
      "payload: " .. vim.inspect(procs[1].writes[1]))
  end)
end)

test("run: sentinel is random per batch", function()
  with_pool(function()
    local spawner, procs = fake_sqlcmd()
    pool._set_spawner(spawner)
    run("SELECT 1")
    run("SELECT 1")
    local t1 = procs[1].writes[1]:match("PRINT '([^']*)'")
    local t2 = procs[1].writes[2]:match("PRINT '([^']*)'")
    assert(t1:match("^GRIPEOB:%x+$") and #t1 == 24, "token shape: " .. t1)
    assert(t1 ~= t2, "tokens repeat")
  end)
end)

test("run: lines and the sentinel split across chunks", function()
  with_pool(function()
    pool._set_spawner(fake_sqlcmd(function() return "a\tb\n-\t-\n1\t2\n" .. MSG_208 end, { chunk = 3 }))
    local stdout, _, code = run("SELECT 1")
    eq(stdout, "a\tb\n-\t-\n1\t2\n" .. MSG_208, "stdout")
    eq(code, 1, "error header seen across chunks")
    assert(pool._entries()[key], "entry kept")
  end)
end)

test("run: server error header fails the batch but keeps the session", function()
  with_pool(function()
    pool._set_spawner(fake_sqlcmd(function(sql)
      if sql == "SELECT * FROM x" then return MSG_208 end
      if sql == "SELECT 1" then return "v\n-\n1\n" end
    end))
    local stdout, stderr, code = run("SELECT * FROM x")
    eq(code, 1, "error exit code")
    eq(stdout, MSG_208, "error text on stdout")
    eq(stderr, "", "stderr")
    local entry = pool._entries()[key]
    assert(entry and not entry.dead, "entry should survive a server error")

    stdout, _, code = run("SELECT 1")
    eq(code, 0, "next batch succeeds")
    eq(stdout, "v\n-\n1\n", "next batch stdout")
    assert(pool._entries()[key] == entry, "same entry reused")
  end)
end)

test("run: lookalike result rows and level 10 messages are not errors", function()
  with_pool(function()
    pool._set_spawner(fake_sqlcmd(function()
      return "a\tb\n-\t-\nMsg 1, Level 16, State 1, Server s, Line 1\tx\nMsg 1, Level 16, fake\n"
        .. "Msg 50000, Level 10, State 1, Server s, Line 1\njust info\n"
    end))
    local _, _, code = run("SELECT 1")
    eq(code, 0, "exit code")
  end)
end)

-- go-sqlcmd hangs after a fatal (level >= 20) error instead of exiting; the
-- pool must give up at once rather than wait out the query timeout.
test("run: fatal error stops waiting and drops the entry", function()
  with_pool(function()
    pool._set_spawner(function(_, opts, on_exit)
      return {
        write = function(_, payload)
          if payload then opts.stdout(nil, "Msg 50000, Level 20, State 1, Server s, Line 1\nfatal\n") end
        end,
        kill = function() on_exit({ code = -1 }) end,
      }
    end)
    local started = vim.uv.now()
    local stdout, _, code = run("RAISERROR('fatal', 20, 1) WITH LOG", 10000)
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
  with_pool(function()
    pool._set_spawner(function(_, opts, on_exit)
      return {
        write = function()
          opts.stdout(nil, MSG_208)
          on_exit({ code = 1 })
        end,
        kill = function() end,
      }
    end)
    local stdout, _, code = run("SELECT * FROM x")
    eq(code, 1, "exit code")
    eq(stdout, MSG_208, "stdout")
    assert(pool._entries()[key] == nil, "dead entry should be dropped")
  end)
end)

test("run: output past the sentinel returns the batch, then discards the entry", function()
  with_pool(function()
    local spawner, procs = fake_sqlcmd(function() return "v\n-\n1\n" end, { after = "stray\n" })
    pool._set_spawner(spawner)
    local stdout, _, code = run("SELECT 1")
    eq(code, 0, "exit code")
    eq(stdout, "v\n-\n1\n", "stdout")
    assert(pool._entries()[key] == nil, "entry should be discarded")
    assert(procs[1].killed, "process should be killed")
  end)
end)

test("run: output while idle makes the next batch use a fresh process", function()
  with_pool(function()
    local spawner, procs = fake_sqlcmd()
    pool._set_spawner(spawner)
    run("SELECT 1")
    procs[1].stdout("unexpected\n")
    run("SELECT 1")
    eq(#procs, 2, "processes")
    assert(procs[1].killed, "first process should be killed")
  end)
end)

-- Test: a process that died while idle is replaced, and the replacement keeps
-- the tabs that were using the connection.
test("run: dead idle entry is replaced and keeps its tabs", function()
  with_pool(function()
    local spawner, procs = fake_sqlcmd()
    pool._set_spawner(spawner)
    run("SELECT 1")
    pool._entries()[key].tabs[12345] = true
    procs[1].exit(1)
    local _, _, code = run("SELECT 1")
    eq(code, 0, "exit code")
    eq(#procs, 2, "processes")
    assert(pool._entries()[key].tabs[12345], "tabs carried over")
  end)
end)

-- Test: the idle timer of a process that died must not remove its replacement
-- from the pool (which orphaned the new process).
test("run: dead entry's idle timer leaves the replacement alone", function()
  with_pool(function()
    local spawner, procs = fake_sqlcmd()
    pool._set_spawner(spawner)
    cfg.sqlserver_pool_idle_timeout = 100
    run("SELECT 1")
    procs[1].exit(1)
    cfg.sqlserver_pool_idle_timeout = 100000
    run("SELECT 1")
    vim.wait(300)
    assert(pool._entries()[key], "replacement should stay in the pool")
    assert(not procs[2].exited, "replacement should stay alive")
  end)
end)

test("run: idle timeout closes the process", function()
  with_pool(function()
    local spawner, procs = fake_sqlcmd()
    pool._set_spawner(spawner)
    cfg.sqlserver_pool_idle_timeout = 50
    run("SELECT 1")
    vim.wait(1000, function() return procs[1].exited end, 10)
    assert(procs[1].exited and not procs[1].killed, "closed through stdin EOF")
    assert(pool._entries()[key] == nil, "entry dropped")
  end)
end)

-- Test: a failed respawn of a dead entry returns an error (no crash) and
-- removes the dead entry so later callers do not wait on it.
test("run: respawn failure drops dead entry", function()
  with_pool(function()
    local spawner, procs = fake_sqlcmd()
    pool._set_spawner(spawner)
    run("SELECT 1")
    procs[1].exit(1)
    pool._set_spawner(function() error("spawn refused") end)
    local ok, _, stderr, code = pcall(run, "SELECT 1")
    assert(ok, "run should not raise: " .. tostring(stderr))
    eq(code, 1, "exit code")
    assert(stderr:match("^Failed to start sqlcmd"), "stderr: " .. vim.inspect(stderr))
    assert(pool._entries()[key] == nil, "dead entry should be dropped")
  end)
end)

print(string.format("\nSQL Server pool: %d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
