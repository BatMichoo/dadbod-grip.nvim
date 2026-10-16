-- connections_spec.lua -- characterization tests for M.switch()'s single-pass
-- read/mutate/write behavior (see history.lua's task-8 companion refactor).
-- M.switch() used to read the local connections file up to 4 times and write
-- it up to twice per call; it now reads once (plus the global file, but only
-- when actually needed for type resolution) and writes at most once. These
-- tests pin the observable behavior of that rewrite against real files in an
-- isolated temp directory, since nothing in the suite previously exercised it.
local paths = require("dadbod-grip.paths")
local grip = require("dadbod-grip")

-- Rebound to a freshly loaded module by every with_real_file() below, because
-- connections.lua keeps per-URL health in a module-local table with no reset
-- hook: without the reload, a switch() in one test leaves its URL marked "ok"
-- for every later case.
local connections = require("dadbod-grip.connections")

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

-- ── real-file harness ────────────────────────────────────────────────────
-- M.switch() is heavily side-effecting: it opens the grid/schema/query pad
-- via vim.schedule(). These tests only care about the synchronous file-write
-- behavior, so UI-facing modules are stubbed to no-ops. Pending vim.schedule
-- callbacks are flushed with vim.wait() *before* teardown (while the stubs
-- and the fake project/home dirs are still live), so nothing fires later
-- against an already-deleted temp directory or a restored real module.
--
-- Isolation notes:
-- - paths.project_root is patched (not paths.grip_dir): connections.lua
--   captures `local grip_dir = paths.grip_dir` at require time, so patching
--   the grip_dir *field* on the module later would not affect that alias.
--   The captured function still calls `M.project_root()` dynamically though,
--   so patching project_root reaches it either way.
-- - vim.fn.expand("~") is patched to a fake home so the global connections
--   file used by tests never touches the real ~/.grip/connections.json.
-- - the module under test is reloaded per call so its module-local state
--   (notably the _health table set_health writes to) starts empty; the
--   file-level `connections` alias is rebound to that instance.
local function with_real_file(fn)
  local project_dir = vim.fn.tempname() .. "_grip_conn_test"
  local fake_home = project_dir .. "_home"
  vim.fn.mkdir(project_dir, "p")
  vim.fn.mkdir(fake_home, "p")

  local orig_project_root = paths.project_root
  local orig_expand = vim.fn.expand
  local orig_notify = vim.notify
  local orig_g_db = vim.g.db
  local orig_opts = grip.get_opts()
  local orig_open = grip.open
  local orig_open_welcome = grip.open_welcome
  local orig_schema = package.loaded["dadbod-grip.schema"]
  local orig_query_pad = package.loaded["dadbod-grip.query_pad"]
  local orig_duckdb = package.loaded["dadbod-grip.adapters.duckdb"]
  local orig_connections = package.loaded["dadbod-grip.connections"]

  paths.project_root = function() return project_dir end
  vim.fn.expand = function(a, ...)
    if a == "~" then return fake_home end
    return orig_expand(a, ...)
  end
  vim.notify = function() end
  grip.setup({}) -- deterministic OPTS baseline (connections_path = nil, etc.)
  grip.open = function() end
  grip.open_welcome = function() end
  package.loaded["dadbod-grip.schema"] = {
    is_open = function() return true end,
    refresh = function() end,
    toggle = function() end,
    get_winid = function() return nil end,
    -- switch() prefetches the schema under the preloader, before it opens
    -- any window; the double has to answer that call too.
    prefetch = function() return {} end,
  }
  package.loaded["dadbod-grip.query_pad"] = { open = function() end }
  package.loaded["dadbod-grip.adapters.duckdb"] = { load_attachments = function() end }
  package.loaded["dadbod-grip.connections"] = nil
  connections = require("dadbod-grip.connections")

  local local_grip = project_dir .. "/.grip"
  local global_grip = fake_home .. "/.grip"
  local ok, err = pcall(fn, local_grip, global_grip)
  vim.wait(50) -- flush any vim.schedule() callbacks queued by switch()

  paths.project_root = orig_project_root
  vim.fn.expand = orig_expand
  vim.notify = orig_notify
  vim.g.db = orig_g_db
  grip.setup(orig_opts)
  grip.open = orig_open
  grip.open_welcome = orig_open_welcome
  package.loaded["dadbod-grip.schema"] = orig_schema
  package.loaded["dadbod-grip.query_pad"] = orig_query_pad
  package.loaded["dadbod-grip.adapters.duckdb"] = orig_duckdb
  package.loaded["dadbod-grip.connections"] = orig_connections
  connections = orig_connections

  vim.fn.delete(project_dir, "rf")
  vim.fn.delete(fake_home, "rf")
  if not ok then error(err) end
end

--- switch() reports which branch it took from inside a scheduled callback --
--- it notifies after the workspace is on screen, not before it is built -- so
--- the queue has to be flushed before the message can be read.
local function flush_schedules()
  vim.wait(100)
end

local function read_connections_json(dir)
  return vim.fn.json_decode(table.concat(vim.fn.readfile(dir .. "/connections.json"), "\n"))
end

-- ── switching to an existing connection (by name, and without one) ────────

test("switch: switching to an existing connection by name upserts + touches, single write", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "old-name", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 },
    }) }, local_grip .. "/connections.json")

    connections.switch("postgresql://u:p@h/db", "mydb", "postgresql", {})

    local data = read_connections_json(local_grip)
    eq(#data, 1, "still one entry, renamed not duplicated")
    eq(data[1].name, "mydb", "renamed")
    eq(data[1].url, "postgresql://u:p@h/db", "url unchanged")
    eq(data[1].type, "postgresql", "type unchanged")
    assert(data[1].last_used > 100, "last_used touched")
  end)
