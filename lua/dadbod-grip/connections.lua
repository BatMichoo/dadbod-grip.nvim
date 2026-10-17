-- connections.lua: connection profile management.
-- Reads from .grip/connections.json, g:dbs (DBUI compat), $DATABASE_URL.
-- All functions return (result, err). Never throw.

local paths = require("dadbod-grip.paths")
local ui = require("dadbod-grip.ui")
local secrets = require("dadbod-grip.secrets")

local store = require("dadbod-grip.connections.store")
local grip_dir = paths.grip_dir
local configured_connections_path = store.configured_connections_path
local global_connections_path = store.global_connections_path
local ensure_grip_dir = store.ensure_grip_dir
local ensure_global_grip_dir = store.ensure_global_grip_dir
local new_connection_id = store.new_connection_id
local read_json_connections = store.read_json_connections
local read_local_connections = store.read_local_connections
local read_file_connections = store.read_file_connections
local write_file_connections = store.write_file_connections
local strip_flags = store.strip_flags
local upsert_conn = store.upsert_conn
local touch_conn = store.touch_conn

local local_files = require("dadbod-grip.connections.local_files")
local is_file_url = local_files.is_file_url

local M = {}

-- Session-scoped connection health state (never persisted).
-- Values: "ok" | "fail" | "unresolved" | "unknown" (default when absent).
-- "unresolved" is distinct from "fail": the connection was never attempted --
-- its ${VAR} placeholder(s) couldn't be expanded (missing .env, still
-- git-crypt-locked, renamed variable), so a scheme/network failure would be
-- a meaningless report.
local _health = {}

-- Session-scoped read/write mode overrides, keyed by connection URL as stored
-- (the template -- the same key entries live under on disk). Set only by
-- M.switch(url, ..., { mode = ... }), which the picker's r:ro/rw action uses
-- to connect once in the mode opposite to the entry's default.
--
-- Deliberately never written to connections.json: the entry's own `mode` is
-- the user's standing decision about that database, and a keypress in a
-- picker is not a request to rewrite their file. Every ordinary switch of a
-- connection clears its override again, so the override lasts exactly from
-- one connect to the next.
local _mode_override = {}

-- ── secret expansion ──────────────────────────────────────────────────────

--- Find the saved entry for a connection URL, or nil when the URL is not a
--- saved connection (an ad-hoc :GripConnect URL, a g:dbs entry, ...).
---
--- Exists so db.lua can reach an entry's env_file without knowing where
--- connections are stored. Deliberately reads the JSON files directly rather
--- than going through M.list(): list() also runs Docker discovery, and this
--- sits on the query path -- db.resolve() calls it for every templated URL.
--- @param url string|nil
--- @return table|nil entry
function M.entry_for(url)
  if type(url) ~= "string" or url == "" then return nil end
  for _, c in ipairs(read_file_connections()) do
    if c.url == url then return c end
  end
  return nil
end

--- The read/write mode of a connection: "ro" or "rw", never nil.
---
--- "ro" only when the saved entry explicitly says `"mode": "ro"`. No entry
--- (an ad-hoc URL, a g:dbs entry), no `mode` field, or any other value all
--- mean "rw", so every connections.json written before this option existed
--- keeps behaving exactly as it did.
---
--- Called with no argument -- the adapters and the mode badge do -- it asks
--- about the connection currently in vim.b.db / vim.g.db, via the same
--- precedence db.get_url() uses. That is deliberately the *template* URL:
--- entries are keyed by the template on disk, so looking up an expanded
--- "${VAR}" URL would find nothing and silently downgrade a ro connection to
--- rw. Callers that already hold a stored URL (db.is_readonly) pass it in.
--- A session override set by the picker's r:ro/rw action wins over the stored
--- field, for that connection only and only until it is switched to again.
--- @param url string|nil  a stored (templated) URL; defaults to the current connection
--- @return string  "ro" or "rw"
function M.current_mode(url)
  -- Lazy require: db.lua reaches back into this module for expand_url.
  local conn = require("dadbod-grip.db").get_url(url)
  local override = conn and _mode_override[conn]
  if override then return override end
  local entry = M.entry_for(conn)
  return (entry and entry.mode == "ro") and "ro" or "rw"
