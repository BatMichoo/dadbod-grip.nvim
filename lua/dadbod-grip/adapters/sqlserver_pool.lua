-- SQL Server connection pooling: keep one sqlcmd process alive per connection
-- identity and feed it successive batches instead of spawning fresh per call.
-- Handles disposal on tab close, Neovim exit, or idle timeout.

local M = {}

local adapters = require("dadbod-grip.adapters")
local config = require("dadbod-grip.config")

-- Pool entries: key -> { obj, buf, stderr_buf, busy, dead, tabs, idle_timer, batch_counter, identity }
local _pool = {}

-- Lazily-created autocmd group for TabClosed, VimLeavePre, etc.
local _ag = nil

-- Injection point for unit tests: allows a fake vim.system(...) spawner.
local _spawner = nil

-- Build a unique key for a parsed connection (host/port/dbname/user/auth/encrypt/trust/cert).
-- Notably excludes password to avoid making the secret a map key.
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
  }, "\1")
end

-- Extract stdout up to and including the sentinel token.
-- Returns (stdout_before_sentinel, found) where found = true if sentinel was found.
function M._extract_until_sentinel(buffer, token)
  local idx = buffer:find(token, 1, true)
  if not idx then return buffer, false end
  local before = buffer:sub(1, idx - 1)
  return before, true
end

-- Introspect the live pool registry (test/diagnostic use only).
function M._entries()
  return _pool
end

-- Test seam: inject a fake vim.system spawner. fn receives (args, opts) and
-- returns a mock SystemObj with write(data), kill(sig), and an on_exit callback.
function M._set_spawner(fn)
  _spawner = fn
end

-- Kill a pool entry: SIGTERM -> wait -> SIGKILL. Never raises.
local function kill_entry(entry)
  if entry.dead then return end
  pcall(entry.obj.kill, entry.obj, "sigterm")
  vim.wait(2000, function() return entry.dead end, 10)
  if not entry.dead then
    pcall(entry.obj.kill, entry.obj, "sigkill")
  end
  vim.wait(500, function() return entry.dead end, 10)
end

-- Lazily register autocmds (called on first pool use).
local function ensure_autocmds()
  if _ag then return end
  _ag = vim.api.nvim_create_augroup("DadbodGripSqlServerPool", { clear = true })

  -- TabClosed: prune closed tabs from each entry; dispose entries with no tabs left.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = _ag,
    callback = function()
      for key, entry in pairs(_pool) do
        for handle in pairs(entry.tabs) do
          if not vim.api.nvim_tabpage_is_valid(handle) then
            entry.tabs[handle] = nil
          end
        end
        if vim.tbl_isempty(entry.tabs) then
          kill_entry(entry)
          if entry.idle_timer then
            pcall(function() entry.idle_timer:stop(); entry.idle_timer:close() end)
          end
          _pool[key] = nil
        end
      end
    end,
  })

  -- VimLeavePre: dispose all entries.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = _ag,
    callback = M.dispose_all,
  })
end

-- Arm/rearm the idle timer for an entry (called after each successful batch).
local function arm_idle_timer(entry, timeout_ms)
  if entry.idle_timer then
    entry.idle_timer:stop()
  else
    entry.idle_timer = vim.uv.new_timer()
  end

  local function fire()
    if entry.busy then
      arm_idle_timer(entry, timeout_ms)
      return
    end
    kill_entry(entry)
    entry.idle_timer = nil
    _pool[entry.key] = nil
  end

  entry.idle_timer:start(timeout_ms, 0, vim.schedule_wrap(fire))
end

-- Spawn a new sqlcmd process with streaming stdin.
local function spawn_process(parsed, sqlcmd_args_fn, sqlcmd_env_fn)
  local args = sqlcmd_args_fn(parsed)
  local env = sqlcmd_env_fn(parsed)

  local entry = {
    buf = "",
    stderr_buf = "",
    dead = false,
    batch_counter = 0,
    identity = {
      host = parsed.host,
      port = parsed.port,
      dbname = parsed.dbname,
      user_or_auth = parsed.user or parsed.authentication or "integrated",
    },
  }

  local sys_opts = {
    text = true,
    stdin = true,
    stdout = function(err, data)
      entry.buf = entry.buf .. (data or "")
    end,
    stderr = function(err, data)
      entry.stderr_buf = entry.stderr_buf .. (data or "")
    end,
    env = env,
  }

  local ok, err = pcall(function()
    local spawner = _spawner or vim.system
    entry.obj = spawner(args, sys_opts, function(r)
      entry.dead = true
      entry.exit_code = r.code
    end)
  end)

  if not ok then
    return nil, tostring(err)
  end

  return entry
end

