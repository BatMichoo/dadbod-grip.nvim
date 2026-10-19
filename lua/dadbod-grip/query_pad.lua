-- query_pad.lua: SQL scratch buffer that pipes results into grip grids.
-- ft=sql and b:db (the connection URL) let external SQL completion plugins,
-- such as vim-dadbod-completion, attach to the pad.

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripQueryPad", { clear = true })
local _pad_bufnr = nil
-- Exact SQL text sync_query last wrote as the pad's whole content. Lets the next
-- sync tell an untouched auto-synced query (replace it) from one the user edited
-- or authored (leave it alone). nil = no auto-sync to reclaim.
local _last_synced = nil

-- The pad is a scratch buffer: never block quitting Neovim on its edits.
-- ExitPre runs before :qa/:q check for modified buffers; tab close never checks.
vim.api.nvim_create_autocmd("ExitPre", {
  group = _ag,
  callback = function()
    if _pad_bufnr and vim.api.nvim_buf_is_valid(_pad_bufnr) then
      vim.bo[_pad_bufnr].modified = false
    end
  end,
})

--- True for the hint comment older versions wrote into the pad, "-- <run
--- key>:run block or buffer  ...". The hint is virtual text now, but saved
--- queries and notebooks can still carry the old line, so it is never run.
local function _is_hint(line)
  return line:match("^%-%- %S+:run block or buffer") ~= nil
    or line:match("^%-%- C%-CR:") ~= nil
end

--- Return true when `lines` contains real SQL content.
--- Strips the hint comment (-- F5:run ...) before deciding.
--- Blank/whitespace-only remaining lines = no real content.
--- This is the single canonical check used by M.open.
local function _has_real_content(lines)
  local real = {}
  for _, line in ipairs(lines) do
    if not _is_hint(line) then
      table.insert(real, line)
    end
  end
  return table.concat(real, "\n"):match("^%s*(.-)%s*$") ~= ""
end
M._has_real_content = _has_real_content  -- exported for unit tests

local _hint_ns = vim.api.nvim_create_namespace("grip_qpad_hint")

--- Show the key hint as virtual text on line 1 while the pad has no text, and
--- clear it as soon as anything is typed or synced in.
local function _refresh_hint(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, _hint_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if table.concat(lines, "\n"):match("%S") then return end
  local run_key = (require("dadbod-grip.keymaps").get("qpad_execute") or "F5"):gsub("[<>]", "")
  vim.api.nvim_buf_set_extmark(bufnr, _hint_ns, 0, 0, {
    virt_text = { { "-- " .. run_key
      .. ":run block or buffer  gn:notebooks  go:tables  gh:hist  gq:saved  gb:schema  gC:conn",
      "Comment" } },
    virt_text_pos = "overlay",
  })
end
M._hint_ns = _hint_ns  -- exported for unit tests
M._refresh_hint = _refresh_hint

--- Highlight the words the formatter knows (DECLARE, NVARCHAR, DATETIME2, ...)
--- under Vim's regex SQL syntax, whose default Oracle dialect lacks them. Only
--- touches a buffer whose syntax is sql; tree-sitter highlighting is unaffected.
local function _add_syntax_words(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].current_syntax ~= "sql" then return end
  local words = require("dadbod-grip.format").syntax_words
  vim.api.nvim_buf_call(bufnr, function()
    -- sqloracle sets "syn case ignore", so lowercase words match any case.
    vim.cmd("syntax keyword sqlStatement " .. table.concat(words.statements, " "):lower())
    vim.cmd("syntax keyword sqlType " .. table.concat(words.types, " "):lower())
  end)
end
M._add_syntax_words = _add_syntax_words  -- exported for unit tests

--- Get or create the query pad buffer.
local function ensure_buf(url)
  if _pad_bufnr and vim.api.nvim_buf_is_valid(_pad_bufnr) then
    -- Update connection if changed
    vim.b[_pad_bufnr].db = url
    return _pad_bufnr
  end

  _pad_bufnr = vim.api.nvim_create_buf(true, false)
  _last_synced = nil  -- fresh pad has no auto-sync history to reclaim
  vim.bo[_pad_bufnr].buftype = "acwrite"
  vim.bo[_pad_bufnr].swapfile = false
  -- Before filetype is set, so the Syntax event it fires already reaches us.
  -- Syntax runs again on :syntax on / colorscheme reloads; re-add each time.
  local syn_buf = _pad_bufnr
  vim.api.nvim_create_autocmd("Syntax", {
    group = _ag,
    buffer = syn_buf,
    callback = function() _add_syntax_words(syn_buf) end,
  })
  vim.bo[_pad_bufnr].filetype = "sql"
  vim.api.nvim_buf_set_name(_pad_bufnr, "grip://query")
  vim.b[_pad_bufnr].db = url
  -- Key hint as virtual text while the pad is empty; on_lines sees every
  -- change (typing, sync_query, notebook loads), extmarks can't be set inside it.
  local bufnr = _pad_bufnr
  _refresh_hint(bufnr)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      vim.schedule(function() _refresh_hint(bufnr) end)
    end,
  })

  -- BufWriteCmd: save query with :GripSave
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group  = _ag,
    buffer = _pad_bufnr,
    callback = function()
      local saved = require("dadbod-grip.saved")
      saved.save_prompt(_pad_bufnr)
    end,
  })

  return _pad_bufnr
