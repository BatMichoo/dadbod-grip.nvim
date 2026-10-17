-- metadata_open_spec.lua: a sidebar folder (Keys, Columns, ...) opens a grid on
-- that view without querying the rows or touching the query pad. The SELECT
-- runs once the user switches to the records.
-- Uses tests/seed_sqlite.db.

local grip = require("dadbod-grip")
local db = require("dadbod-grip.db")
local view = require("dadbod-grip.view")
local qp = require("dadbod-grip.query_pad")

local url = "sqlite:tests/seed_sqlite.db"
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local function cleanup()
  for bufnr in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

test("a folder view opens without the rows; records load on switch", function()
  cleanup()
  local selects, synced = {}, {}
  local real_query, real_sync = db.query, qp.sync_query
  db.query = function(sql, u)
    if sql:match("^SELECT %* FROM") then selects[#selects + 1] = sql end
    return real_query(sql, u)
  end
  qp.sync_query = function(sql) synced[#synced + 1] = sql end
  local ok, err = pcall(function()
    grip.open("users", url, { metadata_view = "fk" })
    vim.wait(20)
    local bufnr, session = next(view._sessions)
    assert(session, "no grid opened")
    assert(session.current_view == "fk", "grid is not on the Keys view: " .. tostring(session.current_view))
    assert(#selects == 0, "rows were queried: " .. tostring(selects[1]))
    assert(#synced == 0, "query pad was synced")

    view.switch_view(bufnr, "records")
    assert(#selects == 1, "records were not queried on switch")
    assert(#session.state.rows > 0, "records grid is empty")
    assert(#session.state.pks > 0, "primary key missing after the records load")
    assert(synced[1] and synced[1]:match("FROM users"), "pad not synced on switch")
    assert(not session.records_pending, "still pending after the load")
  end)
  db.query, qp.sync_query = real_query, real_sync
  cleanup()
  assert(ok, err)
end)

print(string.format("\nmetadata_open_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
