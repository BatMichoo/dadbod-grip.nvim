-- init.lua: plugin entry point — setup(), open() and the public API.
-- Commands live in commands.lua, the start screen in welcome.lua, grid
-- actions (apply, refresh, edit) in session_actions.lua.
--
-- Loaded at startup by plugin/dadbod-grip.lua, so every other module is
-- required on first use: setup() itself only stores options and registers
-- the commands.

local function lazy(name)
  return setmetatable({}, { __index = function(_, k) return require(name)[k] end })
end
local db       = lazy("dadbod-grip.db")
local data     = lazy("dadbod-grip.data")
local view     = lazy("dadbod-grip.view")
local query    = lazy("dadbod-grip.query")
local ui       = lazy("dadbod-grip.ui")
local filetypes = lazy("dadbod-grip.filetypes")
local importer = lazy("dadbod-grip.importer")
local adapters = lazy("dadbod-grip.adapters")
local actions  = lazy("dadbod-grip.session_actions")
local sql      = lazy("dadbod-grip.sql")
local function esc(s) return sql.escape_literal(s) end

local M = {}
M._version = require("dadbod-grip.version")

-- Highlight groups are defined up front: the sidebar, query pad and popups
-- use them before any grid (which would otherwise load them) exists.
require("dadbod-grip.view.highlights")

-- Query Doctor moved to explain.lua; the historical names stay on the plugin
-- module.
function M._parse_explain_nodes(...) return require("dadbod-grip.explain").parse_nodes(...) end
function M._render_query_doctor(...) return require("dadbod-grip.explain").render(...) end

local config = require("dadbod-grip.config")
local OPTS = config.values

--- Return a copy of the current options.
function M.get_opts()
  return config.get()
end

-- ── helpers ───────────────────────────────────────────────────────────────

--- Re-render a grip buffer if it's still valid and has a session.
function M._render_if_visible(bufnr)
  local s = view._sessions[bufnr]
  if s and vim.api.nvim_buf_is_valid(bufnr) then
    view.render(bufnr, s.state)
  end
end

--- Detect if arg is a queryable file path or URL for DuckDB file-as-table.
local function is_queryable_file(arg)
  local is_path = arg:match("^/") or arg:match("^~/") or arg:match("^%./") or arg:match("^%.%./")
  local is_url = arg:match("^https?://") or arg:match("^s3://")
  if not is_path and not is_url then
    return false
  end
  return filetypes.has_supported_extension(arg)
end

--- Shorthand for the shared read-only guard; see connections.deny_if_readonly.
--- @param cmd_name string
--- @param url string|nil  defaults to the current connection
local function deny_if_readonly(cmd_name, url)
  return require("dadbod-grip.connections").deny_if_readonly(cmd_name, url)
end

local function select_editable_table(...)
  return require("dadbod-grip.editable_source").select_editable_table(...)
end