end)

test("switch: switching to an existing connection without a name still touches last_used", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "saved-name", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 },
    }) }, local_grip .. "/connections.json")

    connections.switch("postgresql://u:p@h/db", nil, "postgresql", {})

    local data = read_connections_json(local_grip)
    eq(#data, 1, "still one entry")
    eq(data[1].name, "saved-name", "name preserved (no rename requested)")
    assert(data[1].last_used > 100, "last_used touched even without a name")
  end)
end)

-- ── write is skipped when nothing changed, happens when it did ────────────

test("switch: write is skipped when nothing changed (unnamed, not-yet-saved URL)", function()
  with_real_file(function(local_grip)
    connections.switch("postgresql://u:p@h/db", nil, "postgresql", {})
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0,
      "no connections.json created -- nothing to persist for a nameless, unsaved connection")
  end)
end)

test("switch: write happens when a name is given for a brand-new URL", function()
  with_real_file(function(local_grip)
    -- Note: the persisted `type` field comes from is_file_url(), not the
    -- conn_type parameter -- that's pre-existing M.add() behavior, unchanged
    -- by this refactor. postgresql:// isn't a file url, so type stays nil.
    connections.switch("postgresql://u:p@h/db", "brand-new", "postgresql", {})
    local data = read_connections_json(local_grip)
    eq(#data, 1, "inserted")
    eq(data[1].name, "brand-new", "name")
    eq(data[1].type, nil, "type field derives from is_file_url, not conn_type")
  end)
end)

-- ── module-local health state does not leak between tests ─────────────────
-- Placed after the switch() cases above on purpose: they all switch to this
-- same URL, so without the per-test module reload in with_real_file the first
-- assertion below reads their leftover "ok" instead of a clean slate.

test("switch: health state starts clean in every test, then switch records it", function()
  with_real_file(function()
    eq(connections.get_health("postgresql://u:p@h/db"), "unknown",
      "no health carried in from an earlier test's switch()")
    connections.switch("postgresql://u:p@h/db", nil, "postgresql", {})
    eq(connections.get_health("postgresql://u:p@h/db"), "ok", "switch marks the connection healthy")
  end)
end)

-- ── global file consulted only when the gate allows it ─────────────────────
-- Signal: the only externally-observable trace of resolved_type is the
-- notify message ("opening" for type == "file" vs "connected to" otherwise).
-- customscheme:// is not detected as a file url by the is_file_url()
-- heuristic, so seeding the global file with type = "file" for it makes the
-- notify text a faithful proxy for "was the global file's type honored".

test("switch: global file is consulted when no local match and no configured path", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, nil, {})

    flush_schedules()
    assert(#notified > 0 and notified[1]:find("opening", 1, true),
      "type resolved from global file, file-open branch should have run: " .. vim.inspect(notified))
  end)
