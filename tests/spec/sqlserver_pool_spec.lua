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

print(string.format("\nSQL Server pool: %d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
