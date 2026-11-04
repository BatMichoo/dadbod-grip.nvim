-- neo_tree/init.lua: the schema sidebar as a neo-tree source.
--
-- Listed in neo-tree's `sources` as "dadbod-grip.neo_tree", it shows the
-- connection's catalog in a neo-tree window; with setup({ sidebar = "neo-tree" })
-- grip opens that window wherever it would open its own sidebar. The catalog,
-- its caches and every action belong to schema.lua: this module only turns
-- schema_tree.nested() into neo-tree items and keeps the window up to date.
--
-- Requiring this module must work without neo-tree installed (schema.lua asks
-- it whether neo-tree is available), so neo-tree is only required lazily.

local M = {
  name = "grip",
  display_name = " 󰆼 Grip ",
}

local ROOT_ID = "grip\0root"

--- The connection the tree shows. Set by grip when it opens or refreshes the
--- sidebar; `:Neotree grip` on its own falls back to the current connection.
M.url = nil

local function current_url()
  return M.url or require("dadbod-grip.db").get_url()
end

--- Convert a schema_tree node into a neo-tree item. Anything with children,
--- or a folder whose children are not fetched yet, is a "directory": neo-tree
--- only offers to expand directories and nodes that already have children.
local function to_item(node)
  local extra = {}
  for k, v in pairs(node) do
    if k ~= "children" then extra[k] = v end
  end
  local item = { id = node.id, name = node.name, extra = extra }
  if node.children then
    item.type = "directory"
    item.loaded = true
    item.children = vim.tbl_map(to_item, node.children)
  elseif node.kind == "facet" then
    item.type = "directory"
    item.loaded = false
  else
    item.type = "file"
  end
  return item
end
M._to_item = to_item

--- Fetch one table folder's metadata and return the folder rebuilt with its
--- children. Used on expand and when a refresh redraws an open folder.
function M._load_facet(url, node)
  local schema = require("dadbod-grip.schema")
  local tree = require("dadbod-grip.schema_tree")
  local facet
  for _, f in ipairs(tree.FACETS) do
    if f.key == node.facet then facet = f end
  end
  schema.load_facet(url, node.table_name, node.facet)
  return tree.facet_node(schema.get_state(url), node.table_id, node.table_name, facet)
end

--- The tree for one connection, with every folder that is already expanded
--- in `expanded` (a set of node ids) loaded, so a refresh keeps them filled.
local function build(url, expanded)
  local schema = require("dadbod-grip.schema")
  local tree = require("dadbod-grip.schema_tree")
  local state = schema.prefetch(url)
  local children
  if state.file_cols then
    local columns = {}
    for _, col in ipairs(state.file_cols) do
      columns[#columns + 1] = { kind = "column", id = "file\0column\0" .. col.column_name,
        name = col.column_name, data_type = col.data_type, is_file = true }
    end
    children = { { kind = "table", id = "file", name = schema.title(state), is_file = true,
      children = columns } }
  else
    children = tree.nested(state)
    local function fill(nodes)
      for _, node in ipairs(nodes) do
        if node.kind == "facet" and not node.children and expanded[node.id] then
          local loaded = M._load_facet(url, node)
          node.name, node.children = loaded.name, loaded.children
        elseif node.children then
          fill(node.children)
        end
      end
    end
    fill(children)
  end
  local root = { kind = "root", id = ROOT_ID, name = schema.title(state), children = children }
  if #children == 0 then
    root.children = { { kind = "message", id = "grip\0empty", name = state.items and "(database empty)"
      or "(could not load the schema)" } }
  end
  return to_item(root), state
end