end)

test("switch: global file is not consulted when connections_path is configured", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    grip.setup({ connections_path = local_grip .. "/connections.json" })

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, nil, {})

    flush_schedules()
    assert(#notified > 0 and notified[1]:find("connected to", 1, true),
      "global type must be ignored when connections_path is configured: " .. vim.inspect(notified))
  end)
end)

test("switch: global file is not consulted when conn_type is already given", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, "postgresql", {})

    flush_schedules()
    assert(#notified > 0 and notified[1]:find("connected to", 1, true),
      "explicit conn_type param must win over global lookup: " .. vim.inspect(notified))
  end)
end)

test("switch: global file is not consulted when the type is already known locally", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(local_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "local", url = "customscheme://host/db", type = "postgresql", last_used = 1 },
    }) }, local_grip .. "/connections.json")
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, nil, {})

    flush_schedules()
    assert(#notified > 0 and notified[1]:find("connected to", 1, true),
      "locally-known type must win over global lookup: " .. vim.inspect(notified))
  end)
end)

-- ── attachments-restore reads the pre-mutation snapshot ────────────────────

test("switch: attachments-restore reads the pre-mutation snapshot (rename doesn't disturb .attachments)", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "old", url = "duckdb:/tmp/some.duckdb", type = "duckdb",
        attachments = { "foo.duckdb", "bar.duckdb" }, last_used = 100 },
    }) }, local_grip .. "/connections.json")

    local captured_url, captured_atts
    package.loaded["dadbod-grip.adapters.duckdb"] = {
      load_attachments = function(u, atts) captured_url, captured_atts = u, atts end,
    }

    connections.switch("duckdb:/tmp/some.duckdb", "renamed", "duckdb", {})

    eq(captured_url, "duckdb:/tmp/some.duckdb", "load_attachments called with the right url")
    assert(captured_atts ~= nil, "attachments were restored")
    eq(#captured_atts, 2, "both attachments survived the rename")
    eq(captured_atts[1], "foo.duckdb", "attachment 1")
    eq(captured_atts[2], "bar.duckdb", "attachment 2")

    local data = read_connections_json(local_grip)
    eq(data[1].name, "renamed", "renamed on disk")
    eq(#data[1].attachments, 2, "attachments preserved on disk too")
  end)
end)

-- ── output format matches the pre-refactor multi-pass sequence ─────────────
-- The old M.switch() body was, in effect, M.add(name, url) followed by
-- M.touch(url) -- two separate read+write round trips. M.add()/M.touch()
-- still exist with that exact behavior (now built on the same upsert_conn/
-- touch_conn helpers switch() uses in memory), so running them back-to-back
-- characterizes what the old switch() wrote. os.time() is pinned so both
-- sequences produce the exact same last_used and can be compared byte-for-byte.

test("switch: resulting file is byte-identical to the old add()+touch() sequence for the same inputs", function()
  local orig_os_time = os.time
  -- luacheck: push ignore 122
  os.time = function() return 1700000000 end

  local old_content, new_content
  local seed = { { name = "old-name", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 } }

  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode(seed) }, local_grip .. "/connections.json")
    connections.add("mydb", "postgresql://u:p@h/db")
    connections.touch("postgresql://u:p@h/db")
    old_content = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
  end)

  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode(seed) }, local_grip .. "/connections.json")
    connections.switch("postgresql://u:p@h/db", "mydb", "postgresql", {})
    new_content = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
  end)

  os.time = orig_os_time
  -- luacheck: pop

  eq(old_content, new_content, "byte-identical output for the same logical mutation")
