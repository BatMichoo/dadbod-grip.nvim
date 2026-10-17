-- commands.lua: the :Grip* user commands.

local M = {}

-- Modules load on first use, not when the commands are registered at startup.
local function lazy(name)
  return setmetatable({}, { __index = function(_, k) return require(name)[k] end })
end
local view    = lazy("dadbod-grip.view")
local query   = lazy("dadbod-grip.query")
local db      = lazy("dadbod-grip.db")
local explain = lazy("dadbod-grip.explain")
local ui      = lazy("dadbod-grip.ui")
local function esc(s) return require("dadbod-grip.sql").escape_literal(s) end
local function grip() return require("dadbod-grip") end

local _ag = vim.api.nvim_create_augroup("DadbodGripCommands", { clear = true })

--- Shorthand for the shared read-only guard; see connections.deny_if_readonly.
--- @param cmd_name string
--- @param url string|nil  defaults to the current connection
local function deny_if_readonly(cmd_name, url)
  return require("dadbod-grip.connections").deny_if_readonly(cmd_name, url)
end

--- Resolve what a table-scoped user command should act on: the explicit
--- argument first, then the table behind the current grip session.
--- Notifies and returns nil when either the table or the connection is missing.
--- @param cmd_opts table    user-command opts (reads .args)
--- @param cmd_name string   command name, used as the warning prefix
--- @param no_table_msg? string  override for the "no table" warning text
--- @return string|nil table_name
--- @return string|nil url
local function resolve_target(cmd_opts, cmd_name, no_table_msg)
  local table_name = vim.trim(cmd_opts.args or "")
  if table_name == "" then
    local session = view._sessions[vim.api.nvim_get_current_buf()]
    if session and session.state.table_name then
      table_name = session.state.table_name
    end
  end
  if table_name == "" then
    vim.notify(cmd_name .. ": " .. (no_table_msg or "provide a table name or run from a Grip buffer"),
      vim.log.levels.WARN)
    return nil
  end
  local url = db.get_url()
  if not url then
    vim.notify(cmd_name .. ": no database connection", vim.log.levels.WARN)
    return nil
  end
  return table_name, url
end