--- neo-tree's entry point for drawing the source.
function M.navigate(state, path, path_to_reveal, callback, async)
  local renderer = require("neo-tree.ui.renderer")
  local url = current_url()
  state.grip_url = url
  -- manager.refresh() redraws only states with a path; anything else is
  -- just marked dirty. Not the URL itself, which can carry a password.
  state.path = "grip://schema"
  if not url then
    renderer.show_nodes({ { id = ROOT_ID, name = "No database connection", type = "message" } },
      state, nil, callback)
    return
  end
  local expanded = {}
  if state.tree then
    for _, id in ipairs(renderer.get_expanded_nodes(state.tree)) do expanded[id] = true end
    state.default_expanded_nodes = nil
  else
    -- First draw: the connection and its categories open, as in grip's sidebar.
    state.default_expanded_nodes = { ROOT_ID }
  end
  local root = build(url, expanded)
  if not state.tree then
    for _, child in ipairs(root.children or {}) do
      table.insert(state.default_expanded_nodes, child.id)
      if child.extra.kind == "schema" then
        for _, category in ipairs(child.children or {}) do
          table.insert(state.default_expanded_nodes, category.id)
        end
      end
    end
  end
  renderer.show_nodes({ root }, state, nil, callback)
end

M.default_config = {
  renderers = {
    directory = { { "indent" }, { "grip_icon" }, { "grip_name" } },
    file = { { "indent" }, { "grip_icon" }, { "grip_name" }, { "grip_detail" } },
    message = { { "indent", with_markers = false }, { "name", highlight = "NeoTreeMessage" } },
  },
  window = {
    mappings = {
      ["<cr>"] = "open",
      ["<2-LeftMouse>"] = "open",
      ["<space>"] = "toggle_node",
      ["s"] = "open_records",
      ["<F5>"] = "execute",
      ["S"] = "open_split",
      ["R"] = "refresh",
      ["y"] = "copy_name",
      -- neo-tree's file operations have nothing to act on here.
      ["a"] = "noop", ["A"] = "noop", ["c"] = "noop", ["d"] = "noop", ["m"] = "noop",
      ["p"] = "noop", ["r"] = "noop", ["t"] = "noop", ["T"] = "noop", ["u"] = "noop",
      ["U"] = "noop", ["w"] = "noop", ["x"] = "noop", ["P"] = "noop", ["l"] = "noop",
      ["<C-r>"] = "noop", ["<C-s>"] = "noop", ["<C-f>"] = "noop", ["<C-b>"] = "noop",
    },
  },
}

function M.setup(config, global_config) end

-- ── grip's side ────────────────────────────────────────────────────────────
-- What schema.lua calls when setup({ sidebar = "neo-tree" }) is in effect.

--- Whether neo-tree is installed and has this source registered.
function M.available()
  local ok, neo_tree = pcall(require, "neo-tree")
  if not ok then return false end
  -- Recent neo-tree merges setup()'s config on first use; older ones at setup.
  local config = neo_tree.ensure_config and neo_tree.ensure_config() or neo_tree.config
  return type(config) == "table" and vim.tbl_contains(config.sources or {}, M.name)
end

--- The source's window in this tab, or nil when it is not on screen.
function M.winid()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok then return nil end
  local state = manager.get_state(M.name)
  if state.winid and vim.api.nvim_win_is_valid(state.winid)
      and state.bufnr and vim.api.nvim_win_get_buf(state.winid) == state.bufnr then
    return state.winid
  end
  return nil
end

local function execute(args)
  args.source = M.name
  require("neo-tree.command").execute(args)
end

--- Show the tree for `url` and focus it.
function M.show(url)
  local switched = url and url ~= M.url
  M.url = url or M.url
  if switched and M.winid() then
    require("neo-tree.sources.manager").refresh(M.name)
  end
  execute({ action = "focus" })
end

--- grip's sidebar toggle: focus the tree, or close it when already inside.
function M.toggle(url)
  local win = M.winid()
  if win and win == vim.api.nvim_get_current_win() and (not url or url == M.url) then
    return M.close()
  end
  M.show(url)
end

function M.close()
  if M.winid() then execute({ action = "close" }) end
end

--- Redraw the tree for `url` (its caches already cleared) if it is on screen.
function M.refresh(url)
  M.url = url or M.url
  if M.winid() then require("neo-tree.sources.manager").refresh(M.name) end
end

return M
