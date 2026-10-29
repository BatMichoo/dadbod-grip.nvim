-- paths.lua: per-project storage locations.
-- Single source of truth for where grip keeps per-project state
-- (history.jsonl, filters.json, queries/, connections.json). The state lives
-- under stdpath("state") rather than inside the repo, so nothing has to be
-- added to .gitignore.

local M = {}

--- Find project root by walking up from cwd looking for .git.
--- Falls back to cwd when no marker is found.
--- @return string absolute directory path
function M.project_root()
  local dir = vim.fn.getcwd()
  while true do
    if vim.fn.isdirectory(dir .. "/.git") == 1 or vim.fn.filereadable(dir .. "/.git") == 1 then
      return dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return vim.fn.getcwd()
end

--- The project's state directory (not created):
--- stdpath("state")/grip/projects/<root name>-<hash of root path>.
--- @return string
function M.grip_dir()
  local root = M.project_root()
  local name = vim.fn.fnamemodify(root, ":t"):gsub("[^%w%._-]", "_")
  if name == "" then name = "root" end
  local hash = vim.fn.sha256(root):sub(1, 8)
  return vim.fn.stdpath("state") .. "/grip/projects/" .. name .. "-" .. hash
end

--- Create a directory (and parents) if it does not exist yet.
--- @param dir string
function M.ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

return M
