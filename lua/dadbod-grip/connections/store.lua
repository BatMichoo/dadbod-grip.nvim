-- connections/store.lua: reading and writing connections.json (project and
-- global), and the pure list helpers the write paths share.

local paths = require("dadbod-grip.paths")
local is_file_url = require("dadbod-grip.connections.local_files").is_file_url

local M = {}

local grip_dir = paths.grip_dir

local function configured_connections_path()
  local opts = require("dadbod-grip.config").values
  return opts.connections_path
end

local function connections_path()
  return configured_connections_path() or (grip_dir() .. "/connections.json")
end

local function global_connections_path()
  local home = vim.fn.expand("~")
  return home .. "/.grip/connections.json"
end

local function ensure_grip_dir()
  local custom = configured_connections_path()
  paths.ensure_dir(custom and vim.fn.fnamemodify(custom, ":h") or grip_dir())
end

local function ensure_global_grip_dir()
  paths.ensure_dir(vim.fn.expand("~") .. "/.grip")
end

--- Stable opaque identity for a persisted connection. This is an identifier,
--- not a secret; entropy only needs to make accidental collisions negligible.
local function new_connection_id(url)
  local seed = table.concat({
    tostring(url),
    tostring(os.time()),
    tostring(vim.fn.getpid()),
    tostring(vim.uv.hrtime()),
    tostring(math.random()),
  }, ":")
  return "conn_" .. vim.fn.sha256(seed):sub(1, 24)
end

--- Read connections from a JSON file.
local function read_json_connections(path, source)
  if vim.fn.filereadable(path) == 0 then return {} end
  local raw = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok or type(data) ~= "table" then return {} end
  local result = {}
  for _, entry in ipairs(data) do
    if type(entry) == "table" and entry.name and entry.url then
      local c = { name = entry.name, url = entry.url,
                  type = entry.type, source = source or "file" }
      if entry.id then c.id = entry.id end
      if entry.attachments then c.attachments = entry.attachments end
      if entry.last_used then c.last_used = entry.last_used end
      if entry.env_file then c.env_file = entry.env_file end
      if entry.mode then c.mode = entry.mode end
      if entry.color then c.color = entry.color end
      if type(entry.group) == "string" and entry.group ~= "" then c.group = entry.group end
      table.insert(result, c)
    end
  end
  return result
end

--- Read connections from the project-local file only.
--- Use this for all mutation paths (add, touch, remove, save_attachments).
--- Keeping mutation local-only prevents global connections from leaking into
--- the local file on every write.
local function read_local_connections()
  return read_json_connections(connections_path(), "file")
end

--- Read connections from project-local and global files (read-only paths only).
--- When connections_path is configured, reads ONLY that file (no global merge).
--- Do NOT pass this result to write_file_connections — use read_local_connections.
local function read_file_connections()
  if configured_connections_path() then
    return read_local_connections()
  end
  local result = {}
  for _, c in ipairs(read_local_connections()) do
    table.insert(result, c)
  end
  for _, c in ipairs(read_json_connections(global_connections_path(), "global")) do
    table.insert(result, c)
  end
  return result
end

--- Write connections to .grip/connections.json.
--- Deduplicates by URL before writing, keeping the entry with the highest
--- last_used timestamp. This self-heals files bloated by historical bugs.
local function write_file_connections(conns)
  ensure_grip_dir()
  -- Dedup by URL: keep highest last_used per URL
  local order = {}
  local by_url = {}
  for _, c in ipairs(conns) do
    if not by_url[c.url] then
      by_url[c.url] = c
      table.insert(order, c.url)
    elseif (c.last_used or 0) > (by_url[c.url].last_used or 0) then
      c.id = c.id or by_url[c.url].id
      by_url[c.url] = c
    elseif not by_url[c.url].id and c.id then
      by_url[c.url].id = c.id
    end
  end
  local data = {}
  for _, url in ipairs(order) do
    local c = by_url[url]
    local entry = { name = c.name, url = c.url }
    if c.id then entry.id = c.id end
    if c.type then entry.type = c.type end
    if c.attachments and #c.attachments > 0 then entry.attachments = c.attachments end
    if c.last_used then entry.last_used = c.last_used end
    if c.env_file then entry.env_file = c.env_file end
    if c.mode then entry.mode = c.mode end
    if c.color then entry.color = c.color end
    if c.group then entry.group = c.group end
    table.insert(data, entry)
  end
  local json = vim.fn.json_encode(data)
  vim.fn.writefile({ json }, connections_path())
end

--- Strip session-only flags from a URL before persisting.
--- --write / --watch / --watch=Ns must never reach connections.json.
local function strip_flags(url)
  if not url then return url end
  url = url:gsub("%s*%-%-write%s*", " ")
  url = url:gsub("%s*%-%-watch=%d+s?%s*", " ")
  url = url:gsub("%s*%-%-watch%s*", " ")
  return vim.trim(url)
end

--- Upsert a connection by URL into an in-memory list: renames in place if the
--- URL is already present, otherwise inserts a new entry. Pure (no I/O) so it
--- can be shared by M.add() and M.switch()'s single-read/single-write path.
local function upsert_conn(conns, name, url)
  local found = false
  for _, c in ipairs(conns) do
    if c.url == url then
      c.name = name
      if is_file_url(url) then c.type = "file" end
      found = true
    end
  end
  if found then return end
  local conn_type = is_file_url(url) and "file" or nil
  table.insert(conns, { id = new_connection_id(url), name = name, url = url, type = conn_type })
end

--- Update last_used on a matching entry in an in-memory list (MRU tracking).
--- Pure (no I/O). Returns true when a match was found and updated.
local function touch_conn(conns, url)
  for _, c in ipairs(conns) do
    if c.url == url then
      c.last_used = os.time()
      return true
    end
  end
  return false
end

M.configured_connections_path = configured_connections_path
M.connections_path = connections_path
M.global_connections_path = global_connections_path
M.ensure_grip_dir = ensure_grip_dir
M.ensure_global_grip_dir = ensure_global_grip_dir
M.new_connection_id = new_connection_id
M.read_json_connections = read_json_connections
M.read_local_connections = read_local_connections
M.read_file_connections = read_file_connections
M.write_file_connections = write_file_connections
M.strip_flags = strip_flags
M.upsert_conn = upsert_conn
M.touch_conn = touch_conn

return M
