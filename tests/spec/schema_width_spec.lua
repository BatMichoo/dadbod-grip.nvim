-- Complete names are verified in schema_browser_spec; these remain viewport sizing contracts.
dofile("tests/minimal_init.lua")
local schema = require("dadbod-grip.schema")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end

test("sidebar resize clamps at 80/100/160 columns without regrowing a narrow sidebar", function()
  eq(schema._sidebar_width_for(80), 24, "automatic width at 80 columns")
  eq(schema._sidebar_width_for(100), 25, "automatic width at 100 columns")
  eq(schema._sidebar_width_for(160), 36, "automatic width at 160 columns")
  eq(schema._clamp_sidebar_width(36, 80), 24, "80-column editor")
  eq(schema._clamp_sidebar_width(36, 100), 25, "100-column editor")
  eq(schema._clamp_sidebar_width(36, 160), 36, "160-column editor")
  eq(schema._clamp_sidebar_width(20, 160), 20, "deliberately narrow sidebar stays narrow")
  eq(schema._clamp_sidebar_width(schema._clamp_sidebar_width(36, 80), 160), 24,
    "growing editor does not automatically regrow sidebar")
end)

print(string.format("schema_width_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