end

--- Run SQL from the query pad and open results in a grip grid.
--- Reuses the first unpinned grip grid window; closes unpinned extras; never
--- touches pinned results. Pass force_split=true to always open a new split.
local function run_sql(url, sql, force_split)
  if not sql or sql:match("^%s*$") then
    vim.notify("Grip: empty query", vim.log.levels.WARN)
    return
  end
  if force_split then
    local grip = require("dadbod-grip")
    grip.open(sql, url, { from_pad = true, force_split = true })
    return
  end
  -- Find ALL existing grip grid windows; skip pinned; close unpinned extras.
  local reuse_win = nil
  local view = require("dadbod-grip.view")
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local wbuf = vim.api.nvim_win_get_buf(winid)
    local is_grid = false
    -- Check session registry (definitive)
    if view._sessions[wbuf] then
      -- Skip pinned results entirely: do not reuse, do not close.
      if view._sessions[wbuf].pinned then goto continue end
      is_grid = true
    else
      -- Fallback: check buffer name pattern (grip://result, grip://tablename, etc.)
      local bname = vim.api.nvim_buf_get_name(wbuf)
      if bname:match("^grip://") and not bname:match("grip://query") and not bname:match("grip://schema") then
        is_grid = true
      end
    end
    if is_grid then
      if not reuse_win then
        reuse_win = winid
      else
        -- Close unpinned duplicate grid windows
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
    ::continue::
  end
  local grip = require("dadbod-grip")
  local run_opts = reuse_win and { reuse_win = reuse_win } or {}
  run_opts.from_pad = true
  grip.open(sql, url, run_opts)
end

--- Return the SQL inside the ```sql fence block that contains the cursor line.
--- Returns nil when the cursor is not inside a fenced SQL block.
local function _block_under_cursor(bufnr)
  local line_nr = vim.api.nvim_win_get_cursor(0)[1]  -- 1-based
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Scan backwards for opening ```sql fence
  local block_start = nil
  for i = line_nr, 1, -1 do
    local l = lines[i]
    if l:match("^```sql%s*$") or l:match("^```%s*sql%s*$") then
      block_start = i + 1
      break
    elseif l:match("^```") then
      break  -- hit a different fence going backwards: not inside a sql block
    end
  end

  if not block_start then return nil end

  -- Scan forwards for the closing ``` fence
  local block_end = nil
  for i = block_start, #lines do
    if lines[i]:match("^```%s*$") then
      block_end = i - 1
      break
    end
  end

  if not block_end or block_end < block_start then return nil end

  local block_lines = {}
  for i = block_start, block_end do
    table.insert(block_lines, lines[i])
  end
  return table.concat(block_lines, "\n")
end
M._block_under_cursor = _block_under_cursor  -- exported for unit tests

--- The buffer's real SQL: everything except the hint comment, trimmed. Blank
--- lines are kept, they are part of the SQL. Returns nil when nothing real is
--- left.
local function _buf_content(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local real = {}
  for _, line in ipairs(lines) do
    if not _is_hint(line) then
      table.insert(real, line)
    end
  end
  local content = table.concat(real, "\n"):match("^%s*(.-)%s*$")
  if content == "" then return nil end
  return content
end

--- The SQL the run key (qpad_execute) should run from the pad: the ```sql fence
--- under the cursor (notebook mode), else the whole buffer. Blank lines never
--- split the buffer: they are common inside and between statements, and running
--- only the paragraph under the cursor silently dropped the rest. To run one
--- statement out of several, select it and use the run key in visual mode.
local function _pad_sql_to_run(bufnr)
  return _block_under_cursor(bufnr) or _buf_content(bufnr)
end
M._pad_sql_to_run = _pad_sql_to_run  -- exported for unit tests

--- Scan the project root for .md and .sql files to use as notebooks.
local function scan_notebooks()
  -- Walk up from cwd to find project root (same pattern as connections.lua)
  local root = vim.fn.getcwd()
  do
    local dir = root
    for _ = 1, 10 do
      if vim.fn.isdirectory(dir .. "/.git") == 1 or vim.fn.isdirectory(dir .. "/.grip") == 1 then
        root = dir
        break
      end
      local parent = vim.fn.fnamemodify(dir, ":h")
      if parent == dir then break end
      dir = parent
    end
  end

  local seen = {}
  local files = {}
  local function add(path)
    path = vim.fn.fnamemodify(path, ":p")
    if not seen[path] and vim.fn.filereadable(path) == 1 then
      seen[path] = true
      table.insert(files, {
        path = path,
        name = vim.fn.fnamemodify(path, ":~:."),
        ext  = path:match("%.([^.]+)$") or "",
      })
    end
  end
  for _, pat in ipairs({ "notebooks/*.md", "*.md", "*.sql" }) do
    for _, p in ipairs(vim.fn.glob(root .. "/" .. pat, false, true)) do
      add(p)
    end
  end
  return files
end

--- Set up buffer-local keymaps.
local function setup_keymaps(bufnr, url)
  -- Always read the live connection from the buffer variable so keymaps stay
  -- correct after gC / gq / any other path that switches the connection.
  local function cur_url() return vim.b[bufnr].db or vim.g.db or url end

  local km = require("dadbod-grip.keymaps")
  local function kmap(action, mode, fn, opts)
    km.bind("query_pad", bufnr, action, mode, fn, opts)
  end

  -- qpad_execute: ```sql block under cursor takes priority; else the full buffer
  kmap("qpad_execute", "n", function()
    local sql = _pad_sql_to_run(bufnr)
    if sql then run_sql(cur_url(), sql) end
  end, { desc = "Grip: run query or SQL block under cursor" })

  -- qpad_execute in insert mode too (same block-or-buffer semantics)
  kmap("qpad_execute", "i", function()
    vim.cmd("stopinsert")
    local sql = _pad_sql_to_run(bufnr)
    if sql then run_sql(cur_url(), sql) end
  end, { desc = "Grip: run query" })

  -- qpad_execute_new: always open results in a new split (never reuse)
  kmap("qpad_execute_new", "n", function()
    local sql = _pad_sql_to_run(bufnr)
    if sql then run_sql(cur_url(), sql, true) end
  end, { desc = "Grip: run query in new split" })

  kmap("qpad_execute_new", "x", function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "nx", false)
    local start_line = vim.fn.line("'<")
    local end_line   = vim.fn.line("'>")
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    if #lines == 0 then return end
    run_sql(cur_url(), table.concat(lines, "\n"), true)
  end, { desc = "Grip: run selection in new split" })

  -- Visual qpad_execute: run selection (line-wise: runs all selected lines)
  kmap("qpad_execute", "x", function()
    -- feedkeys Esc to exit visual mode and set '< '> marks, then run
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "nx", false)
    local start_line = vim.fn.line("'<")
    local end_line = vim.fn.line("'>")
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    if #lines == 0 then return end
    run_sql(cur_url(), table.concat(lines, "\n"))
  end, { desc = "Grip: run selection" })

  -- qpad_save: save query
  kmap("qpad_save", "n", function()
    local saved = require("dadbod-grip.saved")
    saved.save_prompt(bufnr)
  end, { desc = "Grip: save query" })

  -- qpad_close: go to welcome screen (home)
  kmap("qpad_close", "n", function()
    require("dadbod-grip").open_welcome()
  end, { nowait = true, desc = "Grip: welcome screen" })

  -- qpad_format: format SQL in buffer (external tool cascade -> Lua fallback)
  kmap("qpad_format", "n", function()
    local fmt   = require("dadbod-grip.format")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local sql   = table.concat(lines, "\n")
    if sql:match("^%s*$") then return end
    local result = fmt.format(sql)
    if result and result ~= "" then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(result, "\n"))
    end
  end, { desc = "Grip: format SQL" })

  -- schema_browser: schema browser sidebar
  kmap("schema_browser", "n", function()
    require("dadbod-grip.schema").toggle(cur_url())
  end, { desc = "Grip: schema browser" })

  -- er_diagram: ER diagram float
  kmap("er_diagram", "n", function()
    require("dadbod-grip.er_diagram").toggle(cur_url())
  end, { desc = "Grip: ER diagram" })

  -- goto_grid: jump to main content window
  kmap("goto_grid", "n", function()
    local win = require("dadbod-grip.view").find_content_win()
    if win then vim.api.nvim_set_current_win(win) end
  end, { nowait = true, desc = "Grip: jump to grid" })

  -- go / table_picker / table_picker_alt: table picker
  local function _pick_table()
    local picker = require("dadbod-grip.picker")
    local u = cur_url()
    picker.pick_table(u, function(name)
      require("dadbod-grip").open(name, u)
    end)
  end
  kmap("table_picker_go",  "n", _pick_table, { desc = "Grip: pick table" })
  kmap("table_picker",     "n", _pick_table, { desc = "Grip: pick table" })
  kmap("table_picker_alt", "n", _pick_table, { desc = "Grip: pick table" })

  -- query_history: query history browser
  kmap("query_history", "n", function()
    local hist = require("dadbod-grip.history")
    hist.pick(function(sql_content)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(sql_content, "\n"))
      vim.bo[bufnr].modified = false
    end)
  end, { desc = "Grip: query history" })

  -- load_saved: load saved query into buffer
  kmap("load_saved", "n", function()
    local saved = require("dadbod-grip.saved")
    saved.pick(function(sql_content, _, bound_url)
      if bound_url then vim.b[bufnr].db = bound_url end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(sql_content, "\n"))
      vim.bo[bufnr].modified = false
    end)
  end, { desc = "Grip: load saved query" })

  -- open_notebook: open a .md or .sql file as a notebook in this buffer
  kmap("open_notebook", "n", function()
    M.pick_notebook()
  end, { desc = "Grip: open notebook file in query pad" })

  -- welcome: go to welcome screen (home)
  kmap("welcome", "n", function()
    require("dadbod-grip").open_welcome()
  end, { desc = "Grip: welcome screen" })

  -- help: help popup
  kmap("help", "n", function()
    require("dadbod-grip.view").show_help()
  end, { desc = "Grip: help" })

  -- palette: command palette
  kmap("palette", "n", function()
    require("dadbod-grip.palette").open("query")
  end, { desc = "Grip: command palette" })

  -- connections / connections_alt: switch database connection
  local function _pick_conn()
    require("dadbod-grip.connections").pick()
  end
  kmap("connections",     "n", _pick_conn, { desc = "Grip: switch connection" })
  kmap("connections_alt", "n", _pick_conn, { desc = "Grip: switch connection" })

  -- ── tab view keymaps (1-9) ───────────────────────────────────────────────
  -- 1-3: surface navigation  4=ER diagram float  5-9: table-depth views

  -- tab_1: schema sidebar
  kmap("tab_1", "n", function()
    require("dadbod-grip.view").close_all_floats(nil)
    require("dadbod-grip.schema").toggle(cur_url())
  end, { desc = "Grip: schema sidebar" })

  -- tab_2: query history (secondary, already in query pad)
  kmap("tab_2", "n", function()
    require("dadbod-grip.view").close_all_floats(nil)
    require("dadbod-grip.history").pick(function(sql_content)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(sql_content, "\n"))
      vim.bo[bufnr].modified = false
    end)
  end, { desc = "Grip: query history" })

  -- tab_3: jump to grid, or table picker if no grid is open
  kmap("tab_3", "n", function()
    local view_mod = require("dadbod-grip.view")
    view_mod.close_all_floats(nil)
    local win = view_mod.find_content_win()
    if win then
      vim.api.nvim_set_current_win(win)
    else
      local u = cur_url()
      require("dadbod-grip.picker").pick_table(u, function(name)
        require("dadbod-grip").open(name, u)
      end)
    end
  end, { desc = "Grip: jump to grid" })

  -- tab_4-9: ER diagram float or jump to grid + switch to that view
  for n = 4, 9 do
    local view_name = km.TAB_VIEWS[n]
    kmap("tab_" .. n, "n", function()
        local view_mod = require("dadbod-grip.view")
        view_mod.close_all_floats(nil)
        if view_name == "er_diagram" then
          require("dadbod-grip.er_diagram").toggle(cur_url())
          return
        end
        local win = view_mod.find_content_win()
        if win then
          local gbuf = vim.api.nvim_win_get_buf(win)
          vim.api.nvim_set_current_win(win)
          view_mod.switch_view(gbuf, view_name)
        else
          local u = cur_url()
          require("dadbod-grip.picker").pick_table(u, function(name)
            require("dadbod-grip").open(name, u)
          end)
        end
      end, { desc = "Grip: view " .. view_name })
  end