end)

-- ── connection groups (picker folders) ─────────────────────────────────────

--- Run fn with g:dbs set and grip_picker.open captured instead of drawn.
--- fn receives a function returning the most recent open() options.
local function with_picker(dbs, fn)
  local orig_picker = package.loaded["dadbod-grip.grip_picker"]
  local orig_docker = package.loaded["dadbod-grip.sources.docker_localdb"]
  local orig_dbs = vim.g.dbs
  local last
  package.loaded["dadbod-grip.grip_picker"] = { open = function(o) last = o end }
  -- No `docker ps`: setup({ discovery = false }) would outlive this test.
  package.loaded["dadbod-grip.sources.docker_localdb"] = {
    fetch = function() return { connections = {} } end,
  }
  vim.g.dbs = dbs
  local ok, err = pcall(fn, function() return last end)
  package.loaded["dadbod-grip.grip_picker"] = orig_picker
  package.loaded["dadbod-grip.sources.docker_localdb"] = orig_docker
  vim.g.dbs = orig_dbs
  if not ok then error(err) end
end

local function names(items)
  local out = {}
  for _, it in ipairs(items) do table.insert(out, it.name) end
  return table.concat(out, ",")
end

local GROUPED_DBS = {
  { name = "dev-billing", url = "sqlserver://dev/billing", group = "DEV" },
  { name = "dev-orders",  url = "sqlserver://dev/orders",  group = "DEV" },
  { name = "qa-billing",  url = "sqlserver://qa/billing",  group = "QA" },
  { name = "loose",       url = "sqlserver://loose/db" },
}

test("groups: the top level shows one folder per group, ungrouped entries as before", function()
  with_real_file(function()
    with_picker(GROUPED_DBS, function(last)
      connections.pick()
      local items = last().items
      eq(items[1]._folder, "DEV", "folders first, sorted")
      eq(items[1]._count, 2, "DEV member count")
      eq(items[2]._folder, "QA", "second folder")
      local listed = names(items)
      assert(listed:find("loose", 1, true), "ungrouped entry listed: " .. listed)
      assert(not listed:find("dev-billing", 1, true), "grouped entry hidden at top level: " .. listed)
      eq(last().title, "Connections", "top-level title")
      assert(last().display(items[1]):find("DEV", 1, true), "folder row names the group")
    end)
  end)
end)

test("groups: selecting a folder opens it, and .. returns to the top level", function()
  with_real_file(function()
    with_picker(GROUPED_DBS, function(last)
      connections.pick()
      last().on_select(last().items[1])
      eq(last().title, "Connections / DEV", "folder title")
      local items = last().items
      eq(items[1]._up, true, "first row goes back up")
      eq(#items, 3, ".. plus the two DEV connections: " .. names(items))
      local listed = names(items)
      assert(listed:find("dev-billing", 1, true) and listed:find("dev-orders", 1, true), listed)
      assert(not listed:find("qa-billing", 1, true), "other groups excluded: " .. listed)

      last().on_select(items[1])
      eq(last().title, "Connections", "back at the top level")
      eq(last().items[1]._folder, "DEV", "folders shown again")
    end)
  end)
end)

test("groups: a group saved in connections.json survives a switch() rewrite", function()
  with_real_file(function(local_grip)
    vim.fn.mkdir(local_grip, "p")
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "app", url = "sqlite:/tmp/grip_group_test.db", group = "DEV" },
    }) }, local_grip .. "/connections.json")
    connections.switch("sqlite:/tmp/grip_group_test.db", "app")
    eq(read_connections_json(local_grip)[1].group, "DEV", "group kept on write")
  end)
end)

