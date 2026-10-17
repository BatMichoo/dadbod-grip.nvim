-- duckdb_argv_spec.lua: SQL and attachment secrets must never enter argv.
dofile("tests/minimal_init.lua")

local duckdb = require("dadbod-grip.adapters.duckdb")

local dir = vim.fn.tempname() .. "_duckdb_argv"
local executable = dir .. "/duckdb"
local pid_file = dir .. "/pid"
local stdin_file = dir .. "/stdin"
local ready_file = dir .. "/ready"
local release_file = dir .. "/release"
local url = "duckdb::memory:"
local password = "argv_secret_hunter2_7f3c"
local dsn = "postgres:dbname=analytics host=db.internal user=reporter password=" .. password

vim.fn.mkdir(dir, "p")
vim.fn.writefile({
  "#!/bin/sh",
  "printf '%s' \"$$\" > \"$GRIP_DUCKDB_PID_FILE\"",
  "cat > \"$GRIP_DUCKDB_STDIN_FILE\"",
  ": > \"$GRIP_DUCKDB_READY_FILE\"",
  "while [ ! -f \"$GRIP_DUCKDB_RELEASE_FILE\" ]; do sleep 0.02; done",
  "printf 'probe\\n'",
}, executable)
assert(vim.fn.setfperm(executable, "rwx------") == 1, "could not create fake DuckDB")

local old = {
  path = vim.env.PATH,
  pid = vim.env.GRIP_DUCKDB_PID_FILE,
  stdin = vim.env.GRIP_DUCKDB_STDIN_FILE,
  ready = vim.env.GRIP_DUCKDB_READY_FILE,
  release = vim.env.GRIP_DUCKDB_RELEASE_FILE,
}
vim.env.PATH = dir .. ":" .. (old.path or "")
vim.env.GRIP_DUCKDB_PID_FILE = pid_file
vim.env.GRIP_DUCKDB_STDIN_FILE = stdin_file
vim.env.GRIP_DUCKDB_READY_FILE = ready_file
vim.env.GRIP_DUCKDB_RELEASE_FILE = release_file

-- The query blocks in run_cmd, which pumps the event loop; a timer inspects
-- the live process from there, then releases it.
local done = false
local function inspect_process()
  local pid = assert(vim.fn.readfile(pid_file)[1], "fake DuckDB did not record its pid")
  -- /proc/<pid>/cmdline only exists on Linux. macOS (and other BSDs) have no
  -- /proc; read the full, untruncated argv via `ps -ww -o command=` instead.
  local cmdline
  local proc_path = "/proc/" .. pid .. "/cmdline"
  if vim.fn.filereadable(proc_path) == 1 then
    local cmdline_file = assert(io.open(proc_path, "rb"))
    cmdline = cmdline_file:read("*a")
    cmdline_file:close()
  else
    local ps = assert(io.popen("ps -ww -o command= -p " .. pid, "r"), "could not run ps")
    cmdline = ps:read("*a")
    ps:close()
    assert(cmdline and cmdline ~= "", "ps returned no output for pid " .. pid)
  end

  for _, forbidden in ipairs({
    "SELECT", "ATTACH", "CREATE SECRET", "postgres:", "db.internal",
    "analytics", password, dsn,
  }) do
    assert(not cmdline:find(forbidden, 1, true),
      string.format("DuckDB argv exposed %q: %s", forbidden, cmdline:gsub("%z", " ")))
  end

  local stdin = table.concat(vim.fn.readfile(stdin_file), "\n")
  assert(stdin:find("CREATE SECRET", 1, true), "credential secret was not sent on stdin")
  assert(stdin:find(password, 1, true), "stdin did not receive the credential")
  assert(stdin:find("ATTACH IF NOT EXISTS", 1, true), "attachment was not sent on stdin")
  assert(stdin:find("grip_argv_probe", 1, true), "query was not sent on stdin")
end

local inspected, inspect_err = false, nil
local timer = vim.uv.new_timer()
timer:start(10, 10, vim.schedule_wrap(function()
  if inspected or vim.fn.filereadable(ready_file) == 0 then return end
  inspected = true
  timer:stop()
  local ok_i, e = xpcall(inspect_process, debug.traceback)
  if not ok_i then inspect_err = e end
  vim.fn.writefile({ "release" }, release_file)
end))

local ok, err = xpcall(function()
  duckdb._attach_unchecked(url, dsn, "reporting")
  duckdb.query("SELECT 'grip_argv_probe'", url)
  done = true
  assert(inspected, "fake DuckDB never reached its process-inspection barrier")
  if inspect_err then error(inspect_err, 0) end
end, debug.traceback)
if not timer:is_closing() then timer:stop(); timer:close() end

-- Always release and reap the fake process before restoring PATH/removing files.
if vim.fn.filereadable(release_file) == 0 then vim.fn.writefile({ "release" }, release_file) end
duckdb.detach(url, "reporting")
vim.env.PATH = old.path
vim.env.GRIP_DUCKDB_PID_FILE = old.pid
vim.env.GRIP_DUCKDB_STDIN_FILE = old.stdin
vim.env.GRIP_DUCKDB_READY_FILE = old.ready
vim.env.GRIP_DUCKDB_RELEASE_FILE = old.release
vim.fn.delete(dir, "rf")

if not ok then error(err, 0) end
print("duckdb_argv_spec: 1 passed, 0 failed")
