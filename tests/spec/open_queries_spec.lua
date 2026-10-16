-- open_queries_spec.lua: opening a table runs only its SELECT.
-- Each extra round-trip is a whole login for sqlcmd, so there is no COUNT(*)
-- and no column-type lookup on open; column types load with the Columns view.
local grip = require("dadbod-grip")
local db = require("dadbod-grip.db")
local view = require("dadbod-grip.view")

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local URL = "sqlserver://u:p@host/app"

--- Open `orders` against stubbed db calls returning `page_rows` rows per page.
--- fn receives the grid buffer and the list of queries/lookups made since.
local function with_grid(page_rows, fn)
  local saved = {}
  for _, k in ipairs({ "query", "get_primary_keys", "get_column_info", "is_readonly" }) do saved[k] = db[k] end
  local calls = {}
  db.query = function(sql)
    if sql:find("COUNT%(%*%)") then
      calls[#calls + 1] = "count"
      return { columns = { "_grip_count" }, rows = { { "250" } } }
    end
    calls[#calls + 1] = "page"
    local rows = {}
    for i = 1, page_rows do rows[i] = { tostring(i) } end
    return { columns = { "id" }, rows = rows }
  end
  db.get_primary_keys = function() return {} end
  db.get_column_info = function() calls[#calls + 1] = "columns"; return {} end
  db.is_readonly = function() return true end
  local orig_notify = vim.notify
  vim.notify = function() end
  grip.setup({ limit = 1000 })
  local ok, err = pcall(function()
    grip.open("orders", URL)
    local buf = vim.api.nvim_get_current_buf()
    assert(view._sessions[buf], "grid did not open")
    fn(buf, calls)
  end)
  vim.notify = orig_notify
  for k, f in pairs(saved) do db[k] = f end
  for b in pairs(view._sessions) do view._sessions[b] = nil; pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  if not ok then error(err) end
end

test("opening a table runs its capped SELECT only", function()
  with_grid(1000, function(buf, calls)
    vim.wait(50)
    eq(table.concat(calls, ","), "page", "no COUNT and no column lookup")
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert(text:find("1000 rows (TOP 1000)", 1, true), "status shows the cap: " .. text)
  end)
end)

test("raw SQL runs exactly as written, with no cap", function()
  with_grid(5, function()
    local sent
    db.query = function(sql) sent = sql; return { columns = { "id" }, rows = { { "1" } } } end
    grip.open("SELECT id FROM orders WHERE x = 1", URL)
    eq(sent, "SELECT id FROM orders WHERE x = 1", "no wrapper, no LIMIT")
  end)
end)

test("sorting runs the query again and no COUNT", function()
  with_grid(1000, function(buf, calls)
    local s = view._sessions[buf]
    s.on_requery(buf, require("dadbod-grip.query").toggle_sort(s.query_spec, "id"))
    eq(table.concat(calls, ","), "page,page", "sort: one query")
  end)
end)

print(string.format("\nopen_queries_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
