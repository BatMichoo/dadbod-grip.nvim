local health = require("dadbod-grip.health")

local pass, fail = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function capture(opts)
  local reports = {}
  local original_health = vim.health
  local original_executable = vim.fn.executable
  local original_has = vim.fn.has

  vim.health = {}
  for _, level in ipairs({ "start", "ok", "warn", "error", "info" }) do
    vim.health[level] = function(message)
      table.insert(reports, { level = level, message = message })
    end
  end
  vim.fn.executable = function(name)
    return opts.executables[name] and 1 or 0
  end
  vim.fn.has = function(feature)
    if feature == "nvim-0.10" then return opts.modern_nvim == false and 0 or 1 end
    return original_has(feature)
  end

  local ok, err = pcall(health.check)
  vim.health = original_health
  vim.fn.executable = original_executable
  vim.fn.has = original_has
  assert(ok, err)
  return reports
end

local function find(reports, level, text)
  for _, report in ipairs(reports) do
    if report.level == level and report.message:find(text, 1, true) then return report end
  end
end

test("health checks sqlcmd with the other database CLIs", function()
  local reports = capture({ executables = {} })
  assert(find(reports, "warn", "sqlcmd not found"), vim.inspect(reports))
end)

print(string.format("\nhealth_spec: %d passed, %d failed", pass, fail))
if fail > 0 then vim.cmd("cquit 1") end