end

--- Refuse a schema-modifying action on a connection saved with "mode": "ro".
--- Returns true when the caller must stop.
---
--- This is the layer that refuses *before* the prompt: every DDL path in the
--- plugin opens an interactive form or a typed confirmation first, and walking
--- a user through one only to have it fail at the end is a worse answer than
--- declining up front.
---
--- It is a guard, not a boundary, and the difference matters. The adapters do
--- put the CLI session itself in read-only mode, which usually means the
--- server would refuse the statement even if this returned false -- but not
--- always: a postgres URL that already carries its own `options=` overrides
--- PGOPTIONS (see psql_env), and sqlite/duckdb pointed at a not-yet-existing
--- file get no `-readonly` at all, by design. Treat this as the thing that
--- keeps a read-only connection honest in ordinary use, not as something a
--- caller may rely on to make a write impossible.
---
--- Lives here rather than in init.lua because the DDL entry points are spread
--- across the command layer, the schema sidebar, the properties float and the
--- grid's inspect keymaps; one wording for all of them is the point.
---
--- The message names the mode and never the URL -- it can carry a password.
--- @param label string  the command or action name to prefix the message with
--- @param url string|nil  defaults to the current connection
--- @return boolean
function M.deny_if_readonly(label, url)
  if M.current_mode(url) ~= "ro" then return false end
  vim.notify(label .. ": Connection is read-only (mode = ro)", vim.log.levels.WARN)
  return true
end

--- Resolve the ${VAR} placeholders in a connection URL against the env_file
--- of its saved entry (falling back to the process environment).
---
--- The expanded URL carries the live password, so it exists in exactly two
--- kinds of place: the argv/env of the database CLI, and the local variable
--- that got it there. vim.g.db, vim.b.db, connections.json and the query
--- history all keep the *template* -- db.resolve() calls this at the single
--- point where a URL is handed to an adapter, which is why no write path in
--- the plugin can spill a secret. Do not push the expansion outward.
---
--- A URL with no placeholder is returned unchanged without touching the
--- filesystem, so ordinary literal connections cost exactly what they did
--- before.
--- @param url string|nil
--- @return string|nil expanded  nil only when expansion failed
--- @return string|nil err
function M.expand_url(url)
  if type(url) ~= "string" or not secrets.has_template(url) then return url end
  return secrets.expand(url, M.entry_for(url))
end

--- Resolve the ${VAR} placeholders in a persisted DuckDB attachment DSN.
---
--- Attachment DSNs are stored templated (see M.save_attachments), so the
--- password of an attached postgres/mysql database never lands in
--- connections.json either. Variables resolve against the attached
--- connection's own entry when the stored string is itself a saved
--- connection URL -- how the `a:attach` picker action stores it -- and
--- otherwise against the entry of the DuckDB connection the attachment hangs
--- off, which is what a DSN typed straight into :GripAttach gets.
--- @param dsn string|nil
--- @param host_url string|nil the DuckDB connection URL, as stored (templated)
--- @return string|nil expanded
--- @return string|nil err
function M.expand_dsn(dsn, host_url)
  if type(dsn) ~= "string" or not secrets.has_template(dsn) then return dsn end
  return secrets.expand(dsn, M.entry_for(dsn) or M.entry_for(host_url))
end

--- Resolve a persisted connection by opaque ID.
--- @return table|nil connection
--- @return string|nil reason "missing" or "ambiguous"
function M.find_by_id(id)
  if type(id) ~= "string" or id == "" then return nil, "missing" end
  local found
  for _, c in ipairs(read_file_connections()) do
    if c.id == id then
      if found and found.url ~= c.url then return nil, "ambiguous" end
      found = found or c
    end
  end
  if not found then return nil, "missing" end
  return found
end

