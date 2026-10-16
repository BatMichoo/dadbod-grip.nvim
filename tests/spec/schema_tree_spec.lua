dofile("tests/minimal_init.lua")
local schema = require("dadbod-grip.schema")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function state(items, routines)
  return {items = items or {}, routines = routines or {}, expanded = {}, groups_expanded = {},
    col_cache = {}, pk_cache = {}, fk_cache = {}, row_count_cache = {}}
end
local function find(nodes, kind, name)
  for _, node in ipairs(nodes) do
    if node.kind == kind and (node.name == name or node.schema == name) then return node end
  end
end
local function open_schema(st, name)
  local node = assert(find(schema._build_nodes(st), "schema", name), "collapsed schema missing: " .. name)
  st.groups_expanded[node.id] = true
end
local function relations()
  return {
    {name="metrics.events",type="table",schema="metrics",relation_name="events",relation_id="1",relation_kind="p"},
    {name="metrics.events_2026",type="table",schema="metrics",relation_name="events_2026",relation_id="2",relation_kind="p",is_partition=true,parent_id="1"},
    {name="archive.events_2026_08_17",type="table",schema="archive",relation_name="events_2026_08_17",relation_id="3",relation_kind="r",is_partition=true,parent_id="2"},
  }
end
local function expand_table(st, name)
  st.expanded[name] = true
  st.col_cache[name], st.pk_cache[name], st.fk_cache[name] = {}, {}, {}
end
local function expand_partitions(st, name)
  expand_table(st, name)
  local group = assert(find(schema._build_nodes(st), "partitions", name), "partitions group missing")
  st.groups_expanded[group.id] = true
end

test("large catalog starts as collapsed schemas for all four object kinds", function()
  local fixture = dofile("tests/fixtures/schema_catalog.lua")()
  local counts = {table=0,view=0,["function"]=0,procedure=0}
  for _, item in ipairs(fixture.items) do counts[item.type] = counts[item.type] + 1 end
  for _, item in ipairs(fixture.routines) do counts[item.type] = counts[item.type] + 1 end
  assert(counts.table == 785 and counts.view == 64 and counts["function"] == 592 and counts.procedure == 56)
  local nodes = schema._build_nodes(state(fixture.items, fixture.routines))
  local groups = 0
  for _, node in ipairs(nodes) do
    if node.kind == "schema" then groups = groups + 1; assert(not node.expanded) end
    assert(node.kind ~= "table" and node.kind ~= "routine", "object leaked from collapsed schema")
  end
  assert(groups == 4, "only schemas with rendered roots should appear")
end)

test("expanded schema contains tables views and distinct overloaded routines", function()
  local st = state({{name="analytics.events",type="table",schema="analytics"},
    {name="analytics.recent",type="view",schema="analytics"}}, {
    {name="analytics.calc",display="analytics.calc(value integer)",type="function",schema="analytics",source_id="11"},
    {name="analytics.calc",display="analytics.calc(value text)",type="function",schema="analytics",source_id="12"},
    {name="analytics.run",display="analytics.run(value integer)",type="procedure",schema="analytics",source_id="13"},
  })
  open_schema(st, "analytics")
  local nodes, routines, headers = schema._build_nodes(st), {}, {}
  for _, node in ipairs(nodes) do
    if node.kind == "routine" then routines[node.source_id] = node end
    if node.kind == "header" then headers[node.text] = true end
  end
  assert(find(nodes,"table","analytics.events") and find(nodes,"table","analytics.recent"))
  assert(headers["Tables (1)"] and headers["Views (1)"] and headers["Functions (2)"] and headers["Procedures (1)"])
  assert(routines["11"].id ~= routines["12"].id and routines["12"].display == "analytics.calc(value text)")
end)

test("nested cross-schema partitions occur only below their actual parent", function()
  local st = state(relations())
  open_schema(st,"metrics")
  local nodes = schema._build_nodes(st)
  assert(not find(nodes,"table","metrics.events_2026") and not find(nodes,"schema","archive"))
  expand_partitions(st,"metrics.events")
  expand_partitions(st,"metrics.events_2026")
  nodes = schema._build_nodes(st)
  local leaf = assert(find(nodes,"table","archive.events_2026_08_17"))
  assert(leaf.display == "archive.events_2026_08_17", "cross-schema child must retain its qualifier")
  local count = 0
  for _, node in ipairs(nodes) do if node.kind=="table" then count=count+1 end end
  assert(count == 3 and leaf.depth > find(nodes,"table","metrics.events_2026").depth)
end)