-- Run one batch (script) against the pooled connection identified by key.
-- Returns (stdout, stderr, code) matching adapters.run_cmd's contract.
function M.run(key, parsed, script, timeout_ms, sqlcmd_args_fn, sqlcmd_env_fn)
  local pool_enabled = config.values.sqlserver_pool
  if pool_enabled == nil then pool_enabled = true end

  if not pool_enabled then
    -- Pooling disabled; fall back to one-shot via adapters.run_cmd.
    return adapters.run_cmd(sqlcmd_args_fn(parsed), timeout_ms,
      { stdin = script, env = sqlcmd_env_fn(parsed) })
  end

  ensure_autocmds()

  -- Get or create the pool entry.
  local entry = _pool[key]
  if not entry then
    local err
    entry, err = spawn_process(parsed, sqlcmd_args_fn, sqlcmd_env_fn)
    if not entry then
      return "", "Failed to spawn sqlcmd: " .. (err or "unknown error"), 1
    end
    entry.key = key
    entry.tabs = {}
    _pool[key] = entry
  end

  -- Record the current tabpage as using this connection (idempotent).
  local current_tab = vim.api.nvim_get_current_tabpage()
  entry.tabs[current_tab] = true

  -- Busy-wait for exclusive access to this entry's stdin.
  local deadline = vim.loop.now() + timeout_ms
  while entry.busy do
    if vim.loop.now() > deadline then
      return "", "Connection busy, timed out waiting", 1
    end
    vim.wait(10, function() return not entry.busy end, 5)
  end
  entry.busy = true

  -- Check if the process is dead (error on last batch or crashed); respawn.
  if entry.dead then
    local err
    entry, err = spawn_process(parsed, sqlcmd_args_fn, sqlcmd_env_fn)
    if not entry then
      entry.busy = false
      return "", "Failed to respawn sqlcmd: " .. (err or "unknown error"), 1
    end
    entry.key = key
    entry.tabs = { [current_tab] = true }
    _pool[key] = entry
  end

  -- Generate a unique sentinel token for this batch.
  entry.batch_counter = entry.batch_counter + 1
  local token = string.format("\x01GRIPEOB:%d:%x\x01", entry.batch_counter, math.random(0, 0xffffffff))

  -- Submit the batch + sentinel marker.
  local payload = script .. "\nGO\nPRINT '" .. token .. "'\nGO\n"
  entry.obj:write(payload)

  -- Wait for the sentinel to appear in stdout.
  local found_sentinel = false
  vim.wait(timeout_ms, function()
    return entry.buf:find(token, 1, true) ~= nil or entry.dead
  end, 5)

  found_sentinel = entry.buf:find(token, 1, true) ~= nil

  -- Extract the batch's output (everything before the sentinel).
  local stdout = entry.buf
  local sentinel_idx = stdout:find(token, 1, true)

  if found_sentinel then
    -- Trim to just before the sentinel.
    stdout = entry.buf:sub(1, sentinel_idx - 1)
    -- Keep the rest (after the sentinel) for the next batch.
    entry.buf = entry.buf:sub(sentinel_idx + token:len())
  else
    -- No sentinel found: process died or timeout. Kill and respawn.
    kill_entry(entry)
    if entry.idle_timer then
      pcall(function() entry.idle_timer:stop(); entry.idle_timer:close() end)
    end
    _pool[key] = nil
    entry.busy = false
    return "", "Query timed out or connection desynchronized (recreating connection)", 1
  end

  -- Run safety-net rollback to bound transaction-leak window.
  local rollback_token = string.format("\x01GRIPEOB:%d:%x\x01", entry.batch_counter + 1, math.random(0, 0xffffffff))
  entry.batch_counter = entry.batch_counter + 1
  local rollback_payload = "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION\nGO\nPRINT '" .. rollback_token .. "'\nGO\n"
  entry.obj:write(rollback_payload)

  local rollback_found = false
  vim.wait(timeout_ms, function()
    return entry.buf:find(rollback_token, 1, true) ~= nil or entry.dead
  end, 5)

  rollback_found = entry.buf:find(rollback_token, 1, true) ~= nil

  if rollback_found then
    local rollback_idx = entry.buf:find(rollback_token, 1, true)
    entry.buf = entry.buf:sub(rollback_idx + rollback_token:len())
  else
    -- Rollback timeout/process death: kill and respawn.
    kill_entry(entry)
    if entry.idle_timer then
      pcall(function() entry.idle_timer:stop(); entry.idle_timer:close() end)
    end
    _pool[key] = nil
    entry.busy = false
    return "", "Connection desynchronized during rollback (recreating connection)", 1
  end

  -- Mark entry idle again and arm the idle timer.
  entry.busy = false
  arm_idle_timer(entry, config.values.sqlserver_pool_idle_timeout)

  -- Return the batch output to the caller.
  return stdout, entry.stderr_buf, 0
end

-- Kill and discard every pool entry. Called from VimLeavePre and tests.
function M.dispose_all()
  for key, entry in pairs(_pool) do
    if entry.idle_timer then
      pcall(function() entry.idle_timer:stop(); entry.idle_timer:close() end)
    end
    kill_entry(entry)
  end
  _pool = {}
end

return M