end

--- Open the query pad.
--- @param url string connection URL
--- @param opts? { initial_sql?: string }
function M.open(url, opts)
  opts = opts or {}

  if not url then
    local db_mod = require("dadbod-grip.db")
    url = db_mod.get_url()
    if not url then
      vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
      return
    end
  end

  local bufnr = ensure_buf(url)
  setup_keymaps(bufnr, url)

  -- Find or create a window for the pad
  local pad_win = nil
  local welcome_win, welcome_view
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not welcome_win and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid)) == "grip://welcome" then
      welcome_win = winid
      welcome_view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
    end
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      pad_win = winid
      break
    end
  end

  if not pad_win then
    -- When schema sidebar is open, open in the right-side area (not full-width bottom)
    local schema = require("dadbod-grip.schema")
    if schema.is_open() then
      -- Find the first non-sidebar window
      local target_win = nil
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local wbuf = vim.api.nvim_win_get_buf(winid)
        local ft = vim.bo[wbuf].filetype
        if ft ~= "grip_schema" then
          target_win = winid
          break
        end
      end
      if target_win then
        vim.api.nvim_set_current_win(target_win)
        -- If the target has a grip grid or welcome screen, split above it instead of replacing
        local target_buf = vim.api.nvim_win_get_buf(target_win)
        local target_name = vim.api.nvim_buf_get_name(target_buf)
        local view_mod = require("dadbod-grip.view")
        if view_mod._sessions[target_buf] or target_name == "grip://welcome" then
          vim.cmd("aboveleft split")
          pad_win = vim.api.nvim_get_current_win()
          vim.api.nvim_win_set_buf(pad_win, bufnr)
          vim.api.nvim_win_set_height(pad_win, math.max(10, math.floor(vim.o.lines * 0.4)))
        else
          vim.api.nvim_win_set_buf(target_win, bufnr)
          pad_win = target_win
        end
      else
        vim.cmd("botright split")
        pad_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(pad_win, bufnr)
        vim.api.nvim_win_set_height(pad_win, math.max(10, math.floor(vim.o.lines * 0.4)))
      end
    else
      -- Find a grip grid or welcome window and open above it
      local view_mod = require("dadbod-grip.view")
      local grid_win = nil
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local wbuf = vim.api.nvim_win_get_buf(winid)
        local wname = vim.api.nvim_buf_get_name(wbuf)
        if view_mod._sessions[wbuf] or wname == "grip://welcome" then
          grid_win = winid
          break
        end
      end
      if grid_win then
        vim.api.nvim_set_current_win(grid_win)
        vim.cmd("aboveleft split")
      else
        vim.cmd("botright split")
      end
      pad_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(pad_win, bufnr)
      vim.api.nvim_win_set_height(pad_win, math.max(10, math.floor(vim.o.lines * 0.4)))
    end

    -- splitkeep=screen can scroll the welcome out of its opening view.
    if welcome_win then
      vim.api.nvim_win_call(welcome_win, function() vim.fn.winrestview(welcome_view) end)
    end
  end

  vim.api.nvim_set_current_win(pad_win)

  -- Pre-fill if requested and buffer has no real SQL content
  if opts.initial_sql then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if not _has_real_content(lines) then
      local sql_lines = vim.split(opts.initial_sql, "\n")
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sql_lines)
      vim.bo[bufnr].modified = false
    end
  end
