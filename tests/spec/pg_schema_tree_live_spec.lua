-- Optional actual restricted-login integration. Seed only a disposable database
-- using tests/fixtures/schema_tree_pg_setup.sql; cleanup with its matching file.
-- URLs must log in as grip_live_reader/full with default_transaction_read_only=on.
local READER = vim.env.GRIP_TEST_SCHEMA_READER_URL
local FULL = vim.env.GRIP_TEST_SCHEMA_FULL_URL
if not READER or not FULL then
  if vim.env.GRIP_REQUIRE_SCHEMA_TREE == '1' then error('schema tree role URLs required') end
  print('pg_schema_tree_live_spec: 0 passed, 0 failed (skipped: role URLs unset)')
  return
end
local pg = require('dadbod-grip.adapters.postgresql')
local schema = require('dadbod-grip.schema')
local tree = require('dadbod-grip.schema_tree')
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(err)) end
end
local function query(sql, url) local result,err=pg.query(sql,url);assert(result,err);return result end
local function catalog(url)
  local items,err=pg.list_tables(url);assert(items,err)
  local routines,rerr=pg.list_routines(url);assert(routines,rerr)
  return {items=items,routines=routines,expanded={},groups_expanded={},col_cache={},pk_cache={},fk_cache={}}
end
local function find(list,kind,name)
  for _,node in ipairs(list) do if (not kind or node.kind==kind) and node.name==name then return node end end
end
local function open_structure(st)
  for _,id in ipairs(tree.containers(st)) do st.groups_expanded[id]=true end
  return schema._build_nodes(st)
end

test('actual restricted logins retain read-only transactions',function()
  for _,entry in ipairs({{READER,'grip_live_reader'},{FULL,'grip_live_full'}}) do
    local row=query("SELECT current_user, session_user, current_setting('transaction_read_only')",entry[1]).rows[1]
    assert(row[1]==entry[2] and row[2]==entry[2] and row[3]=='on','incorrect login or writable transaction')
    local result,err=pg.query('INSERT INTO grip_live.events VALUES (999, CURRENT_DATE)',entry[1])
    assert(not result and err:find('read%-only transaction'),'write did not fail as read-only')
  end
end)

test('parent-only reader sees parent and column-only roots without inventing children',function()
  local st=catalog(READER)
  local parent=assert(find(st.items,nil,'grip_live.events'))
  assert(parent.relation_kind=='p' and parent.can_select_all==true)
  assert(not find(st.items,nil,'grip_live.events_2026_01'),'ungranted child exposed')
  assert(not find(st.items,nil,'grip_live.private_parent'),'invisible parent exposed')
  local column=assert(find(st.items,nil,'grip_live.column_only'))
  assert(column.can_select_all==false,'column-only grant became SELECT-star permission')
  local nodes=open_structure(st)
  local orphan=assert(find(nodes,'table','grip_live.orphan_leaf'))
  assert(orphan.depth==find(nodes,'table','grip_live.events').depth,'invisible parent concealed direct child access')
  assert(not find(nodes,'partitions','grip_live.events'),'ungranted children became synthetic rows')
  assert(query('SELECT COUNT(*) FROM grip_live.events',READER).rows[1][1]=='3','parent SELECT lost descendants')
  assert(query('SELECT COUNT(*) FROM ONLY grip_live.events',READER).rows[1][1]=='0')
  local result,err=pg.query('SELECT * FROM grip_live.events_2026_01',READER)
  assert(not result and err:find('permission denied',1,true),'direct ungranted child unexpectedly readable')
  assert(query('SELECT id FROM grip_live.column_only',READER).rows[1][1]=='5')
  result,err=pg.query('SELECT * FROM grip_live.column_only',READER)
  assert(not result and err:find('permission denied',1,true))
  assert(query('SELECT COUNT(*) FROM grip_live.secured',READER).rows[1][1]=='1','RLS changed')
end)