-- Decide the query spec for a given :Grip argument.
-- Returns (spec, table_name, file_path) or (nil, err_string).
local function resolve_query(arg, limit, adapter_kind)
  if not arg or arg == "" then
    arg = vim.fn.expand("<cword>")
  end
  if arg == "" then
    return nil, "No table name or query provided."
  end

  -- File-as-table or URL-as-table: route to DuckDB
  if is_queryable_file(arg) then
    if arg:match("^https?://") or arg:match("^s3://") then
      -- Remote URL: pass through to DuckDB httpfs
      local file_sql = string.format("SELECT * FROM '%s'", esc(arg))
      return query.new_raw(file_sql, limit), nil, arg
    end
    local path = arg
    if path:sub(1, 1) == "~" then
      path = (os.getenv("HOME") or "") .. path:sub(2)
    end
    path = vim.fn.fnamemodify(path, ":p")
    if vim.fn.filereadable(path) == 0 then
      return nil, "File not found: " .. path
    end
    local file_sql = string.format("SELECT * FROM '%s'", esc(path))
    return query.new_raw(file_sql, limit), nil, path
  end

  -- Detect statement type
  local upper = arg:upper():match("^%s*(%u+)")
  if upper == "SELECT" or upper == "TABLE" then
    local table_name = nil
    local flat = arg:gsub("\n", " ")
    if upper == "TABLE" then
      -- TABLE <name> is always a single table
      local raw = flat:match('^%s*[Tt][Aa][Bb][Ll][Ee]%s+"([^"]+)"')
        or flat:match("^%s*[Tt][Aa][Bb][Ll][Ee]%s+`([^`]+)`")
        or flat:match("^%s*[Tt][Aa][Bb][Ll][Ee]%s+([%w_%.]+)")
      if raw then table_name = sql.unquote_ident(raw) end
    else
      table_name = select_editable_table(arg, adapter_kind)
    end
    return query.new_raw(arg), table_name
  end
  -- WITH can be a read-only CTE (SELECT) or a mutating CTE (UPDATE/DELETE/INSERT).
  -- Scan for mutation keywords to decide; default to SELECT if none found.
  if upper == "WITH" then
    local stripped = arg:upper():gsub("'[^']*'", ""):gsub("%-%-.-%\n", "")
    if stripped:find("%f[%u]UPDATE%f[^%u]") or stripped:find("%f[%u]DELETE%f[^%u]")
        or stripped:find("%f[%u]INSERT%f[^%u]") then
      return nil, nil, nil, arg
    end
    return query.new_raw(arg), nil
  end
  -- REPLACE INTO (MySQL/SQLite): route through mutation preview like INSERT
  if upper == "REPLACE" then
    return nil, nil, nil, arg
  end
  -- Destructive statements: execute directly, don't wrap in SELECT
  if upper == "UPDATE" or upper == "DELETE" or upper == "INSERT"
    or upper == "ALTER" or upper == "DROP" or upper == "CREATE"
    or upper == "BEGIN" or upper == "COMMIT" or upper == "ROLLBACK" then
    return nil, nil, nil, arg  -- 4th return = mutation SQL
  end
  -- Otherwise treat as table name
  return query.new_table(arg, limit), arg
end

local function do_apply(...) return actions.do_apply(...) end
local function do_refresh(...) return actions.do_refresh(...) end
local function do_edit(...) return actions.do_edit(...) end
local function spinner_label(...) return actions.spinner_label(...) end
local function fetch_refresh(...) return actions.fetch_refresh(...) end
local function apply_refresh(...) return actions.apply_refresh(...) end
function M._mutation_preview(...) return actions._mutation_preview(...) end
function M._next_edit_cursor(...) return actions._next_edit_cursor(...) end