--- Register every :Grip* command. Safe to call more than once: each
--- nvim_create_user_command replaces the previous definition.
function M.register()
  -- Register :Grip command
  vim.api.nvim_create_user_command("Grip", function(cmd_opts)
    local arg = vim.trim(cmd_opts.args or "")
    -- Parse --write and --watch[=Ns] flags, stripping them from the query arg
    local grip_opts = {}
    arg = arg:gsub("%s*%-%-write%s*", function() grip_opts.write = true; return " " end)
    arg = arg:gsub("%s*%-%-watch=(%d+)s?%s*", function(n)
      grip_opts.watch_ms = tonumber(n) * 1000
      return " "
    end)
    arg = arg:gsub("%s*%-%-watch%s*", function()
      if not grip_opts.watch_ms then grip_opts.watch_ms = 5000 end
      return " "
    end)
    arg = vim.trim(arg)
    -- No arg: show welcome screen (resolve_query handles <cword> fallback when needed)
    if arg == "" then
      grip().open_welcome()
      return
    end
    grip().open(arg, nil, next(grip_opts) and grip_opts or nil)
  end, {
    nargs = "?",
    desc  = "Open dadbod-grip result grid for table or query",
  })

  -- Register :GripExplain command
  vim.api.nvim_create_user_command("GripExplain", function(cmd_opts)
    local arg = vim.trim(cmd_opts.args or "")

    -- If no arg, try to get SQL from current grip session
    if arg == "" then
      local bufnr = vim.api.nvim_get_current_buf()
      local session = view._sessions[bufnr]
      if session and session.query_spec then
        arg = query.build_sql(session.query_spec)
      elseif session and session.query_sql then
        arg = session.query_sql
      end
    end
    if arg == "" then
      vim.notify("GripExplain: provide a SQL query or run from a Grip buffer", vim.log.levels.WARN)
      return
    end

    -- Resolve connection
    local conn = vim.b.db
    if type(conn) ~= "string" or conn == "" then conn = vim.g.db end
    if type(conn) == "table" and conn.db_url then conn = conn.db_url end
    if not conn or conn == "" then
      vim.notify("GripExplain: no database connection", vim.log.levels.WARN)
      return
    end

    local result, err = db.explain(arg, conn)
    if err then
      vim.notify("EXPLAIN failed: " .. err, vim.log.levels.ERROR)
      return
    end
    if not result or not result.lines or #result.lines == 0 then
      vim.notify("EXPLAIN returned no output", vim.log.levels.INFO)
      return
    end

    local hist = require("dadbod-grip.history")
    hist.record({ sql = arg, url = conn, type = "explain" })

    -- Parse and render as Query Doctor
    local adapter_type = explain.detect_adapter(conn)
    local nodes = explain.parse_nodes(result.lines, adapter_type)
    local doctor_lines, doctor_marks = explain.render(nodes, adapter_type)

    local explain_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(explain_buf, 0, -1, false, doctor_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = explain_buf })

    local max_w = 0
    for _, l in ipairs(doctor_lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
    local width = math.min(math.max(max_w + 4, 40), vim.o.columns - 10)
    local height = math.min(#doctor_lines, math.floor(vim.o.lines * 0.7))

    local win = vim.api.nvim_open_win(explain_buf, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = "minimal",
      border = ui.border(),
      title = " Query Health ",
      title_pos = "center",
    })

    -- Apply highlights
    local explain_ns = vim.api.nvim_create_namespace("grip_explain")
    for _, m in ipairs(doctor_marks) do
      pcall(vim.api.nvim_buf_set_extmark, explain_buf, explain_ns, m.line - 1, 0, {
        end_col = #(doctor_lines[m.line] or ""),
        hl_group = m.hl,
      })
    end

    -- Close keymaps
    local function close()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end

    vim.api.nvim_create_autocmd("WinLeave", {
      group  = _ag,
      buffer = explain_buf,
      once = true,
      callback = function() vim.schedule(close) end,
    })

    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, close, { buffer = explain_buf })
    end
  end, {
    nargs = "?",
    desc  = "Show EXPLAIN plan for a query",
  })

  -- Register :GripSchema command
  vim.api.nvim_create_user_command("GripSchema", function()
    local schema = require("dadbod-grip.schema")
    schema.toggle()
  end, {
    nargs = 0,
    desc  = "Toggle schema browser sidebar",
  })

  -- Register :GripTables command
  vim.api.nvim_create_user_command("GripTables", function()
    local picker = require("dadbod-grip.picker")
    local url = db.get_url()
    if not url then
      vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
      return
    end
    picker.pick_table(url, function(name) grip().open(name, url) end)
  end, {
    nargs = 0,
    desc  = "Open table picker",
  })

  -- Register :GripQuery command
  vim.api.nvim_create_user_command("GripQuery", function(cmd_opts)
    local query_pad = require("dadbod-grip.query_pad")
    local url = db.get_url()
    local initial = vim.trim(cmd_opts.args or "")
    query_pad.open(url, initial ~= "" and { initial_sql = initial } or nil)
  end, {
    nargs = "?",
    desc  = "Open SQL query pad",
  })

  -- Register :GripSave command
  vim.api.nvim_create_user_command("GripSave", function(cmd_opts)
    local saved = require("dadbod-grip.saved")
    local name = vim.trim(cmd_opts.args or "")
    local bufnr = vim.api.nvim_get_current_buf()
    if name == "" then
      saved.save_prompt(bufnr)
    else
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      saved.save(name, table.concat(lines, "\n"), vim.b[bufnr].db or vim.g.db)
    end
  end, {
    nargs = "?",
    desc  = "Save current query",
  })

  -- Register :GripLoad command
  vim.api.nvim_create_user_command("GripLoad", function(cmd_opts)
    local saved = require("dadbod-grip.saved")
    local name = vim.trim(cmd_opts.args or "")
    if name ~= "" then
      local content, bound_url = saved.load(name)
      if content then
        local query_pad = require("dadbod-grip.query_pad")
        local url = bound_url or db.get_url()
        query_pad.open(url, { initial_sql = content })
      end
    else
      saved.pick(function(content, _, bound_url)
        local query_pad = require("dadbod-grip.query_pad")
        local url = bound_url or db.get_url()
        query_pad.open(url, { initial_sql = content })
      end)
    end
  end, {
    nargs = "?",
    desc  = "Load a saved query",
  })

  -- Register :GripHistory command
  vim.api.nvim_create_user_command("GripHistory", function()
    local hist = require("dadbod-grip.history")
    hist.pick(function(content)
      local query_pad = require("dadbod-grip.query_pad")
      local url = db.get_url()
      query_pad.open(url, { initial_sql = content })
    end)
  end, {
    nargs = 0,
    desc  = "Browse query history",
  })

  -- Register :GripProfile command
  vim.api.nvim_create_user_command("GripProfile", function(cmd_opts)
    local tbl, conn = resolve_target(cmd_opts, "GripProfile")
    if not tbl then return end
    local profile = require("dadbod-grip.profile")
    profile.open(tbl, conn)
  end, {
    nargs = "?",
    desc  = "Profile table columns with sparkline distributions",
  })

  -- Register :GripDiff command
  vim.api.nvim_create_user_command("GripDiff", function(cmd_opts)
    local args = vim.split(vim.trim(cmd_opts.args or ""), "%s+")
    if #args < 2 then
      vim.notify("Usage: :GripDiff table1 table2", vim.log.levels.WARN)
      return
    end
    local url = db.get_url()
    if not url then
      vim.notify("GripDiff: no database connection", vim.log.levels.WARN)
      return
    end
    local diff_mod = require("dadbod-grip.diff")
    diff_mod.open(args[1], args[2], url)
  end, {
    nargs = "+",
    desc  = "Diff two tables side-by-side",
  })

  -- Register :GripCreate command
  vim.api.nvim_create_user_command("GripCreate", function()
    if deny_if_readonly("GripCreate") then return end
    local url = db.get_url()
    if not url then
      vim.notify("GripCreate: no database connection. Use :GripConnect.", vim.log.levels.WARN)
      return
    end
    local ddl_mod = require("dadbod-grip.ddl")
    ddl_mod.create_table(url, function()
      -- Refresh schema browser if open
      local schema_mod = require("dadbod-grip.schema")
      if schema_mod.is_open() then
        schema_mod.refresh(url)
      end
    end)
  end, {
    nargs = 0,
    desc  = "Create a new table interactively",
  })

  -- Register :GripDrop command
  vim.api.nvim_create_user_command("GripDrop", function(cmd_opts)
    if deny_if_readonly("GripDrop") then return end
    local table_name, url = resolve_target(cmd_opts, "GripDrop", "provide a table name")
    if not table_name then return end
    local ddl_mod = require("dadbod-grip.ddl")
    ddl_mod.drop_table(table_name, url, function()
      local schema_mod = require("dadbod-grip.schema")
      if schema_mod.is_open() then
        schema_mod.refresh(url)
      end
    end)
  end, {
    nargs = "?",
    desc  = "Drop a table (requires typed confirmation)",
  })

  -- Register :GripRename command
  vim.api.nvim_create_user_command("GripRename", function(cmd_opts)
    local args = vim.split(vim.trim(cmd_opts.args or ""), "%s+")
    local bufnr = vim.api.nvim_get_current_buf()
    local session = view._sessions[bufnr]
    local table_name = session and session.state.table_name

    if not table_name then
      vim.notify("GripRename: run from a Grip buffer", vim.log.levels.WARN)
      return
    end
    local url = db.get_url(session and session.url)
    if not url then
      vim.notify("GripRename: no database connection", vim.log.levels.WARN)
      return
    end
    -- Guarded on the URL the ALTER below actually runs against, not on the
    -- ambient one: this command is the only one whose action reads
    -- session.url, and guarding the ambient connection instead let a rename
    -- through against a ro connection whenever the two had drifted apart.
    if deny_if_readonly("GripRename", url) then return end

    local ddl_mod = require("dadbod-grip.ddl")
    if #args >= 2 then
      -- :GripRename old_name new_name
      local old_name, new_name = args[1], args[2]
      local sql_mod = require("dadbod-grip.sql")
      local ddl_sql = string.format('ALTER TABLE %s RENAME COLUMN %s TO %s',
        sql_mod.quote_ident(table_name), sql_mod.quote_ident(old_name), sql_mod.quote_ident(new_name))
      local _, err = db.execute(ddl_sql, url)
      if err then
        vim.notify("Rename failed: " .. err, vim.log.levels.ERROR)
      else
        vim.notify("Renamed " .. old_name .. " to " .. new_name, vim.log.levels.INFO)
        if session.on_refresh then session.on_refresh(bufnr) end
      end
    elseif #args == 1 then
      ddl_mod.rename_column(table_name, args[1], url, function()
        if session.on_refresh then session.on_refresh(bufnr) end
      end)
    else
      vim.notify("Usage: :GripRename old_name [new_name]", vim.log.levels.WARN)
    end
  end, {
    nargs = "+",
    desc  = "Rename a column: :GripRename old_name new_name",
  })

  -- Register :GripProperties command
  vim.api.nvim_create_user_command("GripProperties", function(cmd_opts)
    local table_name, url = resolve_target(cmd_opts, "GripProperties")
    if not table_name then return end
    local properties = require("dadbod-grip.properties")
    properties.open(table_name, url)
  end, {
    nargs = "?",
    desc  = "Show table properties (columns, indexes, stats)",
  })

  -- Register :GripConnect command
  vim.api.nvim_create_user_command("GripConnect", function(cmd_opts)
    local connections = require("dadbod-grip.connections")
    local arg = vim.trim(cmd_opts.args or "")
    if arg ~= "" then
      -- Direct URL or name
      local conns = connections.list()
      for _, c in ipairs(conns) do
        if c.name == arg then
          connections.switch(c.url, c.name)
          return
        end
      end
      -- Treat as URL
      connections.switch(arg)
    else
      connections.pick()
    end
  end, {
    nargs = "?",
    desc  = "Switch database connection",
  })

  -- :GripAttach [dsn] [alias]: attach external DB to DuckDB session
  vim.api.nvim_create_user_command("GripAttach", function(cmd_opts)
    local connections = require("dadbod-grip.connections")
    local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
    local schema_mod = require("dadbod-grip.schema")

    -- url is the active connection as stored (templated: the key its entry
    -- lives under in connections.json); conn_url is the expanded form the
    -- adapter's attachment registry is keyed by. This command bypasses
    -- db.resolve(), so it expands by hand.
    local url = vim.g.db
    local conn_url = connections.expand_url(url)
    if not conn_url or not conn_url:find("^duckdb:") then
      vim.notify("GripAttach: requires a DuckDB connection. Use :GripConnect to switch.", vim.log.levels.WARN)
      return
    end

    local args = vim.split(vim.trim(cmd_opts.args or ""), "%s+")
    local dsn, alias
    if #args >= 2 then
      alias = args[#args]
      dsn = table.concat(args, " ", 1, #args - 1)
    else
      local d = ui.input({ prompt = "Connection (e.g. postgres:dbname=mydb user=me): " })
      if not d then return end
      dsn = d
      local a = ui.input({ prompt = "Alias (used in queries, e.g. pg): " })
      if not a then return end
      alias = a
    end

    -- A hand-typed DSN may reference ${VAR} too; resolve it against the
    -- active connection's env_file and keep the placeholder for persistence.
    local live_dsn, dsn_err = connections.expand_dsn(dsn, url)
    if not live_dsn then
      vim.notify("GripAttach: " .. (dsn_err or "unresolved secrets in DSN"), vim.log.levels.ERROR)
      return
    end
    local err = duckdb_adapter.attach(conn_url, live_dsn, alias, live_dsn ~= dsn and dsn or nil)
    if err then
      vim.notify("GripAttach: " .. err, vim.log.levels.ERROR)
      return
    end
    connections.save_attachments(url, duckdb_adapter.get_attachments(conn_url))
    schema_mod.refresh(url)
    vim.notify(string.format("Attached '%s' as %s", dsn, alias), vim.log.levels.INFO)
  end, {
    nargs = "*",
    desc  = "Attach external database to DuckDB session",
  })

  -- :GripDetach [alias]: detach a previously attached database
  vim.api.nvim_create_user_command("GripDetach", function(cmd_opts)
    local connections = require("dadbod-grip.connections")
    local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
    local schema_mod = require("dadbod-grip.schema")

    -- Same template/expanded split as :GripAttach above.
    local url = vim.g.db
    local conn_url = connections.expand_url(url)
    if not conn_url or not conn_url:find("^duckdb:") then
      vim.notify("GripDetach: requires a DuckDB connection.", vim.log.levels.WARN)
      return
    end

    local alias = vim.trim(cmd_opts.args or "")
    if alias == "" then
      local atts = duckdb_adapter.get_attachments(conn_url)
      if #atts == 0 then
        vim.notify("GripDetach: no databases attached.", vim.log.levels.INFO)
        return
      end
      local names = {}
      for _, a in ipairs(atts) do table.insert(names, a.alias) end
      local val = ui.input({ prompt = "Detach alias (" .. table.concat(names, ", ") .. "): " })
      if not val then return end
      alias = val
    end

    duckdb_adapter.detach(conn_url, alias)
    connections.save_attachments(url, duckdb_adapter.get_attachments(conn_url))
    schema_mod.refresh(url)
    vim.notify(string.format("Detached '%s'", alias), vim.log.levels.INFO)
  end, {
    nargs = "?",
    desc  = "Detach database from DuckDB session",
  })

  -- :GripOpen [path]: open any data source without saving to connections
  vim.api.nvim_create_user_command("GripOpen", function(cmd_opts)
    local path = vim.fn.trim(cmd_opts.args or "")
    local connections = require("dadbod-grip.connections")
    if path == "" then
      connections.pick()
      return
    end
    path = vim.fn.expand(path)
    -- S3 prefix (no file extension): open query pad pre-filled with glob()
    if path:match("^s3://") and not path:match("%.[a-zA-Z0-9]+$") then
      local safe = esc(path)
      local sql_str = string.format("SELECT * FROM glob('%s*') LIMIT 100", safe)
      local cur = connections.current()
      require("dadbod-grip.query_pad").open(cur and cur.url or "", { initial_sql = sql_str })
    else
      -- file path, HTTPS URL, or s3://...parquet: ephemeral (nil name = not saved)
      connections.switch(path, nil, nil, nil)
    end
  end, { nargs = "?", complete = "file",
         desc = "Open any data source (file, HTTPS, s3://) without saving" })

  -- :GripHome: return to the welcome screen from anywhere
  vim.api.nvim_create_user_command("GripHome", function()
    grip().open_welcome()
  end, { desc = "Open dadbod-grip welcome screen" })

  -- :GripToggle: close all grip windows if visible, reopen if hidden
  vim.api.nvim_create_user_command("GripToggle", function()
    -- Find all windows showing grip:// buffers
    local grip_wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("^grip://") then
        grip_wins[#grip_wins + 1] = { win = win, buf = buf }
      end
    end

    if #grip_wins > 0 then
      -- Close: wipe all grip buffers (triggers bufhidden=wipe cleanup)
      local seen = {}
      for _, gw in ipairs(grip_wins) do
        if not seen[gw.buf] and vim.api.nvim_buf_is_valid(gw.buf) then
          seen[gw.buf] = true
          pcall(vim.api.nvim_buf_delete, gw.buf, { force = true })
        end
      end
    else
      -- Open: reconnect to previous connection or show picker
      local connections = require("dadbod-grip.connections")
      local cur = connections.current()
      if cur and cur.url then
        connections.switch(cur.url, cur.name)
      else
        connections.pick()
      end
    end
  end, { desc = "Toggle dadbod-grip windows on/off" })

  -- :GripExport: export current result set to a file
  vim.api.nvim_create_user_command("GripExport", function()
    local bufnr = vim.api.nvim_get_current_buf()
    view.do_export(bufnr)
  end, { desc = "Export grip result to file (csv/json/sql)" })

  -- :GripImport: parse clipboard rows, or stdout from an explicit !command,
  -- then stage them as inserts in the current editable grid.
  vim.api.nvim_create_user_command("GripImport", function(cmd_opts)
    grip().do_import(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Preview and stage CSV, TSV, or JSON rows from clipboard or !command",
  })
end

return M