test('fully granted catalog nests actual multi-level cross-schema partitions exactly once',function()
  local st=catalog(FULL)
  local nodes=open_structure(st)
  local root=assert(find(nodes,'table','grip_live.events'))
  local middle=assert(find(nodes,'table','grip_live.events_2026'))
  local leaf=assert(find(nodes,'table','grip_live_archive.events_2026_02'))
  assert(root.depth<middle.depth and middle.depth<leaf.depth)
  assert(leaf.display=='grip_live_archive.events_2026_02')
  assert(find(nodes,'table','grip_live.events_default'),'default partition missing')
  local count=0
  for _,node in ipairs(nodes) do
    if node.kind=='table' and node.name==leaf.name then count=count+1 end
    assert(node.kind~='column','structural browse fetched columns')
    assert(not node.name or not node.name:find('grip_live_events_idx',1,true),'partitioned index became a table')
  end
  assert(count==1)
  local legacy=assert(find(nodes,'table','grip_live.legacy'))
  assert(find(nodes,'table','grip_live.legacy_child').depth==legacy.depth)
  assert(find(nodes,'table','grip_live.multi_child').depth==legacy.depth)
  st.filter='events_2026_02'
  nodes=schema._build_nodes(st)
  assert(find(nodes,'table','grip_live.events') and find(nodes,'table','grip_live.events_2026'))
  assert(find(nodes,'table',leaf.name))
end)

test('real overload signatures retain distinct OIDs and the exact source definition',function()
  local st=catalog(FULL)
  st.filter='grip_live.calc(value text)'
  local chosen=assert(find(schema._build_nodes(st),'routine','grip_live.calc'))
  assert(chosen.display=='grip_live.calc(value text)' and chosen.source_id)
  local source,err=pg.get_routine_source(chosen.source_id,FULL);assert(source,err)
  assert(source:find('value text',1,true) and source:find('_text',1,true),'wrong overload source')
  st.filter='grip_live.touch'
  assert(find(schema._build_nodes(st),'routine','grip_live.touch').type=='procedure')
end)

test('real sidebar Enter opens parent rows and a searched cross-schema leaf',function()
  local view=require('dadbod-grip.view')
  local function close_grids()
    for bufnr in pairs(view._sessions) do
      view._sessions[bufnr]=nil
      pcall(vim.api.nvim_buf_delete,bufnr,{force=true})
    end
  end
  local function press(key)
    vim.api.nvim_set_current_win(schema.get_winid())
    local map=vim.fn.maparg(key,'n',false,true)
    assert(type(map.callback)=='function');map.callback()
  end
  local function select_node(st,kind,name)
    for i,node in ipairs(st.nodes) do
      if node.kind==kind and node.name==name then
        vim.api.nvim_win_set_cursor(schema.get_winid(),{i+(st.filter and 4 or 2),0});return
      end
    end
    error('real sidebar node missing: '..name)
  end
  local ui=require('dadbod-grip.ui')
  local old_input=ui.input
  local ok,err=pcall(function()
    schema.close();schema._reset_state();schema.toggle(READER)
    local st=schema.get_state(READER)
    select_node(st,'schema','grip_live');press('l')
    select_node(st,'table','grip_live.events');press('<CR>')
    local _,session=next(view._sessions)
    assert(session and session.state.table_name=='grip_live.events' and #session.state.rows==3,
      'parent action did not retain normal descendant query semantics')
    schema.close();close_grids();schema.toggle(FULL)
    st=schema.get_state(FULL)
    ui.input=function()return 'grip_live_archive.events_2026_02' end
    press('/')
    select_node(st,'table','grip_live_archive.events_2026_02');press('<CR>')
    _,session=next(view._sessions)
    assert(session and session.state.table_name=='grip_live_archive.events_2026_02' and #session.state.rows==1,
      'hidden cross-schema leaf opened a different relation')
    ui.input=function()return 'grip_live.calc(value text)' end
    press('/');select_node(st,'routine','grip_live.calc');press('<CR>')
    assert(vim.bo.readonly and not vim.bo.modifiable,'routine source was editable')
    assert(table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),'\n'):find('_text',1,true),'wrong overload opened')
  end)
  ui.input=old_input;schema.close();close_grids();schema._reset_state()
  assert(ok,err)
end)

print(string.format('pg_schema_tree_live_spec: %d passed, %d failed',pass,fail))
if fail>0 then os.exit(1) end
