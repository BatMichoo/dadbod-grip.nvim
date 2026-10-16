dofile("tests/minimal_init.lua")
local pg=require("dadbod-grip.adapters.postgresql")
local pass,fail=0,0
local function test(name,fn)
  local ok,err=pcall(fn)
  if ok then pass=pass+1 else fail=fail+1;print("FAIL: "..name..": "..tostring(err)) end
end
local function with_psql(fn,run)
  local real=vim.system
  vim.system=function(args,opts,cb)
    assert(args[1]=="psql", "unexpected command")
    local stdout,stderr,code=fn(opts.stdin)
    local result={stdout=stdout or "",stderr=stderr or "",code=code or 0}
    if cb then cb(result) else return {wait=function()return result end} end
  end
  local ok,err=pcall(run)
  vim.system=real
  if not ok then error(err) end
end
test("PostgreSQL flat list retains schema and real partition metadata",function()
  with_psql(function(sql)
    assert(sql:find("pg_catalog.pg_inherits",1,true),"catalog parent links missing")
    assert(sql:find("information_schema.tables",1,true),"visibility boundary changed")
    return "table_name,table_type,relation_id,schema,relation_name,relation_kind,is_partition,parent_id,can_select_all\nmetrics.events,table,1,metrics,events,p,f,,t\narchive.events_2026,table,2,archive,events_2026,r,t,1,f\nforeign_leaf,table,3,public,foreign_leaf,f,t,1,t\n"
  end,function()
    local items,err=pg.list_tables("postgresql://synthetic.invalid/schema_metadata")
    assert(items,err)
    assert(#items==3 and items[1].schema=="metrics" and items[1].relation_kind=="p")
    assert(items[2].parent_id=="1" and items[2].is_partition and items[2].can_select_all==false)
    assert(items[3].type=="table" and items[3].schema=="public")
  end)
end)
test("unsupported metadata falls back without losing relations or repeatedly probing",function()
  local catalog_calls,plain_calls=0,0
  local notify=vim.notify
  vim.notify=function()end
  local ok,err=pcall(function()
    with_psql(function(sql)
      if sql:find("pg_catalog.pg_inherits",1,true) then
        catalog_calls=catalog_calls+1; return "","column c.relispartition does not exist",1
      end
      plain_calls=plain_calls+1
      return "table_name,table_type\naccounts,table\nmetrics.events_2026,table\n"
    end,function()
      for _=1,2 do
        local items,e=pg.list_tables("postgresql://synthetic.invalid/schema_denied")
        assert(items,e)
        assert(#items==2 and items[2].name=="metrics.events_2026")
      end
      assert(catalog_calls==1 and plain_calls==2,"metadata failure was not cached per connection")
    end)
  end)
  vim.notify=notify
  assert(ok,err)
end)
test("a transient metadata failure does not disable later enrichment",function()
  local catalog_calls=0
  local notify=vim.notify
  vim.notify=function()end
  local ok,err=pcall(function()
    with_psql(function(sql)
      if sql:find("pg_catalog.pg_inherits",1,true) then
        catalog_calls=catalog_calls+1
        if catalog_calls==1 then return "","permission denied for table pg_inherits",1 end
        return "table_name,table_type,relation_id,schema,relation_name,relation_kind,is_partition,parent_id,can_select_all\nmetrics.events,table,1,metrics,events,p,f,,t\n"
      end
      return "table_name,table_type,schema,relation_name\nmetrics.events,table,metrics,events\n"
    end,function()
      local first=assert(pg.list_tables("postgresql://synthetic.invalid/schema_transient"))
      assert(first[1].schema=="metrics" and first[1].can_select_all==nil)
      local second=assert(pg.list_tables("postgresql://synthetic.invalid/schema_transient"))
      assert(second[1].relation_kind=="p" and catalog_calls==2)
    end)
  end)
  vim.notify=notify
  assert(ok,err)
end)
print(string.format("pg_schema_tree_spec: %d passed, %d failed",pass,fail))
if fail>0 then os.exit(1) end