-- ── open ──────────────────────────────────────────────────────────────────
---Open a table or raw SQL query in a grip grid.
---@param arg string  Table name or SQL query
---@param url? string Connection URL (uses active connection if nil)
---@param opts? table Additional options (write, watch_ms)
function M.open(arg, url, opts)
  -- Resolve connection URL
  local conn = url
  if not conn or conn == "" then
    conn = vim.b.db
    if not conn or conn == "" then conn = vim.g.db end
  end

  -- Resolve query spec (must happen before connection check for file-as-table).
  -- Pass the adapter kind when available so projection parsing can stay
  -- conservative around dialect-specific identifier quoting.
  local adapter_kind = adapters.kind(db.resolved_url(conn))
  local spec, table_name_arg, file_path, mutation_sql = resolve_query(arg, OPTS.limit, adapter_kind)

  -- Handle destructive statements (UPDATE/DELETE/INSERT/DDL)
  if mutation_sql then
    local exec_conn = url or conn or vim.b.db or vim.g.db
    if not exec_conn or exec_conn == "" then
      vim.notify("Grip: no database connection", vim.log.levels.WARN)
      return
    end
    local stmt_type = mutation_sql:upper():match("^%s*(%u+)") or "SQL"

    -- Unwrap BEGIN/COMMIT (or START TRANSACTION) blocks: extract inner DML for mutation preview.
    -- Executing just the inner statement is correct: BEGIN/COMMIT is unnecessary for single stmts.
    if stmt_type == "BEGIN" or stmt_type == "START" then
      local inner = mutation_sql
        :gsub("^%s*START%s+TRANSACTION%s*;%s*\n?", "")
        :gsub("^%s*BEGIN%s*;%s*\n?", "")
        :gsub("\n?%s*COMMIT%s*;?%s*$", "")
        :gsub("\n?%s*ROLLBACK%s*;?%s*$", "")
      inner = inner:match("^%s*(.-)%s*$")
      if inner and inner ~= "" then
        local inner_type = inner:upper():match("^%s*(%u+)")
        if inner_type == "UPDATE" or inner_type == "DELETE" or inner_type == "INSERT"
            or inner_type == "REPLACE" then
          local preview_type = inner_type == "REPLACE" and "INSERT" or inner_type
          M._mutation_preview(inner, exec_conn, preview_type, opts)
          return
        end
      end
      -- No DML inside: fall through to DDL confirm
    end

    -- For UPDATE/DELETE/INSERT/REPLACE: show preview grid with a:execute / U:cancel
    if stmt_type == "UPDATE" or stmt_type == "DELETE" or stmt_type == "INSERT"
        or stmt_type == "REPLACE" then
      -- Treat REPLACE as INSERT for preview purposes
      local preview_type = (stmt_type == "REPLACE") and "INSERT" or stmt_type
      M._mutation_preview(mutation_sql, exec_conn, preview_type, opts)
      return
    end

    -- For DDL (ALTER/DROP/CREATE/etc.): confirm then execute
    local label = ("Execute " .. stmt_type .. "?")
    local choice = vim.fn.confirm(label .. "\n\n" .. mutation_sql:sub(1, 200), "&Execute\n&Cancel", 2)
    if choice ~= 1 then return end

    local t0 = vim.uv.hrtime()
    local _, exec_err = db.execute(mutation_sql, exec_conn)
    local ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
    if exec_err then
      vim.notify("Grip: " .. exec_err, vim.log.levels.ERROR)
    else
      vim.notify(string.format("%s executed (%dms)", stmt_type, ms), vim.log.levels.INFO)
      local history = require("dadbod-grip.history")
      history.record({ sql = mutation_sql, url = exec_conn, type = stmt_type:lower(), elapsed_ms = ms })
      -- Refresh the grids the user can actually see. Iterating _sessions and
      -- breaking on the first hit picked an arbitrary grid (pairs order), which
      -- could leave the visible one stale while refreshing a hidden buffer.
      for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr_r = vim.api.nvim_win_get_buf(wid)
        local session_r = view._sessions[bufnr_r]
        if session_r and session_r.on_refresh then session_r.on_refresh(bufnr_r) end
      end
    end
    return
  end

  if not spec then
    vim.notify("Grip: " .. (table_name_arg or "unknown error"), vim.log.levels.WARN)
    return
  end

  -- File-as-table: use the active DuckDB connection so ATTACHed databases
  -- remain accessible. Fall back to duckdb::memory: when no DuckDB session exists.
  if file_path then
    -- The scheme test needs the resolved URL (a whole-URL template hides it),
    -- but `conn` stays the template: everything downstream of here expands via
    -- db.resolve(), and history/view must not record the expansion.
    local active = vim.g.db
    local resolved = db.resolved_url(active)
    conn = (resolved and resolved:match("^duckdb:")) and active or "duckdb::memory:"
    if opts and opts.write and not filetypes.write_format(file_path) then
      vim.notify("Write mode does not support this file format; opened read-only",
        vim.log.levels.WARN)
      opts = vim.tbl_extend("force", {}, opts, { write = false })
    end
  end

  if not conn or conn == "" then
    vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
    return
  end

  local query_sql = query.build_sql(spec)

  -- Run query with loading indicator + timing
  local short_label = file_path and vim.fn.fnamemodify(file_path, ":t")
      or table_name_arg and (table_name_arg:match("[^.]+$") or table_name_arg)
      or "result"
  short_label = (short_label:match("^([^\n]+)") or "query"):sub(1, 50)
  -- Opening a table is the SELECT (plus the primary keys, for editing) and
  -- nothing else: no COUNT(*) and no column-type lookup, each of which is one
  -- more round-trip -- a whole login, for sqlcmd.
  local fetched
  ui.blocking("  querying " .. short_label .. "...", function()
    fetched = fetch_refresh(conn, query_sql, table_name_arg)
  end)

  local result = fetched.result
  if not result then
    vim.notify("Grip: " .. (fetched.err or "query failed"), vim.log.levels.ERROR)
    return
  end
  local elapsed_ms = fetched.elapsed_ms
  result.elapsed_ms = elapsed_ms

  local history = require("dadbod-grip.history")
  history.record({ sql = query_sql, url = conn, table_name = table_name_arg, type = "query", elapsed_ms = elapsed_ms })

  local state = data.new(result)

  -- Open the view
  -- query_spec goes in up front so the first render already draws the row cap
  -- hint; without it the grid had to be rendered a second time.
  local view_opts = vim.tbl_extend("force", {
    max_col_width = OPTS.max_col_width,
    elapsed_ms    = elapsed_ms,
    query_spec    = spec,
  }, opts or {})
  local bufnr = view.open(state, conn, query_sql, view_opts)

  -- Auto-sync query pad with the current grid query (passive background update).
  -- Use the clean original SQL (base_sql or table name) so the pad shows what the
  -- user wrote, not the internal sort/filter wrapper (SELECT * FROM (...) AS _grip ...).
  -- Skip when the query originated from the pad itself (from_pad=true): the SQL is
  -- already there and we must not clobber the user's buffer.
  vim.schedule(function()
    if opts and opts.from_pad then return end
    require("dadbod-grip.query_pad").sync_query(query.clean_sql(spec, db.kind(conn)))
  end)

  -- Store the query spec on the session
  local session = view._sessions[bufnr]
  if session then
    -- For file-as-table, store the file path so the schema sidebar can show columns
    if file_path then session.file_path = file_path end
    -- Handed to view.open() above and already on the session; the assignment
    -- stays so a caller that reuses an existing buffer still gets it.
    session.query_spec = spec
  end

  -- Wire callbacks
  view.set_callbacks(bufnr, {
    on_refresh = function(bid)
      local s = view._sessions[bid]
      if not s then return end
      -- Read current table name from session state (may have been updated by rename)
      local current_table = (s.state and s.state.table_name) or table_name_arg
      local sql_str = s.query_spec and query.build_sql(s.query_spec) or query_sql
      do_refresh(bid, conn, sql_str, current_table)
    end,
    on_requery = function(bid, new_spec)
      local s = view._sessions[bid]
      if not s then return end

      -- Sort and filter changes rerun the query, and nothing else
      local new_sql, fetched_q
      ui.blocking("  querying " .. spinner_label(table_name_arg) .. "...", function()
        new_sql = query.build_sql(new_spec)
        fetched_q = fetch_refresh(conn, new_sql, table_name_arg)
      end)

      s.query_spec = new_spec
      s.query_sql = new_sql
      apply_refresh(bid, fetched_q)
    end,
    on_apply = function(bid)
      do_apply(bid, conn)
    end,
    on_edit = function(bid, cell)
      do_edit(bid, cell, conn)
    end,
    on_delete = function(bid, row_idx)
      local session_d = view._sessions[bid]
      if not session_d then return end
      if session_d.state.inserted[row_idx] then
        -- Unsaved inserted row: remove it entirely
        local new_state = data.undo_row(session_d.state, row_idx)
        view.apply_edit(bid, new_state)
        vim.notify("Removed unsaved row", vim.log.levels.INFO)
      else
        -- Existing DB row: toggle delete mark
        local was_deleted = session_d.state.deleted[row_idx]
        local new_state = data.toggle_delete(session_d.state, row_idx)
        vim.notify(was_deleted and "Unmarked" or "Marked for deletion", vim.log.levels.INFO)
        view.apply_edit(bid, new_state)
      end
    end,
    on_insert = function(bid, after_idx)
      local session_i = view._sessions[bid]
      if not session_i then return end
      local new_state = data.insert_row(session_i.state, after_idx)
      view.apply_edit(bid, new_state)
      vim.notify("Inserted blank row", vim.log.levels.INFO)
      -- Move cursor to first cell of the new row
      local r = session_i._render
      if r then
        local ordered = r.ordered
        for i, idx in ipairs(ordered) do
          if new_state.inserted[idx] and idx == new_state._next_insert_idx - 1 then
            local line_nr = i + (r.data_start or 4) - 1
            local bp_row = r.byte_positions and r.byte_positions[i]
            local col_byte = bp_row and bp_row[new_state.columns[1]] and bp_row[new_state.columns[1]].start or #("║ ")
            pcall(vim.api.nvim_win_set_cursor, 0, { line_nr, col_byte })
            break
          end
        end
      end
    end,
    on_clone = function(bid, row_idx)
      local session_c = view._sessions[bid]
      if not session_c then return end
      local new_state = data.clone_row(session_c.state, row_idx)
      view.apply_edit(bid, new_state)
      vim.notify("Cloned row (edit PKs then gw to commit)", vim.log.levels.INFO)
      -- Move cursor to first cell of the cloned row
      local r = session_c._render
      if r then
        for i, idx in ipairs(r.ordered) do
          if new_state.inserted[idx] and idx == new_state._next_insert_idx - 1 then
            local line_nr = i + (r.data_start or 4) - 1
            local bp_row = r.byte_positions and r.byte_positions[i]
            local first_col = new_state.columns[1]
            local col_byte = bp_row and bp_row[first_col] and bp_row[first_col].start or #("║ ")
            pcall(vim.api.nvim_win_set_cursor, 0, { line_nr, col_byte })
            break
          end
        end
      end
    end,
  })

  -- Switch to a specific view if requested via opts.view (view name string)
  if opts and type(opts.view) == "string" then
    local view_name = opts.view
    vim.schedule(function()
      view.switch_view(bufnr, view_name)
    end)
  end