end

--- Silently sync the query pad with the SQL of the grid the user is now looking at.
--- Two callers, both passing query.clean_sql(spec):
---   • init.open() — a table or query opened from outside the pad (sidebar, table
---     picker, :Grip); skipped when the query came from the pad itself;
---   • view._sync_pad() — FK navigation swapped the spec inside an existing grid
---     (gf, gm, <C-o> back), which never reaches init.open().
--- No-op if the pad buffer doesn't exist yet.
--- Behaviour:
---   • empty/hint-only pad → populate it;
---   • pad holds only the query we auto-synced last (user didn't touch it) →
---     replace it, so plain table-hopping keeps one live query;
---   • pad holds anything the user wrote or edited → leave it alone. Browsing
---     never adds queries below the user's SQL, so the run key runs exactly what they wrote.
function M.sync_query(sql_text)
  if not _pad_bufnr or not vim.api.nvim_buf_is_valid(_pad_bufnr) then return end
  if not sql_text or sql_text:match("^%s*$") then return end
  local content = _buf_content(_pad_bufnr)
  if content ~= nil and content ~= _last_synced then
    _last_synced = nil  -- user-owned: never reclaim it
    return
  end
  vim.bo[_pad_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(_pad_bufnr, 0, -1, false, vim.split(sql_text, "\n"))
  _last_synced = sql_text
  vim.bo[_pad_bufnr].modified = false
end

--- Get the current query pad content (nil if empty or hint-only).
function M.get_content()
  if not _pad_bufnr or not vim.api.nvim_buf_is_valid(_pad_bufnr) then return nil end
  return _buf_content(_pad_bufnr)
end

--- Open a file picker for .md and .sql notebooks and load the chosen file
--- into the query pad buffer. Accessible from grid, query pad, and sidebar via gn.
function M.pick_notebook()
  local files = scan_notebooks()
  if #files == 0 then
    vim.notify("Grip: no notebooks found (*.md, *.sql in project root)", vim.log.levels.INFO)
    return
  end
  require("dadbod-grip.grip_picker").open({
    title = "Notebooks",
    items = files,
    display = function(f) return f.name end,
    preview = function(f)
      local ok, lines = pcall(vim.fn.readfile, f.path)
      return ok and lines or { "(unreadable)" }
    end,
    on_select = function(f)
      -- Ensure the pad is open and visible
      local db_url = vim.b[_pad_bufnr or 0] and vim.b[_pad_bufnr or 0].db
        or vim.g.db
        or require("dadbod-grip.db").get_url()
      if db_url then M.open(db_url) end
      vim.schedule(function()
        local pad = _pad_bufnr
        if not pad or not vim.api.nvim_buf_is_valid(pad) then return end
        local ok, lines = pcall(vim.fn.readfile, f.path)
        if not ok then
          vim.notify("Grip: could not read " .. f.name, vim.log.levels.WARN)
          return
        end
        vim.bo[pad].modifiable = true
        vim.api.nvim_buf_set_lines(pad, 0, -1, false, lines)
        vim.bo[pad].modified = false
        vim.notify("Grip: loaded " .. f.name, vim.log.levels.INFO)
      end)
    end,
  })
end

--- Testing hook: override the internal pad buffer reference.
--- NOT for production use.
function M._set_pad_bufnr(bufnr)
  _pad_bufnr = bufnr
  _last_synced = nil  -- a swapped-in pad carries no auto-sync history
end

--- Read-only access to the current pad buffer number. Nil if no pad is open.
function M.get_pad_bufnr()
  return _pad_bufnr
end

return M
