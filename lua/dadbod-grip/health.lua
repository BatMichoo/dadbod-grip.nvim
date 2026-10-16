-- health.lua: :checkhealth dadbod-grip
-- Auto-discovered by Neovim. Checks Neovim version and adapter CLIs.

local M = {}

function M.check()
  vim.health.start("dadbod-grip")

  -- Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required (current version is too old)")
  end

  -- Adapter CLIs (warn = feature degraded, not broken)
  for _, cli in ipairs({ "psql", "sqlite3", "mysql", "duckdb", "sqlcmd" }) do
    if vim.fn.executable(cli) == 1 then
      vim.health.ok(cli .. " found")
    else
      vim.health.warn(cli .. " not found (required for that adapter)")
    end
  end

end

return M