end

-- ── open_smart ───────────────────────────────────────────────────────────
-- DBUI-aware smart open: detects context from current buffer and opens
-- the appropriate table in the grid. Works from SQL query buffers,
-- dbout result buffers, and normal buffers (word under cursor).
---Open the table under cursor, adapting to the current buffer context.
function M.open_smart()
  local bufnr = vim.api.nvim_get_current_buf()

  -- Case 1: DBUI SQL query buffer: has b:dbui_table_name + b:db (string URL)
  local dbui_table = vim.b[bufnr].dbui_table_name
  if dbui_table and dbui_table ~= "" then
    local url = vim.b[bufnr].db
    if type(url) ~= "string" or url == "" then url = vim.g.db end
    if not url or url == "" then
      vim.notify("Grip: no database connection", vim.log.levels.WARN)
      return
    end
    -- Find the dbout window to reuse (keeps two-pane layout)
    local reuse_win
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local wb = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_name(wb):match("%.dbout$") then
        reuse_win = win
        break
      end
    end
    local opts = reuse_win and { reuse_win = reuse_win } or nil
    M.open(dbui_table, url, opts)
    return
  end

  -- Case 2: dbout result buffer: b:db is a dict with db_url
  local db_obj = vim.b[bufnr].db
  if type(db_obj) == "table" and db_obj.db_url then
    local url = db_obj.db_url
    if not url or url == "" then url = vim.w.db end
    if not url or url == "" then url = vim.g.db end
    if not url or url == "" then
      vim.notify("Grip: no database connection", vim.log.levels.WARN)
      return
    end
    local table_name
    local db_input = vim.b[bufnr].db_input
    if db_input then
      local input_resolved = vim.fn.resolve(db_input)
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          local bname = vim.fn.resolve(vim.api.nvim_buf_get_name(b))
          if bname == input_resolved then
            table_name = vim.b[b].dbui_table_name
            break
          end
        end
      end
      if (not table_name or table_name == "")
        and vim.fn.filereadable(db_input) == 1 then
        local sql_text = table.concat(vim.fn.readfile(db_input), " ")
        table_name = sql_text:match("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)")
      end
    end
    -- Fallback: search visible windows for a buffer with dbui_table_name
    if not table_name or table_name == "" then
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local wb = vim.api.nvim_win_get_buf(win)
        local tname = vim.b[wb].dbui_table_name
        if tname and tname ~= "" then
          table_name = tname
          break
        end
      end
    end
    if not table_name or table_name == "" then
      vim.notify("Grip: only works for table results, not raw queries", vim.log.levels.WARN)
      return
    end
    local winid = vim.api.nvim_get_current_win()
    M.open(table_name, url, { reuse_win = winid })
    return
  end

  -- Case 3: No DBUI/dbout context: show table picker
  local conn = vim.b.db
  if type(conn) == "table" then conn = conn.db_url end
  if not conn or conn == "" then conn = vim.g.db end
  if not conn or conn == "" then
    vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
    return
  end
  require("dadbod-grip.picker").pick_table(conn, function(table_name)
    M.open(table_name, conn)
  end)
