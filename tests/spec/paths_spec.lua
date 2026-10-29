-- paths_spec.lua -- per-project state lives under stdpath("state"), not the repo
local paths = require("dadbod-grip.paths")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

--- Run fn with cwd set to a fresh temp tree; restores cwd afterwards.
local function in_tree(fn)
  local base = vim.fn.resolve(vim.fn.tempname() .. "_grip_paths")
  vim.fn.mkdir(base .. "/repo/sub/deeper", "p")
  local orig_cwd = vim.fn.getcwd()
  local ok, err = pcall(fn, base)
  vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
  vim.fn.delete(base, "rf")
  if not ok then error(err) end
end

test("project_root walks up to the nearest .git directory", function()
  in_tree(function(base)
    vim.fn.mkdir(base .. "/repo/.git", "p")
    vim.cmd("cd " .. vim.fn.fnameescape(base .. "/repo/sub/deeper"))
    eq(paths.project_root(), base .. "/repo", "root")
  end)
end)

test("project_root accepts a .git file (worktrees, submodules)", function()
  in_tree(function(base)
    vim.fn.writefile({ "gitdir: /elsewhere" }, base .. "/repo/.git")
    vim.cmd("cd " .. vim.fn.fnameescape(base .. "/repo/sub"))
    eq(paths.project_root(), base .. "/repo", "root")
  end)
end)

test("a leftover .grip directory is no longer a root marker", function()
  in_tree(function(base)
    vim.fn.mkdir(base .. "/repo/.git", "p")
    vim.fn.mkdir(base .. "/repo/sub/.grip", "p")
    vim.cmd("cd " .. vim.fn.fnameescape(base .. "/repo/sub/deeper"))
    eq(paths.project_root(), base .. "/repo", "root skips sub/.grip")
  end)
end)

test("grip_dir sits under stdpath('state'), outside the project", function()
  in_tree(function(base)
    vim.fn.mkdir(base .. "/repo/.git", "p")
    vim.cmd("cd " .. vim.fn.fnameescape(base .. "/repo"))
    local dir = paths.grip_dir()
    local prefix = vim.fn.stdpath("state") .. "/grip/projects/repo-"
    eq(dir:sub(1, #prefix), prefix, "prefix")
    eq(#dir, #prefix + 8, "8-character hash suffix")
    eq(dir:find(base, 1, true), nil, "not inside the project")
  end)
end)

test("grip_dir differs for two projects with the same folder name", function()
  in_tree(function(base)
    vim.fn.mkdir(base .. "/a/repo/.git", "p")
    vim.fn.mkdir(base .. "/b/repo/.git", "p")
    vim.cmd("cd " .. vim.fn.fnameescape(base .. "/a/repo"))
    local a = paths.grip_dir()
    vim.cmd("cd " .. vim.fn.fnameescape(base .. "/b/repo"))
    local b = paths.grip_dir()
    assert(a ~= b, "distinct dirs: " .. a)
  end)
end)

test("grip_dir is stable for the same project", function()
  in_tree(function(base)
    vim.fn.mkdir(base .. "/repo/.git", "p")
    vim.cmd("cd " .. vim.fn.fnameescape(base .. "/repo/sub"))
    local first = paths.grip_dir()
    vim.cmd("cd " .. vim.fn.fnameescape(base .. "/repo/sub/deeper"))
    eq(paths.grip_dir(), first, "same dir from any subdirectory")
  end)
end)

test("test runs keep state out of the developer's real state folder", function()
  eq(vim.env.XDG_STATE_HOME, vim.g.grip_test_state_home, "XDG_STATE_HOME redirected")
  local state = vim.fn.stdpath("state")
  eq(state:sub(1, #vim.g.grip_test_state_home), vim.g.grip_test_state_home, "stdpath follows it")
end)

print(string.format("\npaths_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
