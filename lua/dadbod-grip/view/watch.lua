-- view/watch.lua: re-run a grid's query on a timer (the watch_ms option).

local M = {}

local function view() return require("dadbod-grip.view") end

--- Start a watch timer for bufnr at interval ms. Stops any existing timer.
function M.start(bufnr, ms)
  local session = view()._sessions[bufnr]
  if not session then return end
  -- Stop existing timer if any
  if session.watch_timer then
    pcall(function() session.watch_timer:stop(); session.watch_timer:close() end)
    session.watch_timer = nil
  end
  session.watch_ms = ms
  local timer = vim.uv.new_timer()
  session.watch_timer = timer
  timer:start(ms, ms, vim.schedule_wrap(function()
    local s = view()._sessions[bufnr]
    if not s or not vim.api.nvim_buf_is_valid(bufnr) then
      pcall(function() timer:stop(); timer:close() end)
      return
    end
    -- Skip refresh when there are staged mutations pending
    local staged = s.state and (
      next(s.state.changes or {}) or
      next(s.state.deleted or {}) or
      next(s.state.inserted or {})
    )
    if staged then return end
    if s.on_refresh then s.on_refresh(bufnr) end
  end))
  require("dadbod-grip.view.winbar")._update_winbar(bufnr)
end

--- Stop the watch timer for bufnr.
function M.stop(bufnr)
  local session = view()._sessions[bufnr]
  if not session then return end
  if session.watch_timer then
    pcall(function() session.watch_timer:stop(); session.watch_timer:close() end)
    session.watch_timer = nil
  end
  session.watch_ms = nil
  require("dadbod-grip.view.winbar")._update_winbar(bufnr)
end

return M