end

--- Open the welcome screen. Loaded on first use.
function M.open_welcome()
  return require("dadbod-grip.welcome").open_welcome()
end

-- ── setup ─────────────────────────────────────────────────────────────────

---@class DadbodGripOpts
---@field limit? integer         Row cap when Grip opens a table or file (TOP N; default 1000, 0 = none)
---@field max_col_width? integer Max display width per column (default: 40)
---@field timeout? integer       Query timeout in ms (default: 10000)
---@field keymaps? table         Key overrides: { action_name = "key" } or { action_name = false }
---@field pinned_max? integer    Max number of pinned results allowed (nil = unlimited)
---@field border? string|table   Float window border style (default: "rounded")
---@field cell_split? string     Cell buffer (gB) split style: "horizontal"|"vertical"
---@field open_sidebar? boolean  Open the schema sidebar on connection (default: true)
---@field databases? table       Connections as { servers = { KEY = host }, definitions = { ... } }

---Setup dadbod-grip with user options.
---@param opts? DadbodGripOpts
function M.setup(opts)
  opts = opts or {}
  config.apply(opts)

  require("dadbod-grip.commands").register()
end

-- Exposed for testing
M._is_queryable_file = is_queryable_file
M._resolve_query = resolve_query

--- Preview and stage CSV, TSV, or JSON rows in the current editable grid.
--- An empty source reads the + register; !command captures stdout while the
--- producer script is delivered to a constant parent shell argv over stdin.
function M.do_import(source)
  local bufnr = vim.api.nvim_get_current_buf()
  local session = view._sessions[bufnr]
  if not session then
    vim.notify("GripImport: no grip session on this buffer", vim.log.levels.WARN)
    return
  end
  if not session.state.table_name or session.state.readonly then
    vim.notify("GripImport: requires an editable table grid", vim.log.levels.WARN)
    return
  end
  if deny_if_readonly("GripImport", session.url) then return end
  if db.is_readonly(session.url) then
    vim.notify("GripImport: this adapter is read-only", vim.log.levels.WARN)
    return
  end

  source = vim.trim(source or "")
  local raw, source_name
  if source == "" then
    raw = vim.fn.getreg("+")
    source_name = "clipboard"
  elseif source:sub(1, 1) == "!" then
    local command = vim.trim(source:sub(2))
    if command == "" then
      vim.notify("GripImport: provide a command after !", vim.log.levels.WARN)
      return
    end
    local stdout, _, code = require("dadbod-grip.adapters").run_cmd(
      { "sh", "-s" }, OPTS.timeout, { stdin = command .. "\n" })
    if code ~= 0 then
      vim.notify("GripImport: pipe command failed (exit " .. tostring(code) .. ")", vim.log.levels.ERROR)
      return
    end
    raw = stdout
    source_name = "pipe"
  else
    vim.notify("GripImport: use no argument for the clipboard or !command for a pipe",
      vim.log.levels.WARN)
    return
  end

  local parsed, err = importer.parse(raw, session.state.columns)
  if not parsed then
    vim.notify("GripImport: " .. err, vim.log.levels.ERROR)
    return
  end

  local prompt = string.format("Import %d %s rows into %s?\nColumns: %s (y/N): ",
    #parsed.rows, parsed.format, session.state.table_name, table.concat(parsed.columns, ", "))
  if not ui.confirm(prompt) then return end

  local state = data.insert_rows_with_values(session.state, #session.state.rows, parsed.rows)
  view.apply_edit(bufnr, state)
  vim.notify(string.format("GripImport: staged %d rows from %s; press a to apply",
    #parsed.rows, source_name), vim.log.levels.INFO)
end

return M
