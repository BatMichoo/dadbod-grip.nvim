-- neo_tree_spec.lua: the schema sidebar as a neo-tree source, driven through
-- a real neo-tree.nvim against the seeded SQLite database.
--
-- neo-tree, nui.nvim and plenary.nvim are looked up as sibling directories in
-- GRIP_NEO_TREE_DIR (default: lazy.nvim's ~/.local/share/nvim/lazy). Skips
-- when they are missing, unless GRIP_REQUIRE_NEO_TREE=1.

dofile("tests/minimal_init.lua")

local PLUGINS = { "nui.nvim", "plenary.nvim", "neo-tree.nvim" }
local dir = vim.env.GRIP_NEO_TREE_DIR or (vim.env.HOME .. "/.local/share/nvim/lazy")

for _, name in ipairs(PLUGINS) do
  if vim.fn.isdirectory(dir .. "/" .. name) == 0 then
    if vim.env.GRIP_REQUIRE_NEO_TREE == "1" then
      error("neo_tree_spec: " .. dir .. "/" .. name .. " not found while GRIP_REQUIRE_NEO_TREE=1")
    end
    print("SKIP: neo_tree_spec (" .. name .. " not found in " .. dir .. ")")
    print("\nneo_tree_spec: 0 passed, 0 failed (skipped)")
    return
  end
end
for _, name in ipairs(PLUGINS) do vim.opt.rtp:append(dir .. "/" .. name) end

local grip = require("dadbod-grip")
local schema = require("dadbod-grip.schema")
local source = require("dadbod-grip.neo_tree")

local URL = "sqlite:" .. vim.fn.getcwd() .. "/tests/seed_sqlite.db"
local pass, fail = 0, 0
local orig_opts = grip.get_opts()
local orig_notify = vim.notify

--- A fresh tab per test: neo-tree keeps a tree (and what is expanded in it)
--- per tab, which would otherwise carry from one test into the next.
local function reset()
  pcall(source.close)
  vim.cmd("tabnew")
  vim.cmd("silent! tabonly")
  schema._reset_state()
  source.url = nil
end

local function test(name, fn)
  reset()
  local ok, err = pcall(fn)
  vim.notify = orig_notify
  reset()
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

local function tree_state()
  return require("neo-tree.sources.manager").get_state("grip")
end

local function lines()
  return vim.api.nvim_buf_get_lines(tree_state().bufnr, 0, -1, false)
end

--- Put the cursor on the first tree line containing `text`, after `after`.
local function cursor_to(text, after)
  local seen = after == nil
  for i, line in ipairs(lines()) do
    if not seen and line:find(after, 1, true) then seen = true end
    if seen and line:find(text, 1, true) then
      vim.api.nvim_set_current_win(schema.get_winid())
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  error("no tree line with " .. text .. ":\n" .. table.concat(lines(), "\n"))
end

local function has_line(text)
  for _, line in ipairs(lines()) do
    if line:find(text, 1, true) then return true end
  end
  return false
end

local function commands() return require("dadbod-grip.neo_tree.commands") end

-- Before neo-tree knows the source, grip keeps its own sidebar.
test("without the source registered grip falls back to its own sidebar, once", function()
  grip.setup({ sidebar = "neo-tree" })
  local warnings = {}
  vim.notify = function(msg, level)
    if level == vim.log.levels.WARN then table.insert(warnings, msg) end
  end
  schema.toggle(URL)
  eq(vim.bo[vim.api.nvim_win_get_buf(schema.get_winid())].filetype, "grip_schema", "built-in sidebar")
  schema.close()
  schema.toggle(URL)
  schema.close()
  eq(#warnings, 1, "warned once")
  assert(warnings[1]:find("dadbod-grip.neo_tree", 1, true), warnings[1])
end)

require("neo-tree").setup({ sources = { "filesystem", "dadbod-grip.neo_tree" } })

test("the built-in sidebar stays the default", function()
  grip.setup({})
  schema.toggle(URL)
  eq(vim.bo[vim.api.nvim_win_get_buf(schema.get_winid())].filetype, "grip_schema", "built-in sidebar")
  schema.close()
end)

grip.setup({ sidebar = "neo-tree" })

test("toggle shows the catalog in neo-tree and focuses it", function()
  schema.toggle(URL)
  local win = schema.get_winid()
  assert(win, "no neo-tree window")
  eq(win, vim.api.nvim_get_current_win(), "tree focused")
  eq(vim.bo[vim.api.nvim_win_get_buf(win)].filetype, "neo-tree", "filetype")
  assert(schema.is_open(), "is_open")
  assert(has_line("Tables (12)") and has_line("Views (1)"), table.concat(lines(), "\n"))
  assert(has_line("users") and has_line("no_pk_view"), "objects listed")
end)

test("toggling from inside the tree closes it; from outside reopens it", function()
  schema.toggle(URL)
  schema.toggle(URL)
  assert(not schema.is_open(), "closed from inside")
  schema.toggle(URL)
  assert(schema.is_open(), "reopened")
end)

test("<CR> on a table expands its folders without a query", function()
  schema.toggle(URL)
  cursor_to("users")
  commands().open(tree_state())
  assert(has_line("Columns") and has_line("Keys") and has_line("Indexes"), table.concat(lines(), "\n"))
  eq(schema.get_state(URL).col_cache.users, nil, "no column query before the folder opens")
end)

test("expanding a folder fetches and lists its metadata", function()
  schema.toggle(URL)
  cursor_to("users")
  commands().open(tree_state())
  cursor_to("Columns", "users")
  commands().toggle_node(tree_state())
  assert(has_line("Columns (5)"), "count once loaded:\n" .. table.concat(lines(), "\n"))
  assert(has_line("email") and has_line("created_at"), "columns listed")
  assert(schema.get_state(URL).col_cache.users, "fetched into the shared cache")
end)

test("refresh refetches and keeps an open folder filled", function()
  schema.toggle(URL)
  cursor_to("users")
  commands().open(tree_state())
  cursor_to("Columns", "users")
  commands().toggle_node(tree_state())
  local before = schema.get_state(URL).col_cache.users
  vim.notify = function() end
  commands().refresh(tree_state())
  local after = schema.get_state(URL).col_cache.users
  assert(after and after ~= before, "redrawing the open folder fetched its columns again")
  assert(has_line("Columns (5)") and has_line("email"), "folder still open:\n" .. table.concat(lines(), "\n"))
end)

test("s opens the table's records outside the tree", function()
  local view = require("dadbod-grip.view")
  schema.toggle(URL)
  cursor_to("orders")
  commands().open_records(tree_state())
  local buf = vim.api.nvim_get_current_buf()
  assert(view._sessions[buf], "a grid is focused")
  eq(view._sessions[buf].state.table_name, "orders", "grid table")
  assert(vim.api.nvim_get_current_win() ~= schema.get_winid(), "grid not in the tree window")
  eq(vim.bo[vim.api.nvim_win_get_buf(schema.get_winid())].filetype, "neo-tree", "tree still shown")
end)

test("<F5> runs a table's records and nothing on other rows", function()
  local view = require("dadbod-grip.view")
  schema.toggle(URL)
  local tree_buf = tree_state().bufnr
  eq(vim.fn.maparg("<F5>", "n", false, true).buffer, 1, "mapped in the grip source's buffer")
  cursor_to("users")
  commands().open(tree_state())
  cursor_to("Columns", "users")
  vim.api.nvim_feedkeys(vim.keycode("<F5>"), "x", false)
  eq(vim.api.nvim_get_current_buf(), tree_buf, "a folder has no query to run")
  cursor_to("orders")
  vim.api.nvim_feedkeys(vim.keycode("<F5>"), "x", false)
  local session = view._sessions[vim.api.nvim_get_current_buf()]
  assert(session, "a grid is focused")
  eq(session.state.table_name, "orders", "grid table")
end)

test("connecting lays the workspace out beside the tree", function()
  local paths = require("dadbod-grip.paths")
  local orig_root = paths.project_root
  local project = vim.fn.tempname()
  vim.fn.mkdir(project, "p")
  paths.project_root = function() return project end
  vim.notify = function() end
  local ok, err = pcall(function()
    eq(require("dadbod-grip.connections").switch(URL, "seed"), true, "committed")
    vim.wait(1000, function() return schema.is_open() end)
    assert(schema.is_open(), "tree opened on connect")
    -- The pad by its buffer, not its name: other specs swap that buffer out.
    local pad_buf = require("dadbod-grip.query_pad").get_pad_bufnr()
    local fts, pad = {}, false
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      fts[vim.bo[buf].filetype] = true
      pad = pad or buf == pad_buf
    end
    assert(fts["neo-tree"] and fts["grip-welcome"] and pad, vim.inspect(fts))
    assert(not fts.grip_schema, "built-in sidebar not opened as well")
    eq(source.url, URL, "tree shows the new connection")
  end)
  paths.project_root = orig_root
  vim.g.db = nil
  vim.fn.delete(project, "rf")
  if not ok then error(err, 0) end
end)

grip.setup(orig_opts)

print(string.format("\nneo_tree_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
