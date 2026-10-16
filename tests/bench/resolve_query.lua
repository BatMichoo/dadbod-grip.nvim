-- Run from the checkout: nvim --headless -u NONE -i NONE -l tests/bench/resolve_query.lua [ref]
-- Compares the working parser with ref (default HEAD), using current dependencies.
-- Timings are machine-local diagnostics, never pass/fail thresholds.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.rtp:prepend(root)
local ref = arg[1] or "HEAD"
local historical = vim.system({ "git", "-C", root, "show", ref .. ":lua/dadbod-grip/init.lua" },
  { text = true }):wait()
assert(historical.code == 0, historical.stderr)
local baseline = assert(loadstring(historical.stdout, "@" .. ref .. "/init.lua"))()._resolve_query
local current = require("dadbod-grip")._resolve_query
local resolvers = { baseline, current }
local cases = {
  { "short SELECT", "SELECT id, status FROM orders" },
  { "WHERE + ORDER", "SELECT id, status FROM orders WHERE status = 'pending' ORDER BY id LIMIT 100" },
  { "UPDATE", "UPDATE orders SET status = 'pending' WHERE id = 1" },
}
for _, count in ipairs({ 1000, 5000, 10000 }) do
  local literals = {}
  for i = 1, count do literals[i] = "$tag$value" .. i .. "$tag$" end
  cases[#cases + 1] = {
    "dollar x" .. count,
    "SELECT id, status FROM orders WHERE status IN (" .. table.concat(literals, ",") .. ")",
  }
end
local numbers = {}
for i = 1, 20000 do numbers[i] = tostring(i) end
cases[#cases + 1] = { "numeric IN", "SELECT id FROM orders WHERE id IN (" .. table.concat(numbers, ",") .. ")" }

-- Historical versions may contain known safety bugs; require the current parser
-- to reject a real set operation even after scanning many dollar literals.
local union_sql = cases[6][2] .. " UNION ALL SELECT id, status FROM other"
local union_spec, union_table = current(union_sql, 100, "postgresql")
assert(union_spec.base_sql == union_sql and union_table == nil, "UNION must stay read-only")

local sink = 0
local function measure(resolve, sql, count)
  local start = vim.uv.hrtime()
  for _ = 1, count do
    local spec, table_name, _, mutation = resolve(sql, 100, "postgresql")
    sink = sink + (spec and spec.limit or 0) + (table_name and #table_name or 0)
      + (mutation and #mutation or 0)
  end
  return (vim.uv.hrtime() - start) / count / 1000
end
print("Resolver timings (microseconds/call), baseline=" .. ref .. ", current=working tree")
print(string.format("%-17s %8s %12s %12s %9s", "input", "bytes", "baseline us", "current us", "ratio"))
for case_index, case in ipairs(cases) do
  local name, sql = case[1], case[2]
  local before = { baseline(sql, 100, "postgresql") }
  local after = { current(sql, 100, "postgresql") }
  assert(vim.deep_equal(before, after), name .. ": resolver result changed")
  if name == "UPDATE" then
    assert(after[1] == nil and after[4] == sql, "UPDATE routing changed")
  else
    assert(after[2] == "orders" and after[1].base_sql == sql, name .. ": query metadata changed")
  end
  local iterations, samples = {}, { {}, {} }
  for index, resolve in ipairs(resolvers) do
    local warmup = #sql < 20000 and 40 or 3
    for _ = 1, 3 do measure(resolve, sql, warmup) end
    collectgarbage("collect")
    local estimate = measure(resolve, sql, warmup)
    iterations[index] = math.max(3, math.min(10000, math.floor(20000 / math.max(estimate, 0.1))))
  end
  for batch = 1, 9 do
    for offset = 1, 2 do
      local index = (batch + offset + case_index) % 2 + 1
      collectgarbage("collect")
      samples[index][#samples[index] + 1] = measure(resolvers[index], sql, iterations[index])
    end
  end
  table.sort(samples[1])
  table.sort(samples[2])
  local old, new = samples[1][5], samples[2][5]
  print(string.format("%-17s %8d %12.3f %12.3f %8.2fx", name, #sql, old, new, new / old))
end
assert(sink > 0, "benchmark did not execute")
print("Query specs, editable table metadata, UPDATE routing, and current UNION safety verified.")