--- Return the stable ID for a persisted URL, assigning one lazily when an old
--- connections.json entry predates IDs. Unsaved/discovered URLs return nil.
function M.ensure_id(url)
  if type(url) ~= "string" or url == "" then return nil end

  local local_conns = read_local_connections()
  local global_conns = configured_connections_path()
      and {} or read_json_connections(global_connections_path(), "global")
  local id
  for _, list in ipairs({ local_conns, global_conns }) do
    for _, c in ipairs(list) do
      if c.url == url and c.id then
        id = c.id
        break
      end
    end
    if id then break end
  end

  local persisted = false
  for _, list in ipairs({ local_conns, global_conns }) do
    for _, c in ipairs(list) do
      if c.url == url then persisted = true end
    end
  end
  if not persisted then return nil end
  id = id or new_connection_id(url)

  local local_changed, global_changed = false, false
  for _, c in ipairs(local_conns) do
    if c.url == url and not c.id then c.id, local_changed = id, true end
  end
  for _, c in ipairs(global_conns) do
    if c.url == url and not c.id then c.id, global_changed = id, true end
  end
  if local_changed then write_file_connections(local_conns) end
  if global_changed then
    ensure_global_grip_dir()
    local data = {}
    for _, c in ipairs(global_conns) do
      local entry = { id = c.id, name = c.name, url = c.url }
      if c.type then entry.type = c.type end
      if c.attachments and #c.attachments > 0 then entry.attachments = c.attachments end
      if c.last_used then entry.last_used = c.last_used end
      if c.env_file then entry.env_file = c.env_file end
      if c.mode then entry.mode = c.mode end
      if c.color then entry.color = c.color end
      if c.group then entry.group = c.group end
      table.insert(data, entry)
    end
    vim.fn.writefile({ vim.fn.json_encode(data) }, global_connections_path())
  end
  return id
end

--- Read g:dbs (DBUI-compatible: list or dict of connections).
--- Supports: {name, url} dicts, plain URL strings, and {name = url} dicts.
--- A {name, url} dict may also carry `group`, the picker folder it belongs to.
local function read_gdbs()
  local dbs = vim.g.dbs
  if type(dbs) ~= "table" then return {} end
  local result = {}
  for key, entry in pairs(dbs) do
    if type(entry) == "table" and entry.name and entry.url then
      -- Standard format: { name = "foo", url = "postgresql://..." }
      local group = type(entry.group) == "string" and entry.group ~= "" and entry.group or nil
      table.insert(result, { name = entry.name, url = entry.url, group = group, source = "g:dbs" })
    elseif type(entry) == "string" then
      -- Plain URL string in a list, or {name = "url"} dict
      if type(key) == "string" then
        -- Dict format: { customer_name = "postgresql://..." }
        table.insert(result, { name = key, url = entry, source = "g:dbs" })
      else
        -- List format: { "postgresql://host/db" }
        local name = entry:match("([^/]+)$") or entry
        table.insert(result, { name = name, url = entry, source = "g:dbs" })
      end
    end
  end
  return result
end

local DEFAULT_PORTS = {
  sqlserver = 1433, mssql = 1433,
  postgres = 5432, postgresql = 5432,
  mysql = 3306, mariadb = 3306,
}

