-- schema/keymaps.lua: the schema sidebar's buffer-local keymaps.

local ui      = require("dadbod-grip.ui")
local VERSION = require("dadbod-grip.version")

local M = {}

--- Set up the sidebar buffer's keymaps for connection `url`.
--- ctx carries the sidebar internals the mappings drive (see schema.lua).
function M.setup(url, ctx)
  local buf = ctx.bufnr()
  local km = require("dadbod-grip.keymaps")
  local function kmap(action, fn, opts)
    km.bind("sidebar", buf, action, "n", fn, opts)
  end

  local state = ctx.get_state(url)

  local function groups() return state.filter and state.search_groups or state.groups_expanded end
  local function columns() return state.filter and state.search_columns or state.expanded end
  local function is_group(node) return node.kind == "schema" or node.kind == "partitions" end
  local tree = require("dadbod-grip.schema_tree")
  local function clear_filter()
    local anchor = state.search_restore or ctx.selection(state)
    state.filter, state.search_groups, state.search_columns, state.search_restore = nil, nil, nil, nil
    ctx.render(state, anchor)
  end

  -- Open table / expand column (reuses existing grid window)
  kmap("sidebar_open", function()
    local node = ctx.node_at_cursor(state)
    if not node then return end
    if is_group(node) then
      groups()[node.id] = not node.expanded
      ctx.render(state)
    elseif node.is_file then
      if node.kind == "table" then
        -- File table node: focus grid if open, otherwise open the file
        local view_mod = require("dadbod-grip.view")
        local content_win = view_mod.find_content_win()
        local content_buf = content_win and vim.api.nvim_win_get_buf(content_win)
        if content_win and view_mod._sessions[content_buf] then
          vim.api.nvim_set_current_win(content_win)
        else
          require("dadbod-grip").open(url, nil, {})
        end
      else
        -- File column node: collapse/expand parent
        state.expanded["__file__"] = not state.expanded["__file__"]
        ctx.render(state)
      end
    elseif node.kind == "table" then
      -- As in SSMS, selecting a table expands it into its folders; s opens rows
      if node.expanded then
        columns()[node.name] = false
        if node.partition_id then groups()[node.partition_id] = false end
      else
        columns()[node.name] = true
      end
      ctx.render(state)
    elseif node.view and node.table_name then
      -- A folder under a table, or one of its items: that view in the grid
      ctx.open_table_view(node.table_name, url, node.view)
    elseif node.kind == "routine" then
      ctx.open_routine_source(node.source_id or node.name, url)
    end
  end)

  -- s: the table's records, as SSMS's "Select Top Rows"; from a folder or item too
  kmap("sidebar_select", function()
    local node = ctx.node_at_cursor(state)
    if not node or node.is_file then return end
    local tbl = (node.kind == "table" and node.name) or node.table_name
    if tbl then ctx.open_table(tbl, url) end
  end)

  -- The run key: on a table row, run its SELECT like `s`. Anything else
  -- (folders, columns, groups) has no query of its own, so it does nothing.
  kmap("sidebar_execute", function()
    local node = ctx.node_at_cursor(state)
    if node and node.kind == "table" and not node.is_file then ctx.open_table(node.name, url) end
  end)

  -- Open table in new split (explicit second grid)
  kmap("sidebar_open_spl", function()
    local node = ctx.node_at_cursor(state)
    if not node then return end
    if node.is_file then return end  -- file nodes have no separate split action
    if node.kind == "table" then
      ctx.open_table_split(node.name, url)
    elseif node.table_name then
      ctx.open_table_split(node.table_name, url)
    elseif node.kind == "routine" then
      ctx.open_routine_source(node.source_id or node.name, url)
    end
  end)

  local function expand()
    local node = ctx.node_at_cursor(state)
    if not node then return end
    if is_group(node) then groups()[node.id] = true
    elseif node.kind == "table" then columns()[node.file_key or node.name] = true
    elseif node.kind == "facet" then state.facets_expanded[tree.facet_key(node.table_name, node.facet)] = true
    else return end
    ctx.render(state)
  end
  local function collapse()
    local node = ctx.node_at_cursor(state)
    if not node then return end
    local anchor = ctx.selection(state)
    if is_group(node) and node.expanded then
      groups()[node.id] = false
    elseif node.kind == "table" and node.expanded then
      columns()[node.file_key or node.name] = false
      if node.partition_id then groups()[node.partition_id] = false end
    elseif node.kind == "facet" and node.expanded then
      state.facets_expanded[tree.facet_key(node.table_name, node.facet)] = false
    elseif node.kind == "facet" then
      columns()[node.table_name] = false
    elseif node.kind == "column" and node.is_file then
      columns()["__file__"] = false
    elseif node.facet then
      -- An item: close the folder it sits in; the cursor lands on that folder
      state.facets_expanded[tree.facet_key(node.table_name, node.facet)] = false
    else
      -- A root has no ancestor; collapsing it must not jump to another object.
      if not anchor.ids[2] then return end
      table.remove(anchor.ids, 1)
      anchor.view.col, anchor.view.leftcol, anchor.view.curswant, anchor.view.coladd = 0, 0, 0, 0
    end
    ctx.render(state, anchor)
  end
  kmap("sidebar_expand", expand)
  kmap("sidebar_expand_z", expand)
  kmap("sidebar_collapse", collapse)
  kmap("sidebar_collap_z", collapse)

  kmap("sidebar_expand_all", function()
    if state.file_cols then columns()["__file__"] = true
    else
      for _, id in ipairs(require("dadbod-grip.schema_tree").containers(state)) do groups()[id] = true end
    end
    ctx.render(state)
  end)
  kmap("sidebar_collap_all", function()
    for key in pairs(columns()) do columns()[key] = false end
    state.facets_expanded = {}
    if state.file_cols then columns()["__file__"] = false
    else
      for _, id in ipairs(require("dadbod-grip.schema_tree").containers(state)) do groups()[id] = false end
    end
    ctx.render(state)
  end)

  kmap("sidebar_filter", function()
    local anchor = ctx.selection(state)
    local input = ui.input({prompt = "Filter: ", default = state.filter or "", allow_empty = true})
    -- input() leaves its prompt echoed on the command line after completion.
    vim.api.nvim_echo({}, false, {})
    if input == nil then return end
    if input == "" then clear_filter(); return end
    if not state.filter then state.search_restore = anchor end
    state.filter, state.search_groups, state.search_columns = input, {}, {}
    ctx.render(state)
    for i, node in ipairs(state.nodes) do
      if node.matched then
        vim.api.nvim_win_set_cursor(ctx.winid(), {ctx.node_offset(state) + i, 0})
        vim.api.nvim_win_call(ctx.winid(), function() vim.fn.winrestview({leftcol = 0}) end)
        break
      end
    end
  end)
  kmap("sidebar_filter_c", clear_filter)

  -- next/prev table node (wraps)
  kmap("sidebar_next", function() ctx.jump_to_next_table(state, 1) end)
  kmap("sidebar_prev", function() ctx.jump_to_next_table(state, -1) end)

  -- Refresh (r and R)
  local function do_refresh()
    ui.blocking("Grip: refreshing schema...", function()
      state.items = nil
      ctx.clear_metadata(state)
      ctx.fetch_tables(state)
      ctx.render(state)
    end)
    vim.notify("Grip: schema refreshed", vim.log.levels.INFO)
  end
  kmap("sidebar_refresh",  do_refresh)
  kmap("sidebar_refresh2", do_refresh)

  -- Yank table/column name to clipboard
  kmap("sidebar_yank", function()
    local node = ctx.node_at_cursor(state)
    if not node then return end
    local name = (node.kind == "table" and node.name)
              or (node.kind == "column" and node.name)
              or (node.kind == "routine" and node.name)
              or nil
    if name then
      vim.fn.setreg("+", name)
      vim.fn.setreg('"', name)
      vim.notify("Copied: " .. name, vim.log.levels.INFO)
    end
  end)

  -- table_picker / table_picker_alt: table picker
  local function _pick_table()
    require("dadbod-grip.picker").pick_table(url, function(name) ctx.open_table(name, url) end)
  end
  kmap("table_picker",     _pick_table)
  kmap("table_picker_alt", _pick_table)

  -- sidebar_open_s: open table under cursor with smart ORDER BY (latest rows first)
  kmap("sidebar_open_s", function()
    local node = ctx.node_at_cursor(state)
    if not node then return end

    -- File nodes: focus grid if open, otherwise open the file
    if node.is_file then
      local view_mod = require("dadbod-grip.view")
      local content_win = view_mod.find_content_win()
      local content_buf = content_win and vim.api.nvim_win_get_buf(content_win)
      if content_win and view_mod._sessions[content_buf] then
        vim.api.nvim_set_current_win(content_win)
      else
        require("dadbod-grip").open(url, nil, {})
      end
      return
    end

    local tbl = (node.kind == "table" and node.name) or node.table_name
    if not tbl then return end

    ctx.ensure_columns(state, tbl)
    ctx.ensure_keys(state, tbl)
    local cols   = state.col_cache[tbl] or {}
    local pk_set = state.pk_cache[tbl]  or {}

    -- Build lowercase name → original-case map for O(1) lookup
    local col_map = {}
    for _, col in ipairs(cols) do col_map[col.column_name:lower()] = col.column_name end

    -- Prefer timestamp columns so the grid opens showing the latest rows first
    local order_col
    for _, ts in ipairs({ "created_at", "inserted_at", "date_created", "created_on",
                          "updated_at", "modified_at", "date_updated", "updated_on",
                          "timestamp", "ts" }) do
      if col_map[ts] then order_col = col_map[ts]; break end
    end

    -- Fall back to any PK column
    if not order_col then
      for _, col in ipairs(cols) do
        if pk_set[col.column_name] then order_col = col.column_name; break end
      end
    end

    local grip = require("dadbod-grip")
    local target_win = ctx.find_right_win()
    if target_win then vim.api.nvim_set_current_win(target_win) end
    local arg = order_col
      and ("SELECT * FROM " .. tbl .. " ORDER BY " .. order_col .. " DESC")
      or tbl
    grip.open(arg, url, { reuse_win = target_win })
  end)

  -- schema_browser: close sidebar (from inside; gb elsewhere opens/focuses it)
  kmap("schema_browser", function() ctx.close() end)

  -- welcome: go to welcome screen (home)
  kmap("welcome", function() require("dadbod-grip").open_welcome() end)

  -- query_pad: open query pad
  kmap("query_pad", function()
    local query_pad = require("dadbod-grip.query_pad")
    query_pad.open(url)
  end)

  -- load_saved: load saved query into query pad
  kmap("load_saved", function()
    local saved = require("dadbod-grip.saved")
    saved.pick(function(sql_content, _, bound_url)
      require("dadbod-grip.query_pad").open(bound_url or url, { initial_sql = sql_content })
    end)
  end)

  -- query_history: load query history into query pad
  kmap("query_history", function()
    require("dadbod-grip.history").pick(function(sql_content)
      require("dadbod-grip.query_pad").open(url, { initial_sql = sql_content })
    end)
  end)

  -- open_notebook: open a .md or .sql notebook file in the query pad
  kmap("open_notebook", function()
    require("dadbod-grip.query_pad").pick_notebook()
  end)

  -- goto_grid: jump to main content window
  kmap("goto_grid", function()
    local win = require("dadbod-grip.view").find_content_win()
    if win then vim.api.nvim_set_current_win(win) end
  end, { nowait = true })

  -- Switch connection (connections, sidebar_conns, connections_alt)
  -- on_cancel is a no-op: cancelling the picker keeps the sidebar visible.
  local function _pick_conn()
    require("dadbod-grip.connections").pick({ on_cancel = function() end })
  end
  kmap("connections",     _pick_conn)
  kmap("sidebar_conns",   _pick_conn)
  kmap("connections_alt", _pick_conn)

  -- sidebar_drop: drop table
  kmap("sidebar_drop", function()
    local node = ctx.node_at_cursor(state)
    if not node or node.kind ~= "table" then
      vim.notify("Move cursor to a table", vim.log.levels.INFO)
      return
    end
    if require("dadbod-grip.connections").deny_if_readonly("Drop table", url) then return end
    local ddl = require("dadbod-grip.ddl")
    ddl.drop_table(node.name, url, function()
      state.items = nil
      state.routines = nil
      ctx.clear_metadata(state)
      ctx.fetch_tables(state)
      ctx.render(state)
    end)
  end)

  -- sidebar_create: create table
  kmap("sidebar_create", function()
    if require("dadbod-grip.connections").deny_if_readonly("Create table", url) then return end
    local ddl = require("dadbod-grip.ddl")
    ddl.create_table(url, function()
      state.items = nil
      ctx.clear_metadata(state)
      ctx.fetch_tables(state)
      ctx.render(state)
    end)
  end)

  -- tab_1: connections picker (already in sidebar = secondary action)
  kmap("tab_1", _pick_conn)

  -- tab_2: open query pad
  kmap("tab_2", function()
    require("dadbod-grip.query_pad").open(url)
  end)

  -- tab_3: jump to existing grid; if none, open table under cursor; if no node, table picker
  kmap("tab_3", function()
    local win = require("dadbod-grip.view").find_content_win()
    if win then
      vim.api.nvim_set_current_win(win)
      return
    end
    local node = ctx.node_at_cursor(state)
    local tbl = node and ((node.kind == "table" and node.name) or node.table_name)
    if tbl then
      ctx.open_table(tbl, url)
    else
      _pick_table()
    end
  end)

  -- tab_4-9: ER diagram float or open table in a specific view facet
  for n = 4, 9 do
    local view_name = km.TAB_VIEWS[n]
    kmap("tab_" .. n, function()
        if view_name == "er_diagram" then
          require("dadbod-grip.er_diagram").toggle(url)
          return
        end
        local node = ctx.node_at_cursor(state)
        if not node then return end
        local tbl = (node.kind == "table" and node.name) or node.table_name
        if not tbl then return end
        local grip = require("dadbod-grip")
        local target_win = ctx.find_right_win()
        if target_win then vim.api.nvim_set_current_win(target_win) end
        grip.open(tbl, url, { reuse_win = target_win, view = view_name })
      end)
  end

  -- sidebar_attach: attach external DB (DuckDB federation)
  kmap("sidebar_attach", function()
    if not url or not url:find("^duckdb:") then
      vim.notify("Attach requires a DuckDB connection.", vim.log.levels.WARN)
      return
    end
    vim.cmd("GripAttach")
  end)

  -- sidebar_detach: detach external DB
  kmap("sidebar_detach", function()
    if not url or not url:find("^duckdb:") then
      vim.notify("Detach requires a DuckDB connection.", vim.log.levels.WARN)
      return
    end
    vim.cmd("GripDetach")
  end)

  -- er_diagram: ER diagram float (scroll to table under cursor if on a table node)
  kmap("er_diagram", function()
    local node = ctx.node_at_cursor(state)
    local tbl = node and ((node.kind == "table" and node.name) or node.table_name)
    if tbl then require("dadbod-grip.er_diagram").toggle(url, tbl, { focus = true }) end
  end)

  kmap("sidebar_close", function() ctx.close() end)

  -- palette: command palette
  kmap("palette", function()
    require("dadbod-grip.palette").open("sidebar")
  end)

  -- help: schema help popup
  kmap("help", function()
    local lines = {
      "",
      "  Schema Browser",
      " ─────────────────────────────────────────",
      "",
      "  Navigation",
      "  j/k       Move between items",
      "  <CR>      Open object / toggle group",
      "  S-CR      Open table in new split",
      "  l / zo    Expand group or table columns",
      "  h / zc    Collapse / move to parent",
      "  L         Expand all schema/partition levels",
      "  H         Collapse groups and columns",
      "  /         Search hidden names/signatures",
      "  F         Clear filter, restore view",
      "  zh/zl     Scroll labels horizontally",
      "  zH/zL     Scroll labels by half a window",
      "  0 / $     Move to start / end of label",
      "",
      "  Tab Views",
      "  1         Connections picker",
      "  2         Query pad",
      "  3         Jump to grid / table picker",
      "  4         ER diagram (full map)",
      "  5         Stats view",
      "  6         Columns view",
      "  7         Foreign keys view",
      "  8         Indexes view",
      "  9         Constraints view",
      "",
      "  Actions",
      "  r         Refresh schema",
      "  y         Yank table/column name",
      "  go        Open table, ORDER BY latest (created_at / PK)",
      "  gT / gt   Table picker (fuzzy finder)",
      "  gb        Close browser (gb outside: open/focus)",
      "  gw        Jump to grid",
      "  gC / gc   Switch connection",
      "  gh        Query history",
      "  gq        Saved queries",
      "  q         Query pad",
      "  ga        Attach external DB (DuckDB federation)",
      "  gd        Detach attached database",
      "  gG        ER diagram (focus table neighborhood)",
      "  D         Drop table (confirm)",
      "  +         Create table",
      "  Esc       Close sidebar",
      "  ?         Toggle this help",
      "",
      " ─────────────────────────────────────────",
      "",
      "  ╔═╦═╦═╗",
      "  ║d║b║g║  dadbod-grip v" .. VERSION,
      "  ╚═╩═╩═╝",
      "",
    }
    local grip_win = vim.api.nvim_get_current_win()
    local max_w = 0
    for _, line in ipairs(lines) do max_w = math.max(max_w, #line) end
    max_w = math.max(max_w + 2, 44)
    local popup_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
    -- Full schema help highlights
    local ns_sh = vim.api.nvim_create_namespace("grip_schema_help_hl")
    local function sadd(ln, group, s, e)
      -- Missing or negative end column means "to the end of the line": add_highlight
      -- took col_end = -1 for that, set_extmark wants end_row = ln + 1 / end_col = 0.
      local opts = { hl_group = group }
      if e and e >= 0 then opts.end_col = e else opts.end_row, opts.end_col = ln + 1, 0 end
      vim.api.nvim_buf_set_extmark(popup_buf, ns_sh, ln, s or 0, opts)
    end
    for i, line in ipairs(lines) do
      local ln = i - 1
      if    line:match("^    %a") then                                           sadd(ln, "Special")
      elseif line:find("╔═╦") or line:find("║d║") or line:find("╚═╩") then     sadd(ln, "Special")
      elseif line:match("^%s+[─═]") then sadd(ln, "Comment")
      elseif line:find("\xe2\x86\xb3") then sadd(ln, "Comment")   -- ↳ continuation
      elseif line:match("^  %S") and not line:find("%s%s", 3) then sadd(ln, "Title")
      elseif line:match("^  %S") then
        local key_end = line:find("%s%s", 3)
        if key_end then sadd(ln, "Identifier", 2, key_end - 1) end
      end
    end
    local win = ui.info_float({
      buf = popup_buf,
      width = max_w,
      height = #lines,
      title = " Schema Help ",
      title_pos = "center",
      zindex = 50,
    })
    local function close()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end

    vim.api.nvim_create_autocmd("WinLeave", {
      group  = ctx.augroup,
      buffer = popup_buf,
      once = true,
      callback = function() vim.schedule(close) end,
    })

    for _, key in ipairs({ "q", "?", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        close()
        if vim.api.nvim_win_is_valid(grip_win) then
          vim.api.nvim_set_current_win(grip_win)
        end
      end, { buffer = popup_buf })
    end
  end)
end

--- Compute the automatic sidebar width for an editor width.

return M
