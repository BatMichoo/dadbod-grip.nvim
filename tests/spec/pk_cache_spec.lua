-- pk_cache_spec.lua: db.get_primary_keys caches per connection and table, and
-- DDL or an explicit clear drops the cache. Every lookup is a round-trip (a
-- whole login for sqlcmd), and each grid load or refresh asks for the keys.

local db = require("dadbod-grip.db")

local url = "sqlite:tests/seed_sqlite.db"
local sqlite = require("dadbod-grip.adapters.sqlite")

local pass, fail = 0, 0
local function eq(a, b, msg)
  if a == b then pass = pass + 1 else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected: %s\n  got:      %s", msg, tostring(b), tostring(a)))
  end
end

local calls = 0
local real = sqlite.get_primary_keys
sqlite.get_primary_keys = function(...)
  calls = calls + 1
  return real(...)
end

db.clear_key_cache()

local pks = db.get_primary_keys("users", url)
eq(pks[1], "id", "first lookup returns the key")
eq(calls, 1, "first lookup queries")

pks[1] = "mutated"
eq(db.get_primary_keys("users", url)[1], "id", "callers get a copy")
eq(calls, 1, "second lookup is served from the cache")

db.get_primary_keys("orders", url)
eq(calls, 2, "another table queries")

db.query("SELECT 1", url)
db.get_primary_keys("users", url)
eq(calls, 2, "a SELECT keeps the cache")

db.query("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY)", url)
db.get_primary_keys("users", url)
eq(calls, 3, "DDL clears the cache")

db.clear_key_cache(url)
db.get_primary_keys("users", url)
eq(calls, 4, "clear_key_cache(url) forces a lookup")

sqlite.get_primary_keys = real
db.clear_key_cache()

print(string.format("\npk_cache_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