test("groups: a g:dbs group applies to a saved entry with the same URL", function()
  with_real_file(function(local_grip, global_grip)
    vim.fn.mkdir(local_grip, "p")
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev-billing", url = "sqlserver://dev/billing" },
    }) }, local_grip .. "/connections.json")
    with_picker(GROUPED_DBS, function(last)
      connections.pick()
      eq(last().items[1]._count, 2, "the saved entry still counts toward DEV")
    end)
    local global = read_connections_json(global_grip)
    local by_url = {}
    for _, c in ipairs(global) do by_url[c.url] = c end
    eq(by_url["sqlserver://qa/billing"].group, "QA", "group persisted to the global file")
  end)
end)

test("remove: a URL removes only that entry when names repeat across groups", function()
  with_real_file(function(local_grip)
    vim.fn.mkdir(local_grip, "p")
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "billing", url = "sqlserver://dev/billing", group = "DEV" },
      { name = "billing", url = "sqlserver://qa/billing",  group = "QA" },
    }) }, local_grip .. "/connections.json")
    connections.remove("billing", "sqlserver://dev/billing")
    local left = read_connections_json(local_grip)
    eq(#left, 1, "one entry left")
    eq(left[1].url, "sqlserver://qa/billing", "the QA entry survives")
  end)
end)

-- ── setup({ databases }) ────────────────────────────────────────────────────

local DATABASES = {
  servers = { DEV = "dev-sql", QA = "qa-sql" },
  definitions = {
    { name = "billing", db = "billing", servers = { "DEV", "QA", "MISSING" },
      auth = { user = "app", password = "pw", authentication = "ActiveDirectoryDefault" } },
    { name = "reports", scheme = "postgres", db = "rpt", servers = { "DEV" } },
    { name = "legacy", url = "sqlserver://legacy-host/old", servers = { "QA" } },
    { name = "scratch", url = "sqlite:/tmp/scratch.db" },
  },
}

test("from_databases: one connection per server, grouped and named by key", function()
  local by_name = {}
  for _, c in ipairs(connections.from_databases(DATABASES)) do by_name[c.name] = c end
  eq(by_name["DEV - billing"].url,
    "sqlserver://app:pw@dev-sql:1433/billing?authentication=ActiveDirectoryDefault",
    "built URL: userinfo, default port, other auth keys as query")
  eq(by_name["DEV - billing"].group, "DEV", "group is the server key")
  eq(by_name["QA - billing"].url,
    "sqlserver://app:pw@qa-sql:1433/billing?authentication=ActiveDirectoryDefault", "QA host")
  eq(by_name["MISSING - billing"], nil, "server key without a host is skipped")
  eq(by_name["DEV - reports"].url, "postgres://dev-sql:5432/rpt", "scheme picks its default port")
end)

test("from_databases: a definition url wins and is listed once", function()
  local by_name = {}
  for _, c in ipairs(connections.from_databases(DATABASES)) do by_name[c.name] = c end
  eq(by_name["QA - legacy"].url, "sqlserver://legacy-host/old", "url used as-is")
  eq(by_name["QA - legacy"].group, "QA", "grouped under its first server key")
  eq(by_name["scratch"].url, "sqlite:/tmp/scratch.db", "no group: plain name")
  eq(by_name["scratch"].group, nil, "no group")
end)

test("databases option: picker shows the folders, nothing is written to the global file", function()
  with_real_file(function(_, global_grip)
    with_picker(nil, function(last)
      grip.setup({ databases = DATABASES })
      connections.pick()
      local items = last().items
      eq(items[1]._folder, "DEV", "DEV folder")
      eq(items[1]._count, 2, "billing + reports")
      eq(items[2]._folder, "QA", "QA folder")
      eq(items[2]._count, 2, "billing + legacy")
      assert(names(items):find("scratch", 1, true), "ungrouped entry at the top level")
      eq(vim.fn.filereadable(global_grip .. "/connections.json"), 0,
        "config connections are not copied to the global file")
    end)
  end)
end)

test("databases option: rejects a non-table value", function()
  assert(not pcall(grip.setup, { databases = "nope" }), "string rejected")
  grip.setup({})
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nconnections_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
