-- connections/picker.lua: the connection picker (:GripConnect, gc) — rows,
-- folders, and the per-row actions (add, delete, retest, ro/rw, global, ...).

local paths   = require("dadbod-grip.paths")
local ui      = require("dadbod-grip.ui")
local secrets = require("dadbod-grip.secrets")
local filetypes = require("dadbod-grip.filetypes")
local store   = require("dadbod-grip.connections.store")
local local_files = require("dadbod-grip.connections.local_files")

local configured_connections_path = store.configured_connections_path
local connections_path = store.connections_path
local global_connections_path = store.global_connections_path
local ensure_global_grip_dir = store.ensure_global_grip_dir
local new_connection_id = store.new_connection_id
local read_json_connections = store.read_json_connections
local is_file_url = local_files.is_file_url
local is_testable_locally = local_files.is_testable_locally
local extract_local_path = local_files.extract_local_path
local fmt_size = local_files.fmt_size
local scan_local_files = local_files.scan_local_files
local short_url = local_files.short_url

local conn = setmetatable({}, { __index = function(_, k) return require("dadbod-grip.connections")[k] end })

local M = {}

--- One-character health marker for a picker row.
local function health_char(url)
  local s = conn.get_health(url)
  if s == "ok"         then return "*" end
  if s == "fail"       then return "x" end
  if s == "unresolved" then return "?" end
  return " "
end

--- Prompt user to enter a new connection URL + name, then switch to it.
--- True when the picker's `r` (ro/rw) action applies to this row.
---
--- Shared by the action's `when` and its `fn`: grip_picker fires `fn`
--- regardless of `when`, so both need the same answer, and a second
--- hand-written copy of these conditions is how the two drift apart.
--- @param c table picker item
--- @return boolean
local function ro_toggle_applies(c)
  if c._new or c._temp or c._section_header or c._local_file then return false end
  -- A file connection has no server session to put in read-only mode;
  -- !:write is the flag that matters there.
  if c.type == "file" or (not c.type and is_file_url(c.url)) then return false end
  -- SQL Server is read-only at the adapter (adapters/sqlserver.lua:9), so
  -- offering to toggle its mode would promise a write path that does not
  -- exist. Resolved first: a whole-URL template hides the scheme, and an
  -- unresolvable one falls back to the template, which simply does not match.
  local target = conn.expand_url(c.url) or c.url
  return not target:find("^sqlserver:")
end

local function prompt_new_connection()
  local url = ui.input({ prompt = "Connection URL, file path, or s3://: " })
  if not url then
    require("dadbod-grip").open_welcome(); return
  end

  local name = ui.input({ prompt = "Connection name: " })
  if not name then
    require("dadbod-grip").open_welcome(); return
  end

  conn.add(name, url)
  conn.switch(url, name)
end

--- Connect once without saving to connections.json.
--- Passes nil name so conn.switch() skips the auto-persist path.
local function prompt_temp_connection()
  local url = ui.input({ prompt = "Connect once (URL, not saved): " })
  if not url then
    require("dadbod-grip").open_welcome(); return
  end
  -- nil name → conn.switch() won't auto-persist (see "if not already_saved and name" guard)
  conn.switch(url, nil, nil, nil)
end

