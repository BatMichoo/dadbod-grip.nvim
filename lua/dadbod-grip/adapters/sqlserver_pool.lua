-- SQL Server connection pooling: keep one sqlcmd process alive per connection
-- identity and feed it successive batches instead of spawning fresh per call.
-- Handles disposal on tab close, Neovim exit, or idle timeout.

local M = {}

local adapters = require("dadbod-grip.adapters")
local config = require("dadbod-grip.config")

-- Pool entries: key -> entry (see spawn_process for the fields).
local _pool = {}

-- Lazily-created autocmd group for TabClosed and VimLeavePre.
local _ag = nil

-- Injection point for unit tests: allows a fake vim.system(...) spawner.
local _spawner = nil

-- How long a closed process gets to exit on stdin EOF before SIGKILL.
local CLOSE_GRACE_MS = 2000

-- Server error header as both clients print it. Anchored to a whole line with
-- no tabs, so a multi-column result row (-s "\t") cannot match.
local ERROR_HEADER = "^Msg %d+, Level (%d+), State %d+, Server [^\t,]+, [^\t]*Line %d+\r?\n$"

-- Build a unique key for a parsed connection (host/port/dbname/user/auth/
-- encrypt/trust/cert/password). The password goes in as a hash, so the secret
-- is never a map key, yet a connection with a different password cannot run
-- on a session another password opened.
function M.key_for(parsed)
  return table.concat({
    parsed.host or "",
    parsed.port or "",
    parsed.dbname or "",
    parsed.user or "",
    parsed.authentication or "",
    parsed.encrypt or "",
    tostring(parsed.trust_server_certificate or false),
    parsed.server_certificate or "",
    parsed.pass and vim.fn.sha256(parsed.pass) or "",
  }, "\1")
end

-- Introspect the live pool registry (test/diagnostic use only).
function M._entries()
  return _pool
end

-- Test seam: inject a fake vim.system spawner. fn receives (args, opts,
-- on_exit) and returns a mock SystemObj with write(data) and kill(sig).
function M._set_spawner(fn)
  _spawner = fn
end

-- Stop using an entry: drop it from the pool and end its process. graceful
-- closes stdin so sqlcmd logs out and exits on its own, with SIGKILL as a
-- deferred fallback; otherwise (timeout, desync) the process is killed now.
local function close_entry(entry, graceful)
  if entry.idle_timer then
    entry.idle_timer:stop()
    entry.idle_timer:close()
    entry.idle_timer = nil
  end
  if _pool[entry.key] == entry then _pool[entry.key] = nil end
  entry.busy = false
  entry.closed = true
  if entry.dead then return end
  if graceful then
    pcall(entry.obj.write, entry.obj, nil)
    vim.defer_fn(function()
      if not entry.dead then pcall(entry.obj.kill, entry.obj, "sigkill") end
    end, CLOSE_GRACE_MS)
  else
    pcall(entry.obj.kill, entry.obj, "sigkill")
  end
end

-- Lazily register autocmds (called on first pool use).
local function ensure_autocmds()
  if _ag then return end
  _ag = vim.api.nvim_create_augroup("DadbodGripSqlServerPool", { clear = true })

  -- TabClosed: prune closed tabs from each entry; close entries with no tabs left.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = _ag,
    callback = function()
      for _, entry in pairs(_pool) do
        for handle in pairs(entry.tabs) do
          if not vim.api.nvim_tabpage_is_valid(handle) then
            entry.tabs[handle] = nil
          end
        end
        if vim.tbl_isempty(entry.tabs) and not entry.busy then
          close_entry(entry, true)
        end
      end
    end,
  })

  -- VimLeavePre: dispose all entries.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = _ag,
    callback = function() M.dispose_all() end,
  })
end

-- Arm/rearm the idle timer for an entry (called after each successful batch).
-- The batch count guards against a firing that was already queued when
-- another batch started.
local function arm_idle_timer(entry)
  entry.idle_timer = entry.idle_timer or vim.uv.new_timer()
  entry.idle_timer:stop()
  local armed_at = entry.batches
  entry.idle_timer:start(config.values.sqlserver_pool_idle_timeout, 0, vim.schedule_wrap(function()
    if entry.closed or entry.busy or entry.batches ~= armed_at then return end
    close_entry(entry, true)
  end))
end

