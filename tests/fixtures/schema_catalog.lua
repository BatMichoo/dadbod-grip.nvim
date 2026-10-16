-- Invented catalog at the user's approximate scale; no workplace metadata.
return function()
  local items, routines, serial = {}, {}, 1000
  local function relation(schema, name, kind, parent, partition)
    serial = serial + 1
    local item = {
      name = schema == "public" and name or schema .. "." .. name,
      type = kind == "v" and "view" or "table", schema = schema, relation_name = name,
      relation_id = tostring(serial), relation_kind = kind or "r", is_partition = partition or false,
      parent_id = parent and parent.relation_id or nil, can_select_all = true,
    }
    items[#items + 1] = item
    return item
  end
  relation("public", "accounts")
  local root = relation("metrics", "capacity_with_a_deliberately_long_complete_label_測定", "p")
  local middle = relation("metrics", "capacity_2026_08", "p", root, true)
  relation("metrics", "capacity_p_2026_08_17", "r", middle, true)
  relation("archive", "capacity_p_2026_08_18", "r", middle, true)
  local legacy = relation("metrics", "legacy")
  relation("metrics", "legacy_2026", "r", legacy, false)
  relation("analytics", "orphan", "r", {relation_id = "999999"}, true)
  local schemas = {"public", "metrics", "analytics", "operations"}
  for i = 9, 785 do relation(schemas[(i - 1) % #schemas + 1], string.format("synthetic_table_%04d", i)) end
  for i = 1, 64 do relation(schemas[(i - 1) % #schemas + 1], string.format("synthetic_view_%03d", i), "v") end
  local function routine(schema, name, args, kind)
    serial = serial + 1
    local qualified = schema == "public" and name or schema .. "." .. name
    routines[#routines + 1] = {name = qualified, display = qualified .. "(" .. args .. ")",
      schema = schema, arguments = args, type = kind, source_id = tostring(serial)}
  end
  routine("analytics", "calculate_with_a_very_long_complete_identity_signature", "input integer", "function")
  routine("analytics", "calculate_with_a_very_long_complete_identity_signature", "input text", "function")
  for i = 3, 592 do routine(schemas[(i - 1) % #schemas + 1], string.format("synthetic_function_%03d", i), "value integer", "function") end
  for i = 1, 56 do routine(schemas[(i - 1) % #schemas + 1], string.format("synthetic_procedure_%03d", i), "value integer", "procedure") end
  return {items = items, routines = routines}
end
