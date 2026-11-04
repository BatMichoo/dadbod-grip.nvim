-- neo_tree/commands.lua: what the grip source's neo-tree mappings run.
-- The actions mirror the built-in sidebar's (schema/keymaps.lua): <CR> on a
-- table expands it, on a folder or one of its items shows that view in the
-- grid, on a routine opens its source; s opens a table's records.

local cc = require("neo-tree.sources.common.commands")
local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")

local M = {}

local SOURCE = "grip"

local function node_of(state, node)
  if node then return node end
  local ok, current = pcall(state.tree.get_node, state.tree)
  return ok and current or nil
end

--- The table a node belongs to: itself, or the table above a folder or item.
local function table_of(node)
  local extra = node.extra or {}
  if extra.is_file then return nil end
  return extra.table_name
end

--- Expand or collapse a node, fetching a table folder's metadata the first
--- time it is opened.
function M.toggle_node(state, node)
  node = node_of(state, node)
  if not node then return end
  local extra = node.extra or {}
  if node.type == "directory" and not node.loaded and extra.kind == "facet" then
    local source = require("dadbod-grip.neo_tree")
    local loaded = require("dadbod-grip.ui").blocking("loading " .. extra.name:lower() .. "...", function()
      return source._load_facet(state.grip_url, extra)
    end)
    node.name = loaded.name
    renderer.show_nodes(vim.tbl_map(source._to_item, loaded.children or {}), state, node:get_id())
    return
  end
  cc.toggle_node(state, nil, node)
end

function M.open(state, node)
  node = node_of(state, node)
  if not node then return end
  local extra, url = node.extra or {}, state.grip_url
  local schema = require("dadbod-grip.schema")
  if extra.is_file then
    if extra.kind == "table" then schema.open_file(url) else M.toggle_node(state, node) end
  elseif extra.view and extra.table_name then
    schema.open_table_view(extra.table_name, url, extra.view)
  elseif extra.kind == "routine" then
    schema.open_routine_source(extra.source_id or extra.routine, url)
  else
    M.toggle_node(state, node)
  end
end

--- s: the table's records, from the table, one of its folders or items.
function M.open_records(state)
  local node = node_of(state)
  local tbl = node and table_of(node)
  if tbl then require("dadbod-grip.schema").open_table(tbl, state.grip_url) end
end

--- S: the table's records in a new split, beside the grid already open.
function M.open_split(state)
  local node = node_of(state)
  if not node then return end
  local schema = require("dadbod-grip.schema")
  local tbl = table_of(node)
  if tbl then
    schema.open_table_split(tbl, state.grip_url)
  elseif (node.extra or {}).kind == "routine" then
    schema.open_routine_source(node.extra.source_id or node.extra.routine, state.grip_url)
  end
end

--- R: fetch the catalog again, keeping open folders open.
function M.refresh(state)
  local url = state.grip_url
  if not url then return manager.refresh(SOURCE) end
  local schema = require("dadbod-grip.schema")
  require("dadbod-grip.ui").blocking("refreshing schema...", function()
    schema.invalidate(url)
    schema.prefetch(url)
  end)
  manager.refresh(SOURCE)
  vim.notify("Grip: schema refreshed", vim.log.levels.INFO)
end

--- y: copy the object's or column's name.
function M.copy_name(state)
  local node = node_of(state)
  local extra = node and node.extra or {}
  local name = (extra.kind == "table" and (extra.table_name or extra.name))
    or (extra.kind == "column" and extra.name)
    or (extra.kind == "routine" and extra.routine)
    or nil
  if not name then return end
  vim.fn.setreg("+", name)
  vim.fn.setreg('"', name)
  vim.notify("Copied: " .. name, vim.log.levels.INFO)
end

cc._add_common_commands(M, "node") -- close_node, close_all_nodes, expand_all_nodes, ...
cc._add_common_commands(M, "^close_window$")
cc._add_common_commands(M, "source$") -- next_source, prev_source
cc._add_common_commands(M, "help")
cc._add_common_commands(M, "^cancel$")
cc._add_common_commands(M, "^toggle_auto_expand_width$")
cc._add_common_commands(M, "select")

return M