-- Feed one stdout chunk through the batch framing. Runs in a libuv callback,
-- so it sticks to plain string work: complete lines are collected into
-- entry.out, error headers raise entry.max_level, and the sentinel line ends
-- the batch. Output while no batch is waiting means the framing is broken.
local function on_stdout(entry, data)
  if not data or data == "" then return end
  if not entry.token or entry.done then
    entry.desync = true
    return
  end
  local pos = 1
  while true do
    local nl = data:find("\n", pos, true)
    if not nl then break end
    local line = data:sub(pos, nl)
    if #entry.pending > 0 then
      entry.pending[#entry.pending + 1] = line
      line = table.concat(entry.pending)
      entry.pending = {}
    end
    pos = nl + 1
    if line == entry.token .. "\n" or line == entry.token .. "\r\n" then
      entry.done = true
      if pos <= #data then entry.desync = true end
      return
    end
    local level = line:match(ERROR_HEADER)
    if level then entry.max_level = math.max(entry.max_level, tonumber(level)) end
    entry.out[#entry.out + 1] = line
  end
  if pos <= #data then entry.pending[#entry.pending + 1] = data:sub(pos) end
end

-- One-shot argv uses -b so a server error sets the exit code, but -b also ends
-- the process, which would throw away the pooled session on every error. The
-- pool drops it and reads each batch's "Msg N, Level L, ..." headers instead
-- (both mssql-tools and go-sqlcmd print them on stdout without -b).
local function pooled_args(args)
  return vim.tbl_filter(function(arg) return arg ~= "-b" end, args)
end

-- Spawn a new sqlcmd process with streaming stdin.
local function spawn_process(key, parsed, sqlcmd_args_fn, sqlcmd_env_fn)
  local entry = {
    key = key,
    tabs = {},
    batches = 0,
    out = {},       -- complete stdout lines of the current batch
    pending = {},   -- pieces of a stdout line still missing its newline
    err = {},       -- stderr chunks of the current batch
    max_level = 0,
  }

  local ok, obj = pcall(_spawner or vim.system, pooled_args(sqlcmd_args_fn(parsed)), {
    text = true,
    stdin = true,
    stdout = function(_, data) on_stdout(entry, data) end,
    stderr = function(_, data)
      if data then entry.err[#entry.err + 1] = data end
    end,
    env = sqlcmd_env_fn(parsed),
  }, function(r)
    entry.dead = true
    entry.exit_code = r.code
  end)

  if not ok then return nil, tostring(obj) end
  entry.obj = obj
  return entry
end

-- Send one script plus a closing batch that rolls back any transaction it left
-- open (bounding lock exposure) and prints a random sentinel, then wait for
-- the sentinel. Returns "done", "fatal", "dead" or "timeout". Level >= 20
-- means the server is dropping the session; go-sqlcmd then hangs instead of
-- exiting, so stop waiting at once.
local function send_batch(entry, script, timeout_ms)
  entry.batches = entry.batches + 1
  entry.out, entry.pending, entry.err, entry.max_level, entry.done = {}, {}, {}, 0, false
  entry.token = "GRIPEOB:" .. vim.uv.random(8):gsub(".", function(c)
    return string.format("%02x", c:byte())
  end)
  entry.obj:write(script .. "\nGO\nIF @@TRANCOUNT > 0 ROLLBACK TRANSACTION\nPRINT '"
    .. entry.token .. "'\nGO\n")

  vim.wait(math.max(timeout_ms, 0), function()
    return entry.done or entry.dead or entry.max_level >= 20
  end, 5)
  entry.token = nil

  if entry.done then return "done" end
  if entry.max_level >= 20 then
    -- mssql-tools exits on its own; give it a moment to flush the rest.
    vim.wait(500, function() return entry.dead end, 10)
    return "fatal"
  end
  return entry.dead and "dead" or "timeout"
end

-- Run one batch (script) against the pooled connection for `parsed`.
-- Returns (stdout, stderr, code) matching adapters.run_cmd's contract.
function M.run(parsed, script, timeout_ms, sqlcmd_args_fn, sqlcmd_env_fn)
  if not config.values.sqlserver_pool then
    return adapters.run_cmd(sqlcmd_args_fn(parsed), timeout_ms,
      { stdin = script, env = sqlcmd_env_fn(parsed) })
  end

  ensure_autocmds()
  local key = M.key_for(parsed)
  local deadline = vim.uv.now() + timeout_ms

  -- Wait for exclusive access to this connection's process.
  local entry
  local free = vim.wait(timeout_ms, function()
    entry = _pool[key]
    return not (entry and entry.busy)
  end, 5)
  if not free then
    return "", "Connection busy, timed out waiting", 1
  end

  -- A process that died while idle (server or network dropped it) or printed
  -- out of turn cannot be trusted with the next batch; start a fresh one.
  local tabs
  if entry and (entry.dead or entry.desync) then
    tabs = entry.tabs
    close_entry(entry)
    entry = nil
  end
  if not entry then
    local err
    entry, err = spawn_process(key, parsed, sqlcmd_args_fn, sqlcmd_env_fn)
    if not entry then
      return "", "Failed to start sqlcmd: " .. (err or "unknown error"), 1
    end
    entry.tabs = tabs or entry.tabs
    _pool[key] = entry
  end
  entry.tabs[vim.api.nvim_get_current_tabpage()] = true
  entry.busy = true

  local status = send_batch(entry, script, deadline - vim.uv.now())
  local stdout = table.concat(entry.out) .. table.concat(entry.pending)
  local stderr = table.concat(entry.err)

  if status == "timeout" then
    close_entry(entry)
    return "", "Query timed out or connection desynchronized (recreating connection)", 1
  end
  if status ~= "done" then
    -- Fatal server error or crash: hand back what the process printed so the
    -- "Msg NNNN" text survives.
    close_entry(entry)
    local code = entry.exit_code
    if not code or code == 0 or status == "fatal" then code = 1 end
    return stdout, stderr, code
  end

  if entry.desync then
    -- This batch's output is complete, but the process printed past the
    -- sentinel; do not hand it another batch.
    close_entry(entry)
  else
    entry.busy = false
    arm_idle_timer(entry)
  end

  -- Severity 11+ is an error; 10 and below are informational messages.
  -- Without -r, stderr only carries client-side failures.
  if entry.max_level >= 11 or vim.trim(stderr) ~= "" then
    return stdout, stderr, 1
  end
  return stdout, stderr, 0
end

-- Close every pool entry. Called from VimLeavePre and tests: all processes get
-- stdin EOF at once, one shared wait lets them log out, and any left are killed.
function M.dispose_all()
  local entries = vim.tbl_values(_pool)
  for _, entry in ipairs(entries) do
    close_entry(entry, true)
  end
  vim.wait(1000, function()
    for _, entry in ipairs(entries) do
      if not entry.dead then return false end
    end
    return true
  end, 10)
  for _, entry in ipairs(entries) do
    if not entry.dead then pcall(entry.obj.kill, entry.obj, "sigkill") end
  end
end

return M
