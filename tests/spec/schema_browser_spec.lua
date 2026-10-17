dofile("tests/minimal_init.lua")
local schema = require("dadbod-grip.schema")
local db = require("dadbod-grip.db")
local grip = require("dadbod-grip")
local ui = require("dadbod-grip.ui")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local long_name = "metrics.capacity_with_the_complete_very_long_unicode_name_測定_suffix_2026_08_17"
local items = {
  {name=long_name,type="table",schema="metrics",relation_name=long_name:sub(9),relation_id="1",relation_kind="p"},
  {name="metrics.capacity_2026",type="table",schema="metrics",relation_id="2",relation_kind="p",is_partition=true,parent_id="1"},
  {name="archive.capacity_p_2026_08_17",type="table",schema="archive",relation_id="3",relation_kind="r",is_partition=true,parent_id="2"},
  {name="metrics.other",type="table",schema="metrics",relation_id="4",relation_kind="r"},
}
local routines = {
  {name="analytics.calc",display="analytics.calc(value integer)",type="function",schema="analytics",source_id="101"},
  {name="analytics.calc",display="analytics.calc(value text)",type="function",schema="analytics",source_id="102"},
  {name="analytics.run",display="analytics.run(value integer)",type="procedure",schema="analytics",source_id="103"},
}
local function with_browser(fn, catalog)
  schema.close(); schema._reset_state()
  local original_win = vim.api.nvim_get_current_win()
  local saved, opened, columns, queries, sources, meta = {}, {}, {}, {}, {}, {}
  for _, key in ipairs({"list_tables","list_routines","get_column_info","get_primary_keys","get_foreign_keys","query","get_routine_source","get_indexes","get_constraints"}) do saved[key]=db[key] end
  local real_open, real_input = grip.open, ui.input
  db.list_tables=function()return vim.deepcopy(catalog and catalog.items or items) end
  db.list_routines=function()return vim.deepcopy(catalog and catalog.routines or routines) end
  db.get_column_info=function(name) columns[#columns+1]=name;return {{column_name="id",data_type="integer"}} end
  db.get_primary_keys=function() meta[#meta+1]="pk";return {"id"} end
  db.get_foreign_keys=function() meta[#meta+1]="fk";return {{column="owner_id",ref_table="users"}} end
  db.get_indexes=function() meta[#meta+1]="indexes";return {{name="ix_owner",type="INDEX",columns={"owner_id"}}} end
  db.get_constraints=function() meta[#meta+1]="constraints";return {{name="ck_positive",type="CHECK"}} end
  db.query=function(sql) queries[#queries+1]=sql;return {rows={{"1"}}} end
  db.get_routine_source=function(id) sources[#sources+1]=id;return "SELECT '"..id.."';" end
  grip.open=function(name,_,o)opened[#opened+1]=name;opened.opts=o end
  local url=catalog and catalog.url or "postgresql://synthetic.invalid/sidebar"
  schema.toggle(url)
  local st=schema.get_state(url)
  local win=schema.get_winid()
  local function select_node(kind,name,source_id)
    vim.api.nvim_set_current_win(win)
    for i,node in ipairs(st.nodes) do
      if node.kind==kind and (node.name==name or node.schema==name) and (not source_id or node.source_id==source_id) then
        vim.api.nvim_win_set_cursor(win,{i+(st.filter and 4 or 2),0});return node
      end
    end
    error("node missing: "..kind..":"..name)
  end
  local function press(key)
    vim.api.nvim_set_current_win(win)
    local map=vim.fn.maparg(key,"n",false,true)
    assert(type(map.callback)=="function","missing map "..key)
    map.callback()
    vim.wait(5)
  end
  local function current()
    local row=vim.api.nvim_win_get_cursor(win)[1]
    return st.nodes[row-(st.filter and 4 or 2)]
  end
  local ok,err=pcall(fn,{state=st,win=win,select=select_node,press=press,current=current,
    opened=opened,columns=columns,queries=queries,sources=sources,meta=meta,
    lines=function()return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win),0,-1,false) end,
    filter=function(value)ui.input=function()return value end;press("/")end})
  schema.close(); schema._reset_state()
  grip.open,ui.input=real_open,real_input
  for key,value in pairs(saved) do db[key]=value end
  for _,window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if window~=original_win then pcall(vim.api.nvim_win_close,window,true) end
  end
  if vim.api.nvim_win_is_valid(original_win) then vim.api.nvim_set_current_win(original_win) end
  assert(ok,err)
end

test("schema Enter and l aliases expose all object kinds without fetching columns",function()
  with_browser(function(b)
    b.select("schema","analytics");b.press("<CR>")
    b.select("routine","analytics.calc","102")
    b.press("<CR>")
    assert(b.sources[1]=="102", "wrong overloaded source opened")
    assert(vim.bo[vim.api.nvim_get_current_buf()].readonly,"routine source must stay readonly")
    b.select("schema","metrics");b.press("zo")
    b.select("table",long_name)
    assert(#b.columns==0 and #b.queries==0,"group expansion performed data/column I/O")
  end)
end)

test("L opens partition structure while explicit l on the Columns folder alone fetches columns",function()
  with_browser(function(b)
    b.press("L")
    b.select("table","archive.capacity_p_2026_08_17")
    assert(#b.columns==0 and #b.queries==0,"expand-all eagerly loaded table metadata")
    b.select("table",long_name);b.press("l")
    assert(#b.columns==0,"expanding a table must only list its folders")
    b.select("facet","Columns");b.press("l")
    assert(#b.columns==1 and b.columns[1]==long_name)
    assert(#b.queries==0,"column expansion issued an exact COUNT")
    b.select("column","id");b.press("zc")
    assert(b.current().kind=="facet" and b.current().name=="Columns","collapse did not select the folder")
    b.press("zc")
    assert(b.current().kind=="table" and b.current().name==long_name,"collapse did not restore parent selection")
  end)
end)

test("a table expands into SSMS folders and each folder queries only when opened",function()
  with_browser(function(b)
    b.press("L")
    b.select("table",long_name);b.press("l")
    local folders={}
    for _,node in ipairs(b.state.nodes) do
      if node.kind=="facet" and node.table_name==long_name then
        folders[#folders+1]=node.name;assert(not node.expanded,"folders start collapsed")
      end
    end
    assert(table.concat(folders,",")=="Columns,Keys,Constraints,Indexes",table.concat(folders,","))
    assert(#b.columns==0 and #b.meta==0,"expanding the table ran metadata queries")

    b.select("facet","Keys");b.press("l")
    assert(table.concat(b.meta,",")=="pk,fk","Keys fetched only the keys: "..table.concat(b.meta,","))
    local text=table.concat(b.lines(),"\n")
    assert(text:find("PK (id)",1,true) and text:find("owner_id → users",1,true),text)

    b.select("facet","Indexes");b.press("l")
    assert(b.meta[#b.meta]=="indexes" and table.concat(b.lines(),"\n"):find("ix_owner",1,true))
    b.select("facet","Constraints");b.press("l")
    assert(b.meta[#b.meta]=="constraints" and table.concat(b.lines(),"\n"):find("ck_positive",1,true))
    assert(#b.columns==0,"no folder but Columns loads column info")
  end)
end)

test("the Columns folder runs one query; markers appear once Keys has loaded",function()
  with_browser(function(b)
    b.press("L");b.select("table","metrics.other");b.press("<CR>")
    b.select("facet","Columns");b.press("l")
    assert(#b.columns==1 and #b.meta==0,"Columns folder queried keys: "..table.concat(b.meta,","))
    assert(not table.concat(b.lines(),"\n"):find("🔑",1,true),"marker without loaded keys")
    b.select("facet","Keys");b.press("l")
    assert(table.concat(b.meta,",")=="pk,fk")
    assert(table.concat(b.lines(),"\n"):find("🔑  id",1,true),"PK marker after Keys loaded")
  end)
end)

test("Enter on a table expands and collapses it; s opens its records",function()
  with_browser(function(b)
    b.press("L");b.select("table","metrics.other");b.press("<CR>")
    assert(#b.opened==0,"Enter on a table ran its query")
    assert(b.current().expanded and b.state.expanded["metrics.other"],"Enter did not expand the table")
    b.press("<CR>")
    assert(not b.current().expanded,"second Enter did not collapse the table")
    b.press("s")
    assert(b.opened[1]=="metrics.other","s did not open the records")
    b.press("<CR>");b.select("facet","Keys");b.press("s")
    assert(b.opened[2]=="metrics.other","s from a folder opens its table")

    -- A partitioned table opened by L also closes its partitions on Enter
    b.select("table",long_name)
    assert(b.current().expanded,"L opened the partition structure")
    b.press("<CR>")
    assert(not b.current().expanded,"Enter left the partitions open")
  end)
end)

test("F5 opens the table under the cursor and nothing else",function()
  with_browser(function(b)
    b.press("L");b.select("table","metrics.other");b.press("<F5>")
    assert(b.opened[1]=="metrics.other","F5 did not open the table's records")
    b.press("<CR>");b.select("facet","Keys");b.press("<F5>")
    assert(#b.opened==1,"F5 on a folder ran a query")
  end)
end)

test("Enter on a folder shows that view in the grid",function()
  with_browser(function(b)
    local view=require("dadbod-grip.view")
    local real_find,real_switch=view.find_content_win,view.switch_view
    local switched={}
    view.switch_view=function(buf,name) switched[#switched+1]={buf,name} end
    local ok,err=pcall(function()
      b.press("L");b.select("table",long_name);b.press("l")

      -- No grid on that table yet: a grid opens on the view, without the rows
      view.find_content_win=function() return nil end
      b.select("facet","Indexes");b.press("<CR>")
      assert(b.opened[1]==long_name,"table was not opened")
      assert(b.opened.opts and b.opened.opts.metadata_view=="indexes","rows were queried for a folder")

      -- A grid already on the table: only the view changes
      vim.api.nvim_set_current_win(b.win)
      vim.cmd("rightbelow vsplit")
      local grid_win=vim.api.nvim_get_current_win()
      local grid_buf=vim.api.nvim_create_buf(false,true)
      vim.api.nvim_win_set_buf(grid_win,grid_buf)
      view._sessions[grid_buf]={url=b.state.url,state={table_name=long_name}}
      view.find_content_win=function() return grid_win end
      b.select("facet","Keys");b.press("<CR>")
      assert(#b.opened==1,"an open grid on the table was reopened")
      assert(switched[#switched][1]==grid_buf and switched[#switched][2]=="fk","Keys shows the fk view")
      b.select("facet","Constraints");b.press("<CR>")
      assert(switched[#switched][2]=="constraints")
      view._sessions[grid_buf]=nil
    end)
    view.find_content_win,view.switch_view=real_find,real_switch
    assert(ok,err)
  end)
end)

test("search reveals hidden descendants and F restores original selection and folds",function()
  with_browser(function(b)
    b.select("schema","metrics")
    b.filter("capacity_p_2026_08_17")
    assert(b.current().name=="archive.capacity_p_2026_08_17","search selected an ancestor")
    b.press("s")
    assert(b.opened[1]=="archive.capacity_p_2026_08_17")
    b.filter("calc(value text)")
    assert(b.current().source_id=="102","routine overload search lost identity")
    b.press("h")
    b.press("F")
    assert(b.state.filter==nil and b.current().kind=="schema" and b.current().name=="metrics")
    assert(next(b.state.groups_expanded)==nil and next(b.state.expanded)==nil,"temporary search changed saved folds")
    assert(#b.columns==0 and #b.queries==0)
  end)
end)

test("cancelled search preserves the active term and selection",function()
  with_browser(function(b)
    b.filter("calc(value integer)")
    b.filter(nil)
    assert(b.state.filter=="calc(value integer)" and b.current().source_id=="101")
  end)
end)

test("complete Unicode labels survive horizontal scrolling and table actions",function()
  with_browser(function(b)
    b.select("schema","metrics");b.press("l")
    b.select("table",long_name)
    local found=false
    for _,line in ipairs(b.lines()) do if line:find(long_name,1,true) then found=true end end
    assert(found,"buffer label permanently lost the suffix")
    assert(not vim.wo[b.win].wrap)
    vim.cmd("normal! zL")
    local offset=vim.fn.winsaveview().leftcol
    assert(offset>0,"native horizontal scroll did not reveal full label")
    b.press("l")
    assert(vim.fn.winsaveview().leftcol==offset,"render reset horizontal position")
    assert(b.current().name==long_name,"horizontal offset changed selected object")
    b.press("s")
    assert(b.opened[1]==long_name,"truncated display became an action target")
  end)
end)

test("legacy flat buffer also retains the complete label beyond the window edge",function()
  with_browser(function(b)
    b.state.items={{name=long_name,type="table"}}
    b.state.routines={}
    b.press("F")
    b.select("table",long_name)
    local full=false
    for _,line in ipairs(b.lines()) do if line:find(long_name,1,true) then full=true end end
    assert(full,"legacy renderer permanently ellipsized the buffer label")
  end)
end)

test("group rows cannot trigger relation-specific actions",function()
  with_browser(function(b)
    b.select("schema","metrics")
    b.press("<S-CR>");b.press("go");b.press("D")
    assert(#b.opened==0 and #b.columns==0 and #b.queries==0)
    b.press("l");b.select("table",long_name);b.press("l")
    b.select("partitions",long_name)
    b.press("<S-CR>");b.press("go");b.press("D")
    assert(#b.opened==0 and #b.queries==0)
  end)
end)

test("H moves a hidden leaf selection to its surviving schema",function()
  with_browser(function(b)
    b.press("L")
    b.select("table","archive.capacity_p_2026_08_17")
    b.press("H")
    assert(b.current().kind=="schema" and b.current().name=="metrics")
  end)
end)

test("h from a horizontally scrolled closed table reveals its schema label",function()
  with_browser(function(b)
    b.select("schema","metrics");b.press("l")
    b.select("table",long_name)
    vim.cmd("normal! $")
    assert(vim.fn.winsaveview().leftcol>0)
    b.press("h")
    assert(b.current().kind=="schema" and b.current().name=="metrics")
    assert(vim.fn.winsaveview().leftcol==0,"ancestor navigation hid the short schema label")
    vim.cmd("normal! jj")
    assert(b.current().name==long_name and vim.fn.winsaveview().leftcol==0,"ancestor retained the old end-of-line cursor goal")
  end)
end)

test("n and N visit real routines alongside tables",function()
  with_browser(function(b)
    b.press("L")
    b.select("routine","analytics.calc","102")
    b.press("n")
    assert(b.current().kind=="routine" and b.current().source_id=="103")
    b.press("N")
    assert(b.current().source_id=="102")
  end)
end)

test("L and H act across the full large catalog from a routine row and preserve existing columns",function()
  local catalog=dofile("tests/fixtures/schema_catalog.lua")()
  with_browser(function(b)
    b.press("L")
    local seen,objects={},0
    for _,node in ipairs(b.state.nodes) do
      if node.kind=="schema" or node.kind=="partitions" then assert(node.expanded,"L left a structural group closed") end
      if node.kind=="table" or node.kind=="routine" then
        assert(not seen[node.id],"object duplicated during global expansion");seen[node.id]=true;objects=objects+1
      end
    end
    assert(objects==1497 and #b.columns==0 and #b.queries==0)
    b.select("table","accounts");b.press("l");b.select("facet","Columns");b.press("l")
    b.select("table","accounts")
    local selected=b.current().id
    b.press("L");b.press("L")
    assert(b.current().id==selected and b.state.expanded.accounts and #b.columns==1,
      "L changed existing columns or selected object")
    b.select("routine",catalog.routines[2].name,catalog.routines[2].source_id)
    b.press("H");b.press("H")
    assert(b.current().kind=="schema" and b.current().name=="analytics","H did not keep the nearest surviving ancestor")
    for _,node in ipairs(b.state.nodes) do assert(node.kind=="schema" and not node.expanded) end
    assert(#b.state.nodes==4 and not b.state.expanded.accounts and #b.queries==0)
    b.press("L")
    b.select("table","archive.capacity_p_2026_08_18")
    assert(#b.columns==1,"reopening all structure reloaded columns")
  end,catalog)
end)

test("L and H during search only change temporary folds and F restores global folds and selection",function()
  with_browser(function(b)
    b.press("L")
    b.select("table",long_name);b.press("l");b.select("facet","Columns");b.press("l")
    b.select("table","archive.capacity_p_2026_08_17")
    local original=b.current().id
    local saved_groups,saved_columns=vim.deepcopy(b.state.groups_expanded),vim.deepcopy(b.state.expanded)
    b.filter("capacity_p_2026_08_17")
    b.press("H")
    assert(b.state.filter and b.current().kind=="schema" and not b.current().expanded)
    b.press("L")
    local matches=0
    for _,node in ipairs(b.state.nodes) do
      if node.kind=="table" and node.matched then matches=matches+1 end
      assert(node.name~="metrics.other","L removed the active search restriction")
    end
    assert(matches==1)
    assert(vim.deep_equal(saved_groups,b.state.groups_expanded) and vim.deep_equal(saved_columns,b.state.expanded))
    b.press("F")
    assert(not b.state.filter and b.current().id==original)
    assert(vim.deep_equal(saved_groups,b.state.groups_expanded) and vim.deep_equal(saved_columns,b.state.expanded))
    assert(#b.columns==1 and #b.queries==0)
    b.press("H");b.press("L");b.select("table","metrics.other")
  end)
end)

test("schema-less catalog still expands explicit partition depth and leaves flat routines accessible",function()
  local catalog={url="sqlite:synthetic-schema-less",items={
    {name="root",type="table",relation_id="1",relation_kind="p"},
    {name="middle",type="table",relation_id="2",relation_kind="p",is_partition=true,parent_id="1"},
    {name="deeper",type="table",relation_id="3",relation_kind="p",is_partition=true,parent_id="2"},
    {name="leaf",type="table",relation_id="4",relation_kind="r",is_partition=true,parent_id="3"},
    {name="ordinary",type="table"},{name="recent",type="view"},
  },routines={
    {name="calc",display="calc(value integer)",type="function",source_id="101"},
    {name="calc",display="calc(value text)",type="function",source_id="102"},
    {name="run",display="run(value integer)",type="procedure",source_id="103"},
  }}
  with_browser(function(b)
    for _,node in ipairs(b.state.nodes) do assert(node.kind~="schema") end
    b.press("L");b.select("table","leaf")
    assert(b.current().depth==6,"expand-all stopped before the deepest partition")
    b.press("H")
    assert(b.current().kind=="table" and b.current().name=="root")
    b.select("routine","calc","102")
    b.press("H");assert(b.current().source_id=="102","H hid an ungrouped routine")
    b.press("<CR>");assert(b.sources[1]=="102")
    b.select("table","ordinary");b.press("l");b.select("facet","Columns");b.press("l");b.press("L")
    assert(b.state.expanded.ordinary and #b.columns==1 and #b.queries==0)
    b.press("H");assert(not b.state.expanded.ordinary)
    b.filter("main.calc")
    assert(#b.state.nodes==0,"search invented a main schema for unqualified routines")
    b.press("F");b.select("table","ordinary")
  end,catalog)
end)

test("mixed PostgreSQL metadata never assigns public ownership to unknown rows",function()
  local catalog={items={{name="unknown",type="table"},{name="metrics.known",type="table",schema="metrics"}},
    routines={{name="calc",display="calc(value integer)",type="function",source_id="101"},
      {name="tools.run",schema="tools",type="procedure",source_id="102"}}}
  with_browser(function(b)
    b.select("table","unknown");b.select("routine","calc","101")
    b.press("L")
    for _,node in ipairs(b.state.nodes) do assert(node.kind~="schema" or node.name~="public","missing schema was assumed public") end
    b.press("H")
    b.select("table","unknown");b.select("routine","calc","101")
    b.filter("public.calc")
    assert(#b.state.nodes==0,"missing routine schema was assumed public in search")
    b.press("F");b.select("routine","calc","101")
    assert(#b.columns==0 and #b.queries==0)
  end,catalog)
end)

test("collapsing an ungrouped root without a parent keeps its selection",function()
  local catalog={url="sqlite:synthetic-flat",items={{name="first",type="table"},{name="last",type="table"}},
    routines={{name="calc",display="calc(value text)",type="function",source_id="102"}}}
  with_browser(function(b)
    b.select("routine","calc","102");b.press("h")
    assert(b.current().source_id=="102","root collapse jumped to an unrelated table")
    b.select("table","last");b.press("zc")
    assert(b.current().name=="last","root fold alias jumped to an unrelated table")
  end,catalog)
end)

test("DuckDB implicit main ownership follows a resolved whole-URL template",function()
  local previous=vim.env.GRIP_TEST_SCHEMA_DUCKDB_TEMPLATE
  vim.env.GRIP_TEST_SCHEMA_DUCKDB_TEMPLATE="duckdb::memory:"
  local ok,err=pcall(function()
    with_browser(function(b)
      b.select("schema","main");b.press("L");b.select("table","plain")
      b.filter("main.plain")
      assert(b.current().kind=="table" and b.current().name=="plain")
      b.press("H");b.press("L");b.press("F")
      b.select("table","plain")
      assert(#b.columns==0 and #b.queries==0)
    end,{url="${GRIP_TEST_SCHEMA_DUCKDB_TEMPLATE}",items={{name="plain",type="table"},
      {name="analytics.events",type="table",schema="analytics"}},routines={}})
  end)
  vim.env.GRIP_TEST_SCHEMA_DUCKDB_TEMPLATE=previous
  assert(ok,err)
end)

print(string.format("schema_browser_spec: %d passed, %d failed",pass,fail))
if fail>0 then os.exit(1) end