--- Build a URL from a setup({ databases }) definition for one host. auth.user
--- and auth.password become the userinfo, verbatim; every other auth key
--- becomes a query parameter, sorted so the URL (the connection's identity)
--- is the same every session.
local function definition_url(def, host)
  local scheme = def.scheme or "sqlserver"
  local auth = vim.deepcopy(def.auth or {})
  local userinfo = ""
  if auth.user then
    userinfo = auth.user .. (auth.password and (":" .. auth.password) or "") .. "@"
  end
  auth.user, auth.password = nil, nil
  local keys = vim.tbl_keys(auth)
  table.sort(keys)
  local params = {}
  for _, k in ipairs(keys) do table.insert(params, k .. "=" .. tostring(auth[k])) end
  local port = def.port or DEFAULT_PORTS[scheme]
  return string.format("%s://%s%s%s/%s%s", scheme, userinfo, host,
    port and (":" .. port) or "", def.db or "",
    #params > 0 and ("?" .. table.concat(params, "&")) or "")
end

--- Expand setup({ databases = { servers, definitions } }) into connections.
--- A definition is listed once per key in its `servers`, grouped under that
--- key and named "<key> - <name>" so the active connection stays unambiguous.
--- A definition with a `url` uses it as-is instead of building one: it is
--- listed once, grouped under `group` or else its first server key.
function M.from_databases(spec)
  if type(spec) ~= "table" then return {} end
  local servers = spec.servers or {}
  local result = {}
  local function add(name, url, group)
    table.insert(result, {
      name = group and (group .. " - " .. name) or name,
      url = url, group = group, source = "config",
    })
  end
  for _, def in ipairs(spec.definitions or {}) do
    if type(def) == "table" and def.name then
      if def.url then
        add(def.name, def.url, def.group or (def.servers or {})[1])
      else
        for _, key in ipairs(def.servers or {}) do
          local host = servers[key]
          if host then add(def.name, definition_url(def, host), key) end
        end
      end
    end
  end
  return result
end

--- Read live local DB containers (Docker labels). Empty list when the
--- discovery option is disabled, docker is unavailable, or the daemon is
--- down. Never throws.
local function read_discovered_connections()
  local opts = require("dadbod-grip.config").values
  if opts.discovery == false then return {} end
  local ok, mod = pcall(require, "dadbod-grip.sources.docker_localdb")
  if not ok then return {} end
  local result = mod.fetch()
  return result and result.connections or {}
end

--- List all connections from all sources, deduplicated by URL and name.
function M.list()
  local all = {}
  local seen = {}  -- keyed by URL; URL is the canonical identifier

  -- Read the files once: the discovery loop below needs them to enrich a
  -- colliding entry, and the loop after it needs them to add the rest.
  local file_conns = read_file_connections()
  local file_by_url = {}
  for _, c in ipairs(file_conns) do
    if not file_by_url[c.url] then file_by_url[c.url] = c end
  end

  -- Discovered connections first: live containers beat hand-edited static.
  -- A user spinning up `just up` expects to see that stack at the top.
  --
  -- On a URL collision the discovered entry wins the *identity* -- its name is
  -- the running container's, which is what the user is looking for in the
  -- picker -- but the file entry still owns the settings the user configured.
  -- Dropping it whole used to take `mode` with it, so a connection saved as
  -- read-only connected writable whenever its stack happened to be up.
  for _, c in ipairs(read_discovered_connections()) do
    if not seen[c.url] then
      seen[c.url] = true
      local filed = file_by_url[c.url]
      if filed then
        -- Copy before writing: docker_localdb.fetch() memoizes its table for
        -- a 2s TTL, and mutating it would leak these settings into a later
        -- fetch whose file entry no longer carries them.
        c = vim.tbl_extend("force", {}, c)
        for _, field in ipairs({
          "id", "type", "env_file", "mode", "color", "group", "attachments", "last_used",
        }) do
          if c[field] == nil then c[field] = filed[field] end
        end
      end
      table.insert(all, c)
    end
  end

  -- File connections second (user-managed, sorted by last_used in pick())
  for _, c in ipairs(file_conns) do
    if not seen[c.url] then
      seen[c.url] = true
      table.insert(all, c)
    end
  end

  -- g:dbs (DBUI compat): also persist globally for cross-project access
  local gdbs = read_gdbs()
  local new_global = false
  local global_existing = read_json_connections(global_connections_path(), "global")
  local global_seen = {}
  for _, gc in ipairs(global_existing) do global_seen[gc.url] = gc end
  local all_by_url = {}
  for _, c in ipairs(all) do all_by_url[c.url] = c end

  for _, c in ipairs(gdbs) do
    if not seen[c.url] then
      seen[c.url] = true
      table.insert(all, c)
      all_by_url[c.url] = c
    elseif c.group then
      -- g:dbs is generated from the user's config, so its group is the
      -- current one even when a saved entry for the same URL won the dedup.
      all_by_url[c.url].group = c.group
    end
    -- Persist to global if not already there, and keep its group in step
    local gc = global_seen[c.url]
    if not gc then
      gc = { id = new_connection_id(c.url), name = c.name, url = c.url, group = c.group }
      table.insert(global_existing, gc)
      global_seen[c.url] = gc
      new_global = true
    elseif c.group and gc.group ~= c.group then
      gc.group = c.group
      new_global = true
    end
  end

  -- setup({ databases }): config-defined, so like g:dbs its group wins, but
  -- never copied to the global file -- the config already lists them every
  -- session, and their URLs carry passwords.
  for _, c in ipairs(M.from_databases(require("dadbod-grip.config").values.databases)) do
    if not seen[c.url] then
      seen[c.url] = true
      table.insert(all, c)
      all_by_url[c.url] = c
    elseif c.group then
      all_by_url[c.url].group = c.group
    end
  end

  -- Write global file if new entries were added
  if new_global then
    ensure_global_grip_dir()
    local gdata = {}
    for _, gc in ipairs(global_existing) do
      local gentry = { name = gc.name, url = gc.url }
      if gc.id then gentry.id = gc.id end
      if gc.type then gentry.type = gc.type end
      if gc.attachments and #gc.attachments > 0 then gentry.attachments = gc.attachments end
      if gc.last_used then gentry.last_used = gc.last_used end
      if gc.env_file then gentry.env_file = gc.env_file end
      if gc.mode then gentry.mode = gc.mode end
      if gc.color then gentry.color = gc.color end
      if gc.group then gentry.group = gc.group end
      table.insert(gdata, gentry)
    end
    vim.fn.writefile({ vim.fn.json_encode(gdata) }, global_connections_path())
  end

  -- Mark any connection whose URL is in the global file as source = "global".
  -- When a URL exists in both local and global files, the local entry wins the
  -- dedup above (local is read first), so its source stays "file". This pass
  -- corrects that: if a URL is in global, it gets the [g] badge regardless of
  -- which file was deduped first.
  for _, c in ipairs(all) do
    if global_seen[c.url] then
      c.source = "global"
    end
  end

  -- $DATABASE_URL
  local env_url = os.getenv("DATABASE_URL")
  if env_url and env_url ~= "" and not seen[env_url] then
    seen[env_url] = true
    table.insert(all, { name = "$DATABASE_URL", url = env_url, source = "env" })
  end

  -- Current vim.g.db (if set and not already listed by URL)
  local gdb = vim.g.db
  if type(gdb) == "string" and gdb ~= "" and not seen[gdb] then
    seen[gdb] = true
    table.insert(all, { name = "vim.g.db", url = gdb, source = "global" })
  end

  -- ── Starter connections: shown until dismissed or already present ──────
  local data_dir = vim.fn.stdpath("data") .. "/grip"
  local has_duck = vim.fn.executable("duckdb") == 1

  local starters = {
    {
      id   = "duckdb_memory",
      name = "DuckDB (memory)  · read files; no cross-query state",
      url  = "duckdb::memory:",
      cond = has_duck,
    },
    {
      id   = "duckdb_scratch",
      name = "DuckDB (scratch) · /tmp/grip_scratch.duckdb",
      url  = "duckdb:/tmp/grip_scratch.duckdb",
      cond = has_duck,
    },
    {
      id   = "sqlite_scratch",
      name = "SQLite  (scratch) · /tmp/grip_scratch.db",
      url  = "sqlite:/tmp/grip_scratch.db",
      cond = true,
    },
  }
  for _, s in ipairs(starters) do
    local hidden_f = data_dir .. "/" .. s.id .. ".hidden"
    if s.cond and not seen[s.url] and vim.fn.filereadable(hidden_f) == 0 then
      table.insert(all, { name = s.name, url = s.url, _builtin_id = s.id })
    end
  end

  return all
end

--- Mark a connection URL as healthy or failed for the current session.
--- Called by M.switch() on success/failure and by the T retest action in the picker.
function M.set_health(url, status)
  _health[url] = status
end

--- Return the current session health for a URL: "ok" | "fail" | "unresolved" | "unknown".
function M.get_health(url)
  return _health[url] or "unknown"
end

--- Add (or rename) a connection in .grip/connections.json.
--- Upsert by URL: if the URL already exists, updates name and type in place,
--- preserving last_used and attachments. Prevents accumulation of duplicates
--- and correctly handles "rename on next switch" (e.g. vim.g.db → proper name).
function M.add(name, url)
  local clean_url = strip_flags(url)
  local conns = read_local_connections()
  upsert_conn(conns, name, clean_url)
  write_file_connections(conns)
end

--- Update last_used timestamp for a saved connection (MRU tracking).
function M.touch(url)
  local clean = strip_flags(url)
  local conns = read_local_connections()
  if touch_conn(conns, clean) then
    write_file_connections(conns)
  end
end

--- Remove a connection from .grip/connections.json. Matches by URL when one is
--- given, since grouped connections often share a name ("billing" in DEV and
--- in QA); by name otherwise.
function M.remove(name, url)
  local conns = read_local_connections()
  local filtered = {}
  for _, c in ipairs(conns) do
    local match = url and c.url == url or (not url and c.name == name)
    if not match then
      table.insert(filtered, c)
    end
  end
  write_file_connections(filtered)
end

--- Switch active connection. Routes file connections through grip.open(),
--- DB connections through vim.g.db + workspace open.
--- Auto-saves to .grip/connections.json if not already persisted.
--- opts: { write = bool, watch_ms = number, mode = "ro"|"rw" }: session-only,
--- never persisted.
--- @return boolean committed  false when the switch aborted and nothing changed
function M.switch(url, name, conn_type, opts)
  -- Strip session-only flags: they must never reach the connection registry
  url = strip_flags(url)

  -- Resolve ${VAR} placeholders up front, before anything is mutated or
  -- written: a connection whose .env is missing or still git-crypt-locked
  -- must fail cleanly instead of leaving a half-switched session behind.
  -- `url` itself stays the template -- that is what gets persisted, what
  -- vim.g.db holds, and what every later lookup keys on. conn_url is only
  -- needed by the DuckDB attachment paths below, which bypass db.resolve().
  local conn_url, secret_err = M.expand_url(url)
  if not conn_url then
    -- Same distinct marker T:test sets, for the same reason: the picker has
    -- to say "this one could not resolve its secret" rather than the generic
    -- "x" of a database that is genuinely unreachable. Connecting is how most
    -- people meet this failure, so the attempt has to record it too --
    -- otherwise the user presses <CR>, reads an error, reopens the picker and
    -- finds nothing to show for it.
    M.set_health(url, "unresolved")
    vim.notify("Grip: " .. (secret_err or "could not resolve connection secrets"),
      vim.log.levels.ERROR)
    return false
  end

  -- Single read of the local file; everything below (type resolution,
  -- rename/insert, MRU touch) mutates this same in-memory list, and it is
  -- written back at most once at the end instead of once per mutation.
  local local_conns = read_local_connections()

  -- Resolve type: param > local connections > global connections > auto-detect.
  -- The global file is only read when actually needed for the lookup, since
  -- most callers already pass conn_type or have a locally-known type.
  local resolved_type = conn_type
  if not resolved_type then
    for _, c in ipairs(local_conns) do
      if c.url == url and c.type then
        resolved_type = c.type
        break
      end
    end
  end
  if not resolved_type and not configured_connections_path() then
    for _, c in ipairs(read_json_connections(global_connections_path(), "global")) do
      if c.url == url and c.type then
        resolved_type = c.type
        break
      end
    end
  end
  if not resolved_type and is_file_url(url) then
    resolved_type = "file"
  end

  -- Always upsert when a name is provided. This handles both insert (new
  -- URL) and rename (existing URL with a stale generic name like "vim.g.db").
  -- Without this, an already-saved URL would keep a stale name forever even
  -- when switching with the correct one.
  local changed = false
  if name and name ~= "" then
    upsert_conn(local_conns, name, url)
    changed = true
  end
  -- Touch AFTER upsert so first-time connections get last_used stamped.
  if touch_conn(local_conns, url) then
    changed = true
  end
  if changed then
    write_file_connections(local_conns)
  end

  -- The one place a mode override is set or cleared. Connecting the ordinary
  -- way always returns a connection to the mode its entry asks for, so an
  -- override taken by mistake is undone by reconnecting rather than by
  -- editing connections.json.
  --
  -- Below the expansion check above, deliberately: a switch that aborted did
  -- not happen, and must leave the mode of that URL exactly as it found it.
  -- Set any earlier and an `r` on an entry whose ${VAR} does not resolve
  -- would flip a read-only connection the user is still on to writable, with
  -- only a "could not resolve secrets" message to go on.
  _mode_override[url] = nil
  if opts and (opts.mode == "ro" or opts.mode == "rw") then
    _mode_override[url] = opts.mode
  end

  -- Say so, once per connect, when this particular connection cannot keep the
  -- read-only promise the rest of the UI is about to make for it. Everything
  -- downstream -- the RO badge, the DDL refusals -- reads the entry rather
  -- than what the server was actually told, so silence here leaves the one
  -- connection with a writable session looking the most protected of all.
  --
  -- Below the override, so an `r`-toggle to ro warns and a toggle to rw does
  -- not. Asked of conn_url, not the template: the `options=` can arrive inside
  -- a ${VAR}. Lazy require -- adapters reaches back into this module.
  if M.current_mode(url) == "ro" then
    local caveat = require("dadbod-grip.adapters").readonly_caveat(conn_url)
    if caveat then
      vim.notify("Grip: read-only is not enforced on this connection -- " .. caveat,
        vim.log.levels.WARN)
    end
  end

  -- Re-tint the accent groups for the connection being switched to. Read
  -- after the write above so a just-added entry is found, and passed
  -- unconditionally: an entry with no `color` (or no entry at all) has to
  -- restore the default look, not inherit the previous connection's.
  local view = require("dadbod-grip.view")
  local switched_entry = M.entry_for(url)
  view.set_connection_accent(switched_entry and switched_entry.color)
  -- A switch changes what current_mode() answers, so every grid still open
  -- has to ask again. Their badges are cached per session precisely because
  -- the winbar is rebuilt on every cursor move; a switch is the one other
  -- moment the cached answer can be wrong.
  view.invalidate_mode_cache()

  if resolved_type == "file" then
    M.set_health(url, "ok")
    -- Compute the DuckDB connection that will actually run queries against this file.
    -- Mirrors the logic in init.lua so the query pad is wired to the same connection.
    -- The scheme test needs the resolved URL (a whole-URL template hides it);
    -- the pad is still bound to the template, which db.resolve() expands.
    local active = vim.g.db
    local active_resolved = active and (M.expand_url(active) or active)
    local db_url = (active_resolved and active_resolved:match("^duckdb:")) and active
      or "duckdb::memory:"
    local label = name or url
    vim.schedule(function()
      -- No reuse_win: let find_content_win() place the grid correctly.
      -- Passing cur_win risks putting the grid in the sidebar if that window was focused.
      local open_opts = {}
      if opts and opts.write    then open_opts.write    = true       end
      if opts and opts.watch_ms then open_opts.watch_ms = opts.watch_ms end
      local schema = require("dadbod-grip.schema")
      local auto_sidebar = require("dadbod-grip.config").values.open_sidebar
      -- Both round-trips under one preloader. open() runs a blocking() of its
      -- own for the grid query; nested, that relabels this float instead of
      -- closing it, so the screen stays covered until there is a grid to show.
      -- prefetch() goes first so the sidebar opened in the next tick is
      -- already populated rather than empty for a second beside a live grid.
      ui.blocking("opening " .. label .. "...", function()
        if auto_sidebar or schema.is_open() then schema.prefetch(url) end
        require("dadbod-grip").open(url, nil, open_opts)
      end)
      -- Open sidebar and query pad after the grid is placed. Nothing here
      -- blocks any more, so both land in a single repaint.
      vim.schedule(function()
        if not schema.is_open() and auto_sidebar then
          schema.toggle(url)
        elseif schema.is_open() then
          schema.refresh(url)
        end
        require("dadbod-grip.query_pad").open(db_url)
        vim.notify("Grip: opening " .. label, vim.log.levels.INFO)
      end)
    end)
    return true
  end

  -- Regular DB connection: set vim.g.db and open full workspace
  vim.g.db = url

  -- Restore persisted attachments for DuckDB connections (local file only;
  -- attachments are always saved to local by M.save_attachments).
  --
  -- One of the four paths that bypass db.resolve(), so it expands by hand:
  -- the adapter's attachment registry is keyed by the URL the adapter is
  -- called with, which is the *expanded* one on every query, and the stored
  -- DSNs are templates that only become connectable here.
  if conn_url:find("^duckdb:") then
    local stored_atts
    for _, c in ipairs(local_conns) do
      if c.url == url and c.attachments then
        stored_atts = c.attachments
        break
      end
    end
    if stored_atts then
      local live_atts = {}
      for _, a in ipairs(stored_atts) do
        local stored_dsn = type(a) == "table" and a.dsn or nil
        if type(stored_dsn) ~= "string" then
          -- Nothing to expand: hand the record on exactly as it was read and
          -- let load_attachments deal with whatever shape it is, as before.
          table.insert(live_atts, a)
        else
          local dsn, dsn_err = M.expand_dsn(stored_dsn, url)
          if dsn then
            -- template is carried through so the next save_attachments()
            -- writes the placeholder back, not what it resolved to.
            table.insert(live_atts, {
              dsn = dsn, alias = a.alias, template = dsn ~= stored_dsn and stored_dsn or nil,
            })
          else
            vim.notify(string.format("Skipped attachment '%s': %s", a.alias, dsn_err),
              vim.log.levels.WARN)
          end
        end
      end
      require("dadbod-grip.adapters.duckdb").load_attachments(conn_url, live_atts)
    end
  end

  M.set_health(url, "ok")
  local label = name or url

  vim.schedule(function()
    local schema = require("dadbod-grip.schema")
    local auto_sidebar = require("dadbod-grip.config").values.open_sidebar

    -- One preloader over the whole workspace. The table list is fetched here,
    -- before any of these windows exist, and the three panes are then built
    -- with nothing blocking between them -- so the float lifts on a finished
    -- layout. Built the other way round, each pane appeared empty and filled
    -- in a second later, which read as the plugin assembling itself on screen.
    ui.blocking("connecting to " .. label .. "...", function()
      if auto_sidebar or schema.is_open() then schema.prefetch(url) end

      if not schema.is_open() and auto_sidebar then
        schema.toggle(url)
      elseif schema.is_open() then
        schema.refresh(url)
      end

      -- Show welcome screen in the main content area
      require("dadbod-grip").open_welcome()

      local query_pad = require("dadbod-grip.query_pad")
      query_pad.open(url)

      -- Focus sidebar so user can immediately browse tables
      if auto_sidebar and schema.is_open() and schema.get_winid() then
        vim.api.nvim_set_current_win(schema.get_winid())
      end
    end)

    -- After the layout, not before it: fired first, this toast hung alone over
    -- an empty screen for however long the schema took to arrive.
    vim.notify("Grip: connected to " .. label, vim.log.levels.INFO)
  end)
  return true
end

--- Get current connection info.
function M.current()
  local url = vim.g.db
  if type(url) ~= "string" or url == "" then
    url = os.getenv("DATABASE_URL")
  end
  if not url or url == "" then return nil end

  -- Try to find name from known connections
  for _, c in ipairs(M.list()) do
    if c.url == url then
      return { name = c.name, url = c.url }
    end
  end
  return { name = nil, url = url }
end

--- Persist attachments for a DuckDB connection URL.
--- Called after attach/detach to update .grip/connections.json.
---
--- `url` is the connection URL as stored (templated), since that is the key
--- the entry lives under on disk; the live adapter registry is keyed by the
--- expanded URL, so callers pass the two separately.
---
--- Each record is persisted as `a.template or a.dsn`: a live attachment
--- record carries the expanded, password-bearing DSN, and writing that here
--- would put the password on disk through a field nothing else covers. The
--- template is resolved again on replay by M.switch/expand_dsn. Records with
--- no template (a literal DSN) round-trip byte-identically, as before.
function M.save_attachments(url, attachments)
  local file_conns = read_local_connections()
  local found = false
  for _, c in ipairs(file_conns) do
    if c.url == url then
      c.attachments = attachments and #attachments > 0 and {} or nil
      if attachments then
        for _, a in ipairs(attachments) do
          table.insert(c.attachments, { dsn = a.template or a.dsn, alias = a.alias })
        end
      end
      found = true
      break
    end
  end
  if found then
    write_file_connections(file_conns)
  end
end

--- Open the connection picker. See connections/picker.lua.
function M.pick(opts)
  return require("dadbod-grip.connections.picker").pick(opts)
end

function M.grip_dir_path()
  return grip_dir()
end

return M