test("invisible-parent and traditional inheritance children stay roots", function()
  local st=state({
    {name="a.orphan",type="table",schema="a",relation_id="1",is_partition=true,parent_id="999"},
    {name="a.legacy",type="table",schema="a",relation_id="2",relation_kind="r"},
    {name="a.child",type="table",schema="a",relation_id="3",relation_kind="r",is_partition=false,parent_id="2"},
    {name="a.column_only",type="table",schema="a",relation_id="4",can_select_all=false},
  })
  open_schema(st,"a")
  local nodes=schema._build_nodes(st)
  assert(find(nodes,"table","a.orphan") and find(nodes,"table","a.child"))
  assert(find(nodes,"table","a.orphan").depth == find(nodes,"table","a.legacy").depth)
  assert(find(nodes,"table","a.column_only"), "some-privilege metadata is not SELECT-star privilege")
end)

test("hidden leaf search reveals only matching ancestry without altering folds", function()
  local st=state(relations())
  st.filter="2026_08_17"
  local nodes=schema._build_nodes(st)
  assert(find(nodes,"schema","metrics") and find(nodes,"table","metrics.events"))
  assert(find(nodes,"table","metrics.events_2026") and find(nodes,"table","archive.events_2026_08_17"))
  for _, node in ipairs(nodes) do assert(node.kind~="column") end
  assert(next(st.expanded)==nil and next(st.groups_expanded)==nil, "temporary reveal changed saved folds")
  st.filter=nil
  nodes=schema._build_nodes(st)
  assert(not find(nodes,"table","metrics.events"), "clearing filter failed to restore collapsed schema")
end)

test("hidden routine search matches identity signature and preserves overload target", function()
  local fixture=dofile("tests/fixtures/schema_catalog.lua")()
  local st=state(fixture.items,fixture.routines)
  st.filter="identity_signature(input text)"
  local nodes=schema._build_nodes(st)
  local count, chosen=0
  for _, node in ipairs(nodes) do if node.kind=="routine" then count=count+1;chosen=node end end
  assert(count==1 and chosen.source_id==fixture.routines[2].source_id)
  assert(find(nodes,"schema","analytics"))
end)

test("refresh rebuilds partition ownership when a child becomes detached", function()
  local items=relations()
  local st=state(items)
  schema._build_nodes(st)
  st.items=vim.deepcopy(items)
  st.items[3].is_partition,st.items[3].parent_id=false,nil
  open_schema(st,"archive")
  assert(find(schema._build_nodes(st),"table","archive.events_2026_08_17"))
end)

test("public routine search includes its qualified schema and identity signature", function()
  local st=state({}, {{name="calc",schema="public",display="calc(value integer)",type="function",source_id="22"}})
  st.filter="public.calc(value integer)"
  local node=assert(find(schema._build_nodes(st),"routine","calc"),"public-qualified routine search lost the match")
  assert(node.source_id=="22" and node.display=="calc(value integer)")
end)

test("a public child beneath another schema displays its qualification without changing target", function()
  local st=state({
    {name="metrics.events",type="table",schema="metrics",relation_name="events",relation_id="1",relation_kind="p"},
    {name="events_2026",type="table",schema="public",relation_name="events_2026",relation_id="2",relation_kind="r",is_partition=true,parent_id="1"},
  })
  st.filter="public.events_2026"
  local child=assert(find(schema._build_nodes(st),"table","events_2026"))
  assert(child.display=="public.events_2026","cross-schema public child looked owned by metrics")
  assert(not find(st.nodes,"schema","public"),"child duplicated in its own schema")
end)

test("routine-only schemas group and mixed legacy DuckDB objects use the default schema",function()
  local routines={{name="tools.calc",schema="tools",type="function",source_id="9"}}
  local st=state({},routines)
  assert(find(schema._build_nodes(st),"schema","tools"))
  st=state({{name="plain",type="table"},{name="attached.events",schema="attached",type="table"}},routines)
  st.default_schema="main"
  open_schema(st,"main")
  local nodes=schema._build_nodes(st)
  assert(find(nodes,"table","plain") and find(nodes,"schema","attached") and find(nodes,"schema","tools"))
  st.filter="main.plain"
  assert(find(schema._build_nodes(st),"table","plain"),"default-schema qualified search lost a legacy object")
end)

print(string.format("schema_tree_spec: %d passed, %d failed",pass,fail))
if fail>0 then os.exit(1) end
