-- Catalog indexing and visible sidebar projection. No database or window I/O.
local M = {}
local CATEGORIES = {"table", "view", "function", "procedure"}
local TITLES = {table = "Tables", view = "Views", ["function"] = "Functions", procedure = "Procedures"}
-- Folders under an expanded table, as in SSMS's Object Explorer. `view` is the
-- grid view (view.switch_view) that <CR> on the folder or its items opens.
M.FACETS = {
  {key = "columns", title = "Columns", view = "columns"},
  {key = "keys", title = "Keys", view = "fk"},
  {key = "constraints", title = "Constraints", view = "constraints"},
  {key = "indexes", title = "Indexes", view = "indexes"},
}

--- Fold key for one table folder in state.facets_expanded.
function M.facet_key(table_name, facet) return table_name .. "\0" .. facet end

local function schema_id(name) return "schema\0" .. name end
local function partition_id(id) return "partitions\0" .. id end
local function schema_name(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function index(state)
  local cached = state._tree_index
  if cached and cached.items == state.items and cached.routines == state.routines then return cached end
  local ix = {items = state.items, routines = state.routines, objects = {}, by_id = {}, by_oid = {},
    children = {}, parent = {}, schemas = {}, schema_order = {}, grouped = false}
  for _, list in ipairs({state.items or {}, state.routines or {}}) do
    for _, item in ipairs(list) do if schema_name(item.schema) then ix.grouped = true end end
  end
  local function add(item, kind)
    local s = schema_name(item.schema)
    if item.schema == nil then s = schema_name(state.default_schema) end
    local identity = kind == "table" and (item.relation_id or item.name)
      or (item.source_id or item.display or item.name)
    local id = kind .. "\0" .. identity .. "\0" .. (item.display or item.name)
    local qualified = s and item.relation_name and (s .. "." .. item.relation_name) or item.name
    if s and qualified:sub(1, #s + 1) ~= s .. "." then qualified = s .. "." .. qualified end
    local display = item.display or item.name
    local qualified_display = display
    if s and kind == "routine" and display:sub(1, #s + 1) ~= s .. "." then
      qualified_display = s .. "." .. display
    end
    local object = {id = id, item = item, kind = kind, schema = s,
      search = (qualified .. "\0" .. display .. "\0" .. qualified_display):lower()}
    ix.objects[#ix.objects + 1], ix.by_id[id] = object, object
    if kind == "table" and item.relation_id then ix.by_oid[item.relation_id] = object end
  end
  for _, item in ipairs(state.items or {}) do add(item, "table") end
  for _, item in ipairs(state.routines or {}) do add(item, "routine") end
  for _, object in ipairs(ix.objects) do
    local item = object.item
    local parent = item.is_partition and ix.by_oid[item.parent_id]
    if parent and parent ~= object and parent.item.relation_kind == "p" then
      ix.parent[object.id] = parent.id
      ix.children[parent.id] = ix.children[parent.id] or {}
      table.insert(ix.children[parent.id], object)
    end
  end
  for _, object in ipairs(ix.objects) do
    if not ix.parent[object.id] then
      local s = ix.grouped and object.schema or ""
      if not ix.schemas[s] then
        ix.schemas[s] = {table = {}, view = {}, ["function"] = {}, procedure = {}}
        ix.schema_order[#ix.schema_order + 1] = s
      end
      table.insert(ix.schemas[s][object.item.type or (object.kind == "routine" and "function" or "table")], object)
    end
  end
  table.sort(ix.schema_order)
  state._tree_index = ix
  return ix
end

function M.containers(state)
  local ix, containers = index(state), {}
  if ix.grouped then
    for _, name in ipairs(ix.schema_order) do
      if name ~= "" then containers[#containers + 1] = schema_id(name) end
    end
  end
  for id in pairs(ix.children) do containers[#containers + 1] = partition_id(id) end
  return containers
end

function M.prune(state)
  local ix, valid = index(state), {}
  for _, id in ipairs(M.containers(state)) do valid[id] = true end
  for id in pairs(state.groups_expanded or {}) do if not valid[id] then state.groups_expanded[id] = nil end end
  local names = {}
  for _, object in ipairs(ix.objects) do if object.kind == "table" then names[object.item.name] = true end end
  for name in pairs(state.expanded or {}) do if not names[name] then state.expanded[name] = nil end end
  for key in pairs(state.facets_expanded or {}) do
    if not names[key:match("^(.-)%z") or key] then state.facets_expanded[key] = nil end
  end
end

--- Item rows for one open table folder, from the sidebar's metadata caches.
local function facet_items(state, table_name, facet)
  local out = {}
  if facet == "columns" then
    for _, col in ipairs(state.col_cache[table_name] or {}) do
      local fk = (state.fk_cache[table_name] or {})[col.column_name]
      out[#out + 1] = {kind = "column", key = col.column_name, name = col.column_name,
        data_type = col.data_type, pk = (state.pk_cache[table_name] or {})[col.column_name] or false,
        fk = fk ~= nil, fk_ref = fk}
    end
  elseif facet == "keys" then
    local pk_cols = (state.pk_list or {})[table_name] or {}
    if #pk_cols > 0 then
      out[#out + 1] = {kind = "facet_item", key = "pk", icon = "🔑", text = "PK (" .. table.concat(pk_cols, ", ") .. ")"}
    end
    local fk_cols = vim.tbl_keys(state.fk_cache[table_name] or {})
    table.sort(fk_cols)
    for _, col in ipairs(fk_cols) do
      out[#out + 1] = {kind = "facet_item", key = "fk\0" .. col, icon = "🔗",
        text = col .. " → " .. state.fk_cache[table_name][col]}
    end
  else
    local cache = facet == "constraints" and state.constraint_cache or state.index_cache
    for _, entry in ipairs((cache or {})[table_name] or {}) do
      local cols = type(entry.columns) == "table" and table.concat(entry.columns, ", ") or entry.columns
      local detail = entry.type and entry.type ~= "" and entry.type or nil
      if facet == "indexes" and cols and cols ~= "" then detail = (detail and detail .. ": " or "") .. cols end
      out[#out + 1] = {kind = "facet_item", key = entry.name or "", icon = " ",
        text = (entry.name or "") .. (detail and ("  " .. detail) or "")}
    end
  end
  return out
end

function M.build(state)
  local ix, nodes = index(state), {}
  local filtering = state.filter and state.filter ~= ""
  local groups = (filtering and state.search_groups or state.groups_expanded) or {}
  local columns = (filtering and state.search_columns or state.expanded) or {}
  local included, matches = {}, {}
  if filtering then
    local needle = state.filter:lower()
    for _, object in ipairs(ix.objects) do
      if object.search:find(needle, 1, true) then
        matches[object.id] = true
        local id = object.id
        while id and not included[id] do included[id] = true; id = ix.parent[id] end
      end
    end
  end
  local function wanted(object) return not filtering or included[object.id] end
  local function is_open(id) return groups[id] == true or (filtering and groups[id] ~= false) end
  local function append(node)
    nodes[#nodes + 1] = node
    return node
  end
  local function walk(object, depth, parent)
    if not wanted(object) then return end
    local item, id = object.item, object.id
    if object.kind == "routine" then
      append({kind = "routine", id = id, parent = parent, depth = depth, name = item.name,
        display = item.display or item.name, type = item.type, source_id = item.source_id, matched = matches[id]})
      return
    end
    local label = item.name
    local actual_parent = ix.by_id[ix.parent[id]]
    if object.schema and actual_parent and actual_parent.schema ~= object.schema and item.relation_name then
      label = object.schema .. "." .. item.relation_name
    end
    local children = ix.children[id]
    local group_id = children and partition_id(id)
    local column_open = columns[item.name] == true
    local structure_open = group_id and is_open(group_id)
    local body_open = column_open or structure_open
    append({kind = "table", id = id, parent = parent, depth = depth, name = item.name,
      display = label, type = item.type, expanded = not not body_open, columns_expanded = column_open,
      partition_id = group_id, matched = matches[id], relation_kind = item.relation_kind})
    if column_open then
      for _, facet in ipairs(M.FACETS) do
        local fid = id .. "\0facet\0" .. facet.key
        local open = (state.facets_expanded or {})[M.facet_key(item.name, facet.key)] == true
        local count = facet.key == "columns" and state.col_cache[item.name]
          and #state.col_cache[item.name] or nil
        append({kind = "facet", facet = facet.key, view = facet.view, id = fid, parent = id,
          depth = depth + 1, name = facet.title, count = count, table_name = item.name, expanded = open})
        if open then
          for _, entry in ipairs(facet_items(state, item.name, facet.key)) do
            entry.id = fid .. "\0" .. entry.key
            entry.parent, entry.depth, entry.table_name = fid, depth + 2, item.name
            entry.facet, entry.view = facet.key, facet.view
            append(entry)
          end
        end
      end
    end
    if children and body_open then
      append({kind = "partitions", id = group_id, parent = id, depth = depth + 1, name = item.name,
        count = #children, expanded = not not structure_open})
      if structure_open then
        for _, child in ipairs(children) do walk(child, depth + 2, group_id) end
      end
    end
  end
  local any = false
  for _, s in ipairs(ix.schema_order) do
    local sections, show = ix.schemas[s], false
    local grouped = s ~= ""
    for _, kind in ipairs(CATEGORIES) do
      for _, object in ipairs(sections[kind]) do if wanted(object) then show = true; break end end
    end
    if show then
      if grouped then
        append({kind = "schema", id = schema_id(s), schema = s, name = s, depth = 0,
          expanded = not not is_open(schema_id(s))})
      elseif any then append({kind = "sep"}) end
      if not grouped or is_open(schema_id(s)) then
        for _, kind in ipairs(CATEGORIES) do
          local objects, visible = sections[kind], false
          for _, object in ipairs(objects) do if wanted(object) then visible = true; break end end
          if visible then
            if not grouped and any then append({kind = "sep"}) end
            local parent = grouped and schema_id(s) or nil
            append({kind = "header", id = "header\0" .. s .. "\0" .. kind, parent = parent,
              depth = grouped and 1 or 0, text = TITLES[kind] .. " (" .. #objects .. ")"})
            for _, object in ipairs(objects) do walk(object, grouped and 1 or 0, parent) end
            any = true
          end
        end
      end
      any = true
    end
  end
  return nodes
end

return M
