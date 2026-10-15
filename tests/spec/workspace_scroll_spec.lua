-- Exercise splitkeep with a real attached Neovim grid, including 0.10's
-- cursor adjustment when a query pad is split above the welcome screen.
dofile("tests/minimal_init.lua")

local pass, fail = 0, 0
for _, layout in ipairs({ { false, false }, { true, false }, { false, true }, { true, true } }) do
  local sidebar, duplicate = unpack(layout)
  for _, scrolled in ipairs({ false, true }) do
    local name = string.format("query split preserves %s welcome with sidebar=%s, duplicate=%s",
      scrolled and "scrolled" or "fresh", tostring(sidebar), tostring(duplicate))
    local child = vim.fn.jobstart({ vim.g.grip_test_progpath, "--embed", "--headless",
      "-i", "NONE", "-u", "tests/minimal_init.lua" }, { rpc = true })
    local ok, err = pcall(function()
      vim.fn.rpcrequest(child, "nvim_ui_attach", 100, 36, { rgb = true })
      local before = vim.fn.rpcrequest(child, "nvim_exec_lua", [[
        local sidebar, scrolled, duplicate = ...
        vim.o.splitkeep, vim.o.scrolloff, vim.o.wrap = "screen", 4, false
        local grip = require("dadbod-grip")
        grip.setup({ connections_path = vim.fn.tempname() })
        if sidebar then require("dadbod-grip.schema").toggle("sqlite:tests/seed_sqlite.db") end
        grip.open_welcome()
        vim.wait(20)
        if scrolled then vim.fn.winrestview({ lnum = 14, topline = 10 }) end
        if duplicate then vim.cmd("vsplit") end
        vim.cmd("redraw")
        return { cursor = vim.api.nvim_win_get_cursor(0), view = vim.fn.winsaveview() }
      ]], { sidebar, scrolled, duplicate })
      local after = vim.fn.rpcrequest(child, "nvim_exec_lua", [[
        local welcome = vim.api.nvim_get_current_win()
        require("dadbod-grip.query_pad").open("sqlite:tests/seed_sqlite.db")
        vim.cmd("redraw")
        return { win = welcome, cursor = vim.api.nvim_win_get_cursor(welcome),
          view = vim.api.nvim_win_call(welcome, vim.fn.winsaveview),
          focused = vim.api.nvim_buf_get_name(0) }
      ]], {})
      assert(vim.deep_equal(after.cursor, before.cursor),
        "welcome cursor moved: " .. vim.inspect({ before.cursor, after.cursor }))
      assert(after.view.topline == before.view.topline,
        string.format("welcome topline moved: %d -> %d", before.view.topline, after.view.topline))
      assert(after.focused == "grip://query", "query pad must retain focus")
      local function check_cycle(resize)
        if resize then vim.fn.rpcrequest(child, "nvim_ui_try_resize", 80, 28) end
        local cycle = vim.fn.rpcrequest(child, "nvim_exec_lua", [[
          local welcome = ...
          local grip = require("dadbod-grip")
          local pad = require("dadbod-grip.query_pad")
          local function snapshot()
            vim.cmd("redraw")
            return { cursor = vim.api.nvim_win_get_cursor(welcome),
              view = vim.api.nvim_win_call(welcome, vim.fn.winsaveview) }
          end
          local start = snapshot()
          pad.open("sqlite:tests/seed_sqlite.db")
          local repeated = snapshot()
          vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
          grip.open_welcome()
          local closed = snapshot()
          pad.open("sqlite:tests/seed_sqlite.db")
          local reopened = snapshot()
          return { start, repeated, closed, reopened }
        ]], { after.win })
        for _, pair in ipairs({ { 1, 2 }, { 3, 4 } }) do
          local first, second = cycle[pair[1]], cycle[pair[2]]
          assert(vim.deep_equal(first.cursor, second.cursor), "repeat/reopen moved welcome cursor")
          assert(first.view.topline == second.view.topline, "repeat/reopen scrolled welcome")
        end
      end
      check_cycle(false)
      check_cycle(true)
    end)
    vim.fn.jobstop(child)
    if ok then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
  end
end

print(string.format("workspace_scroll_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