--- Open a picker to select and switch connection. Uses grip_picker (zero external deps).
--- Connections with a `group` are listed inside a folder of that name: the top
--- level shows one row per folder, and selecting it reopens the picker on
--- that group alone.
--- @param opts? { on_cancel?: function, group?: string }  group = folder to open
function M.pick(opts)
  opts = opts or {}
  local on_cancel = opts.on_cancel or function() require("dadbod-grip").open_welcome() end
  local conns = conn.list()
  if #conns == 0 then
    prompt_new_connection()
    return
  end

  -- Sort file-backed connections (file + global) by most recently used first,
  -- with non-file-backed sources (e.g. vim.g.db env var) sorted last.
  local function is_file_backed(c)
    return c.source == "file" or c.source == "global"
  end
  table.sort(conns, function(a, b)
    local af, bf = is_file_backed(a), is_file_backed(b)
    if af ~= bf then return af end
    if af and bf then
      return (a.last_used or 0) > (b.last_used or 0)
    end
    return false
  end)

  -- Scan cwd for local data files (CSV, Parquet, JSON, etc.)
  local local_files = scan_local_files()

  local max_name = 0
  for _, c in ipairs(conns) do
    max_name = math.max(max_name, vim.fn.strdisplaywidth(c.name))
  end
  for _, f in ipairs(local_files) do
    max_name = math.max(max_name, vim.fn.strdisplaywidth(f.name))
  end

  -- Sentinel items at bottom of list
  local new_sentinel  = { name = "+ New connection...",          url = "", _new  = true }
  local temp_sentinel = { name = "~ Connect once (no save)...", url = "", _temp = true }

  -- Does any listed entry default to read-only? Set by build_picker_items and
  -- read by display: the RO column only exists when something is in it, so a
  -- picker with no ro entry renders byte-identically to how it always has.
  local any_ro = false

  -- Build the full item list with scope sections.
  -- When at least one global connection exists and connections_path is not set,
  -- connections are grouped under "global" and "project" section headers so the
  -- user can immediately see which connections are shared across projects.
  -- Called at open time and from on_delete to refresh after a deletion.
  local function build_picker_items()
    local fresh = conn.list()

    -- Inside a folder: a way back up, then that group's connections, MRU first.
    if opts.group then
      local members = {}
      for _, c in ipairs(fresh) do
        if c.group == opts.group and not (c._builtin_id) then
          table.insert(members, c)
        end
      end
      table.sort(members, function(a, b) return (a.last_used or 0) > (b.last_used or 0) end)
      local out = { { name = "..", url = "", _up = true, _section_header = true } }
      vim.list_extend(out, members)
      any_ro = false
      for _, c in ipairs(members) do
        if c.mode == "ro" then any_ro = true; break end
      end
      return out
    end

    -- Top level: grouped connections collapse into one folder row per group.
    -- Folder rows carry _section_header so every action and on_delete skips them.
    local folders, folder_order, ungrouped = {}, {}, {}
    for _, c in ipairs(fresh) do
      if c.group and not (c._builtin_id) then
        if not folders[c.group] then
          folders[c.group] = { name = c.group, url = "", _folder = c.group,
                               _count = 0, _section_header = true }
          table.insert(folder_order, c.group)
        end
        folders[c.group]._count = folders[c.group]._count + 1
      else
        table.insert(ungrouped, c)
      end
    end
    table.sort(folder_order)
    fresh = ungrouped
    local use_sections = not configured_connections_path()

    local global_conns, project_conns, other_conns = {}, {}, {}
    for _, c in ipairs(fresh) do
      if c._builtin_id then
        table.insert(other_conns, c)
      elseif c.source == "global" then
        table.insert(global_conns, c)
      elseif c.source == "file" then
        table.insert(project_conns, c)
      else
        table.insert(other_conns, c)
      end
    end

    local function sort_mru(t)
      table.sort(t, function(a, b) return (a.last_used or 0) > (b.last_used or 0) end)
    end
    sort_mru(global_conns)
    sort_mru(project_conns)

    local out = {}
    for _, g in ipairs(folder_order) do table.insert(out, folders[g]) end
    local show_headers = use_sections and #global_conns > 0

    if show_headers then
      table.insert(out, { name = "global", url = "", _section_header = true })
      for _, c in ipairs(global_conns) do table.insert(out, c) end
      table.insert(out, { name = "project", url = "", _section_header = true })
      for _, c in ipairs(project_conns) do table.insert(out, c) end
    else
      -- Flat list: file-backed MRU first, then others
      local flat = {}
      for _, c in ipairs(global_conns)  do table.insert(flat, c) end
      for _, c in ipairs(project_conns) do table.insert(flat, c) end
      sort_mru(flat)
      for _, c in ipairs(flat) do table.insert(out, c) end
    end

    for _, c in ipairs(other_conns) do table.insert(out, c) end

    local fresh_files = scan_local_files()
    if #fresh_files > 0 then
      table.insert(out, { name = "Local Files (cwd)", url = "", _section_header = true })
      for _, f in ipairs(fresh_files) do table.insert(out, f) end
    end
    table.insert(out, new_sentinel)
    table.insert(out, temp_sentinel)
    any_ro = false
    for _, c in ipairs(out) do
      if c.mode == "ro" then any_ro = true; break end
    end
    return out
  end

  local picker_items = build_picker_items()

  -- Track which connection URLs have password reveal active
  local show_pass = {}

  require("dadbod-grip.grip_picker").open({
    title = opts.group and ("Connections / " .. opts.group) or "Connections",
    items = picker_items,
    on_cancel = on_cancel,
    display = function(c)
      if c._folder then
        local pad = string.rep(" ", math.max(0, max_name - vim.fn.strdisplaywidth(c.name)))
        return "▸ " .. c.name .. pad .. "  (" .. c._count .. ")"
      end
      if c._section_header then
        return "  " .. c.name
      end
      if c._new or c._temp then
        return "  " .. c.name
      end
      if c._local_file then
        local pad = string.rep(" ", max_name - vim.fn.strdisplaywidth(c.name))
        return "  " .. c.name .. pad .. "  " .. fmt_size(c.size_bytes)
      end
      local dot = health_char(c.url)
      local pad = string.rep(" ", max_name - vim.fn.strdisplaywidth(c.name))
      local url_display = show_pass[c.url] and c.url or short_url(c.url)
      -- The entry's stored default, not what r:ro/rw may have overridden for
      -- this session: this row answers "how does this connection open", and
      -- the winbar answers "how is it open right now".
      --
      -- Its own column, ahead of the URL, because it is a property of the
      -- entry like the health dot -- and because grip_picker truncates a row
      -- that overruns the float, which ate the marker outright when it
      -- trailed the URL: long production names and long hosts are exactly the
      -- rows most likely to be read-only, and M:mask lengthens them further.
      local ro = any_ro and (c.mode == "ro" and "RO " or "   ") or ""
      return dot .. " " .. c.name .. pad .. "  " .. ro .. url_display
    end,
    on_select = function(c)
      if c._folder then
        conn.pick({ group = c._folder, on_cancel = opts.on_cancel })
        return
      end
      if c._up then
        conn.pick({ on_cancel = opts.on_cancel })
        return
      end
      if c._section_header then return end
      if c._new then
        prompt_new_connection()
      elseif c._temp then
        prompt_temp_connection()
      elseif c._local_file then
        conn.switch(c.url, nil, "file")
      else
        conn.switch(c.url, c.name, c.type)
      end
    end,
    on_delete = function(c, refresh_fn)
      if c._new or c._temp or c._section_header or c._local_file then return end
      -- Starter built-in: write a hidden flag so it never appears again
      if c._builtin_id then
        if ui.confirm("Remove '" .. c.name .. "'? (y/N): ") then
          vim.fn.mkdir(vim.fn.stdpath("data") .. "/grip", "p")
          vim.fn.writefile({}, vim.fn.stdpath("data") .. "/grip/" .. c._builtin_id .. ".hidden")
          refresh_fn(build_picker_items())
        end
        return
      end
      if ui.confirm("Remove '" .. c.name .. "'? (y/N): ") then
        conn.remove(c.name, c.url)
        refresh_fn(build_picker_items())
      end
    end,
    actions = {
      {
        key            = "!",
        label          = "!:write",
        close_on_select = true,
        when           = function(c)
          return not c._new and not c._temp and not c._section_header
              and (c._local_file or c.type == "file" or (not c.type and is_file_url(c.url)))
              and filetypes.write_format(c.url) ~= nil
        end,
        fn             = function(c)
          if c._new or c._temp or c._section_header then return end
          conn.switch(c.url, c._local_file and nil or c.name, c.type or "file", { write = true })
        end,
      },
      {
        key            = "W",
        label          = "W:watch",
        close_on_select = true,
        when           = function(c)
          return not c._new and not c._temp and not c._section_header and not c._local_file
        end,
        fn             = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          conn.switch(c.url, c.name, c.type, { watch_ms = 5000 })
        end,
      },
      {
        key   = "M",
        label = "M:mask",
        when  = function(c)
          return not c._new and not c._temp and not c._section_header and not c._local_file
        end,
        fn    = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          if show_pass[c.url] then
            show_pass[c.url] = nil
          else
            show_pass[c.url] = true
          end
        end,
      },
      {
        key            = "a",
        label          = "a:attach",
        close_on_select = true,
        when           = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return false end
          -- Show on non-DuckDB connections when current connection is DuckDB.
          -- Both URLs are resolved first: a whole-URL template hides the
          -- scheme, and without this the action is hidden on a templated
          -- DuckDB connection even though its fn below handles one.
          local cur = vim.g.db
          cur = cur and (conn.expand_url(cur) or cur)
          local target = conn.expand_url(c.url) or c.url
          if not (cur and cur:find("^duckdb:")) or target:find("^duckdb:") then return false end
          -- Hide it outright for databases DuckDB has no scanner for (SQL
          -- Server, Oracle, ...) rather than offering an action that can only
          -- fail. conn.attach refuses those too, for the :GripAttach path.
          local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
          return duckdb_adapter._unsupported_attach_scheme(duckdb_adapter.url_to_dsn(target)) == nil
        end,
        fn             = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          -- Guard: grip_picker fires fn regardless of `when` predicate label
          -- url is the active connection as stored (templated: the key on
          -- disk); conn_url is what the adapter registry is keyed by. One of
          -- the four paths that bypass db.resolve(), so both the DuckDB URL
          -- and the target's URL are expanded by hand here.
          local url = vim.g.db
          local conn_url = conn.expand_url(url)
          if not conn_url or not conn_url:find("^duckdb:") then
            vim.notify(
              "Attach requires an active DuckDB connection. Switch to DuckDB with gc first.",
              vim.log.levels.WARN)
            return
          end
          local target_url, target_err = conn.expand_url(c.url)
          if not target_url then
            vim.notify("Attach failed: " .. (target_err or "unresolved connection secrets"),
              vim.log.levels.ERROR)
            return
          end
          local default_alias = c.name:lower():gsub("[^%w_]", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
          local alias = ui.input({ prompt = "Attach as alias: ", default = default_alias })
          if not alias then return end
          local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
          local schema_mod = require("dadbod-grip.schema")
          local dsn = duckdb_adapter.url_to_dsn(target_url)
          -- Persist the connection's own URL template, not the DSN derived
          -- from it: conn.expand_dsn() finds this entry's env_file by that URL,
          -- and load_attachments() runs url_to_dsn() again on replay.
          local template = target_url ~= c.url and c.url or nil
          local err = duckdb_adapter.attach(conn_url, dsn, alias, template)
          if err then
            vim.notify("Attach failed: " .. err, vim.log.levels.ERROR)
            return
          end
          conn.save_attachments(url, duckdb_adapter.get_attachments(conn_url))
          schema_mod.refresh(url)
          vim.notify(string.format("Attached '%s' as %s", c.name, alias), vim.log.levels.INFO)
        end,
      },
      {
        -- T: retest connection health. File-backed connections use filereadable()
        -- for instant feedback; network DBs run SELECT 1 via db.ping() with a 5s timeout.
        key   = "T",
        label = "T:test",
        when  = function(c) return not (c._new or c._temp or c._section_header) end,
        fn    = function(c)
          if c._new or c._temp or c._section_header then return end
          -- A templated entry must report *why* it can't be tested, not a
          -- meaningless "Unsupported database scheme: ${VAR}" from handing
          -- the literal placeholder to the adapter.
          local conn_url, secret_err = conn.expand_url(c.url)
          if not conn_url then
            conn.set_health(c.url, "unresolved")
            vim.notify("Grip: " .. (secret_err or "could not resolve connection secrets"),
              vim.log.levels.ERROR)
            return
          end
          -- Scheme detection (is_testable_locally) needs the resolved URL for
          -- a whole-URL template, same reasoning as a:attach above.
          local test_target = conn_url == c.url and c
            or vim.tbl_extend("force", {}, c, { url = conn_url })
          if is_testable_locally(test_target) then
            local path = extract_local_path(conn_url)
            conn.set_health(c.url, vim.fn.filereadable(path) == 1 and "ok" or "fail")
          else
            -- db.ping is given the URL *as stored*, not the expansion above:
            -- it resolves internally, and everything else it consults keys on
            -- the template. Handing it the expanded URL made
            -- current_mode(expanded) find no entry and report "rw", so a
            -- connection saved "mode": "ro" got pinged with a writable
            -- session -- the one place in this feature that looked a
            -- connection up by anything but the template.
            local ok = require("dadbod-grip.db").ping(c.url)
            conn.set_health(c.url, ok and "ok" or "fail")
          end
        end,
      },
      {
        -- G: promote a project-local connection to the global file (~/.grip/connections.json)
        -- so it appears in every project's picker without re-adding it each time.
        key   = "G",
        label = "G:global",
        when  = function(c)
          -- No global concept when connections_path override is active (single-file mode)
          if configured_connections_path() then return false end
          return not (c._new or c._temp or c._section_header or c._local_file
                      or c._builtin_id)
              and c.source == "file"
        end,
        fn    = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          ensure_global_grip_dir()
          local global_path  = global_connections_path()
          local global_conns = read_json_connections(global_path, "global")
          for _, gc in ipairs(global_conns) do
            if gc.url == c.url then
              vim.notify("'" .. c.name .. "' is already in global connections", vim.log.levels.INFO)
              return
            end
          end
          local promoted = { id = c.id or new_connection_id(c.url),
                              name = c.name, url = c.url, type = c.type,
                              env_file = c.env_file, mode = c.mode, color = c.color, group = c.group,
                              attachments = c.attachments, last_used = c.last_used }
          table.insert(global_conns, promoted)
          local gdata = {}
          for _, gc in ipairs(global_conns) do
            local entry = { name = gc.name, url = gc.url }
            if gc.id then entry.id = gc.id end
            if gc.type then entry.type = gc.type end
            if gc.attachments and #gc.attachments > 0 then entry.attachments = gc.attachments end
            if gc.last_used then entry.last_used = gc.last_used end
            if gc.env_file then entry.env_file = gc.env_file end
            if gc.mode then entry.mode = gc.mode end
            if gc.color then entry.color = gc.color end
            if gc.group then entry.group = gc.group end
            table.insert(gdata, entry)
          end
          vim.fn.writefile({ vim.fn.json_encode(gdata) }, global_path)
          vim.notify("'" .. c.name .. "' saved to ~/.grip/connections.json", vim.log.levels.INFO)
        end,
      },
      {
        -- r: connect in the mode opposite to the entry's default -- a ro entry
        -- opened writable for one fix, a rw entry opened read-only before
        -- poking at production. Session-only: nothing is written to
        -- connections.json, and selecting the connection normally afterwards
        -- puts it back on its own mode (see _mode_override).
        key            = "r",
        label          = "r:ro/rw",
        close_on_select = true,
        when           = function(c)
          return ro_toggle_applies(c)
        end,
        fn             = function(c)
          -- grip_picker fires fn regardless of the `when` predicate (see the
          -- same guard on a:attach), so this is the check that actually
          -- prevents an override being set on an entry the action was hidden
          -- for -- not a restatement of the line above.
          if not ro_toggle_applies(c) then return end
          local mode = c.mode == "ro" and "rw" or "ro"
          -- Only claim the override on a switch that committed: one that
          -- aborted (unresolvable ${VAR}) leaves the connection exactly as it
          -- was, and has already said why.
          if conn.switch(c.url, c.name, c.type, { mode = mode }) then
            vim.notify("Grip: connected " .. (mode == "ro" and "read-only" or "writable")
              .. " for this session (mode = " .. mode .. ")", vim.log.levels.INFO)
          end
        end,
      },
      {
        -- s: save a local file as a named connection in .grip/connections.json.
        key            = "s",
        label          = "s:save",
        close_on_select = true,
        when           = function(c) return c._local_file == true end,
        fn             = function(c)
          if not c._local_file then return end
          local default_name = vim.fn.fnamemodify(c.url, ":t:r")
          local name = ui.input({ prompt = "Save as: ", default = default_name })
          if not name then return end
          conn.switch(c.url, name, "file")
        end,
      },
    },
  })
end

--- Expose the .grip/ directory path for other modules (schema catalog, etc.).

return M
