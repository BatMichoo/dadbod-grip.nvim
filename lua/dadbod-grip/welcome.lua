-- welcome.lua: the grip://welcome start screen (:GripHome, Q).

local db    = require("dadbod-grip.db")
local data  = require("dadbod-grip.data")
local view  = require("dadbod-grip.view")
local query = require("dadbod-grip.query")
local ui    = require("dadbod-grip.ui")

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripWelcome", { clear = true })

local function grip()
  return require("dadbod-grip")
end

-- ── welcome screen ────────────────────────────────────────────────────────
---Open the welcome screen (Chonk mascot + feature hints).
---Called automatically when :Grip is invoked with no arguments.
function M.open_welcome()
  -- Find existing welcome buffer
  local welcome_buf = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
        and vim.api.nvim_buf_get_name(b) == "grip://welcome" then
      welcome_buf = b
      break
    end
  end

  -- If already visible in any window, just focus it: reuse, don't replace
  if welcome_buf then
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(winid) == welcome_buf then
        vim.api.nvim_set_current_win(winid)
        return
      end
    end
  end

  -- Not visible: if called from the sidebar, find a non-sidebar window to place
  -- the welcome screen in. Query pad and grid replace their own window.
  local cur_buf = vim.api.nvim_get_current_buf()
  local cur_ft  = vim.bo[cur_buf].filetype
  local is_special = cur_ft == "grip_schema"
  if is_special then
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local wbuf  = vim.api.nvim_win_get_buf(winid)
      local wname = vim.api.nvim_buf_get_name(wbuf)
      local wft   = vim.bo[wbuf].filetype
      if wft ~= "grip_schema"
          and not (wname:match("^grip://") and wname ~= "grip://welcome") then
        vim.api.nvim_set_current_win(winid)
        break
      end
    end
  end

  if not welcome_buf then
    welcome_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(welcome_buf, "grip://welcome")
  end

  local ver = "v" .. require("dadbod-grip.version")
  -- Compact header matching help popup (help guy)
  local logo = {
    "",
    "  ╔═╦═╦═╗",
    "  ║d║b║g║  dadbod-grip " .. ver,
    "  ╚═╩═╩═╝",
    "  Editable database grids, inside Neovim.",
    "",
    "  ── Start ───────────────────────────────────────",
    "  :GripConnect  connect a database",
    "  ?             full keymap reference",
    "",
    "  ── Navigate: 1 · 2 · 3 ─────────────────────────",
    "  1   schema sidebar           2   query pad",
    "  3   table / records          Q   this screen",
    "  4   ER diagram               5-9 stats/cols/fk/idx",
    "",
    "  ── Query pad ───────────────────────────────────",
    "  q       open pad             <F5>    run SQL block",
    "  gn      notebook picker      gh      query history",
    "  gq      load saved           <C-s>   save query",
    "",
    "  ── Grid: edit ──────────────────────────────────",
    "  i/<CR>  edit cell            x     set null",
    "  o       insert row           d     delete row",
    "  a       apply changes        u     undo",
    "  gf      FK drill-down        s/S   sort / stack sort",
    "  gF      filter builder       f     quick filter",
    "  violet = modified · green = inserted · red = deleted",
    "",
    "  ── Analysis ────────────────────────────────────",
    "  gR  column distributions     gS  column stats",
    "  gD  diff tables              gE  export clipboard",
    "  gX  export to file",
    "",
    "  ── Files ───────────────────────────────────────",
    "  /path/to/file.csv   .parquet   .json   .xlsx",
    "  https://host/data.parquet      (remote via httpfs)",
    "  :Grip file.csv --write    edit + write back  (g!)",
    "  :Grip file.csv --watch    auto-refresh on timer",
    "",
    "  ── Connect ─────────────────────────────────────",
    "  postgresql://user:pass@host:5432/dbname",
    "  mysql://user:pass@host:3306/dbname",
    "  sqlite:path/to/file.db",
    "  duckdb:path/to/file.duckdb   duckdb::memory:",
    "",
    "  ────────────────────────────────────────────────",
    "",
  }

  vim.bo[welcome_buf].modifiable = true
  vim.api.nvim_buf_set_lines(welcome_buf, 0, -1, false, logo)
  vim.bo[welcome_buf].modifiable = false
  vim.bo[welcome_buf].buftype    = "nofile"
  vim.bo[welcome_buf].modified   = false
  vim.bo[welcome_buf].filetype   = "grip-welcome"

  -- Syntax highlights for welcome screen: deferred so they survive FileType autocmds
  local ns_w = vim.api.nvim_create_namespace("grip_welcome")
  vim.api.nvim_buf_clear_namespace(welcome_buf, ns_w, 0, -1)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(welcome_buf) then return end
    -- Byte-range highlight helper; matches the defaults of the (deprecated)
    -- add_highlight it replaces: priority 4096, no hl_eol.
    local function hl_range(row, group, col, end_col)
      vim.api.nvim_buf_set_extmark(welcome_buf, ns_w, row, col, {
        end_col = end_col, hl_group = group,
      })
    end
    for i, line in ipairs(logo) do
      local ln  = i - 1
      local len = #line
      if line:sub(3, 8) == "──" then
        -- Section headers and bottom separator
        hl_range(ln, "Comment", 0, len)
      elseif line:sub(3, 5) == "╔" or line:sub(3, 5) == "║" or line:sub(3, 5) == "╚" then
        -- Logo box lines (╔ ║ ╚)
        hl_range(ln, "Special", 0, len)
        local vs = line:find("dadbod-grip", 1, true)
        if vs then hl_range(ln, "Title", vs - 1, len) end
      elseif line:find("Editable database", 1, true) then
        hl_range(ln, "Comment", 0, len)
      elseif line:find("= modified", 1, true) then
        -- Color legend: extmark with high priority so it shows above any syntax highlighting
        local function hl_phrase(phrase, hl)
          local s, e = line:find(phrase, 1, true)
          if s then
            vim.api.nvim_buf_set_extmark(welcome_buf, ns_w, ln, s - 1, {
              end_col = e, hl_group = hl, priority = 200,
            })
          end
        end
        hl_phrase("violet = modified", "GripModified")
        hl_phrase("green = inserted",  "GripInserted")
        hl_phrase("red = deleted",     "GripDeleted")
      elseif line:sub(3, 7) == ":Grip" then
        -- :Grip command examples
        local s, e = line:find(":Grip%S*")
        if s then hl_range(ln, "Statement", s - 1, e) end
        s, e = line:find("%-%-%S+")
        if s then hl_range(ln, "Identifier", s - 1, e) end
      elseif line:sub(1, 2) == "  " and line:sub(3, 3) ~= " " and line:sub(3, 3) ~= "" then
        -- Keymap lines: highlight left key and right key (two-column layout)
        local _, after = line:match("^  (%S+)()")
        if after then
          hl_range(ln, "Identifier", 2, after - 1)
        end
        -- Right-column key: consistently at byte 31 (0-indexed). Guard: line must be long
        -- enough and that position must be non-space (single-column lines are too short).
        if #line >= 34 and line:sub(32, 32) ~= " " then
          local rs, re = line:find("%S+", 32)
          if rs then
            hl_range(ln, "Identifier", rs - 1, re)
          end
        end
      end
      -- ·NULL· token: highlight wherever it appears, regardless of which branch fired above
      local ns, ne = line:find("·NULL·", 1, true)
      if ns then hl_range(ln, "GripNullStaged", ns - 1, ne) end
    end
  end)

  -- Display in current window
  vim.api.nvim_win_set_buf(0, welcome_buf)

  -- Keymaps
  local function wmap(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = welcome_buf, silent = true, nowait = true, desc = desc })
  end
  local function do_connect()
    require("dadbod-grip.connections").pick()
  end
  local function cur_conn()
    local c = vim.g.db
    if type(c) ~= "string" or c == "" then c = os.getenv("DATABASE_URL") end
    return (c and c ~= "") and c or nil
  end
  wmap("q",     function() pcall(vim.api.nvim_buf_delete, welcome_buf, { force = true }) end, "Close welcome")
  wmap("<Esc>", function() pcall(vim.api.nvim_buf_delete, welcome_buf, { force = true }) end, "Close welcome")
  wmap("gc",    do_connect, "Connect to database")
  wmap("gC",    do_connect, "Connect to database")
  wmap("<C-g>", do_connect, "Connect to database")
  wmap("<CR>",  do_connect, "Connect to database")
  wmap("go",    function()
    local conn = cur_conn()
    if not conn then do_connect(); return end
    require("dadbod-grip.picker").pick_table(conn, function(t) grip().open(t, conn) end)
  end, "Open table picker")
  wmap("gb",    function()
    require("dadbod-grip.schema").toggle(cur_conn())
  end, "Schema browser")
  wmap("gG", function()
    local conn = cur_conn()
    if not conn then
      vim.notify("ER Diagram: no database connection", vim.log.levels.WARN)
      return
    end
    require("dadbod-grip.er_diagram").toggle(conn)
  end, "ER diagram")
  -- Saved queries live in .grip/queries and need no connection to browse;
  -- a bound query switches to its own connection when picked.
  wmap("gq",    function()
    require("dadbod-grip.saved").pick(function(content, _, bound_url)
      require("dadbod-grip.query_pad").open(bound_url or cur_conn(), { initial_sql = content })
    end)
  end, "Load saved query")
  wmap("?",     function() view.show_help() end, "Full keymap help")

  -- 1-9: surface navigation from welcome screen
  wmap("1", function()
    local conn = cur_conn()
    if not conn then do_connect(); return end
    require("dadbod-grip.schema").toggle(conn)
  end, "Schema sidebar")
  wmap("2", function()
    local conn = cur_conn()
    if conn then
      require("dadbod-grip.query_pad").open(conn)
    else
      do_connect()
    end
  end, "Query pad")
  wmap("3", function()
    local conn = cur_conn()
    if not conn then do_connect(); return end
    require("dadbod-grip.picker").pick_table(conn, function(t) grip().open(t, conn) end)
  end, "Table picker")
  wmap("4", function()
    local conn = cur_conn()
    if not conn then do_connect(); return end
    require("dadbod-grip.er_diagram").toggle(conn)
  end, "ER diagram")
  -- 5-9: pick a table and open it straight into that view. Slot 4 (ER diagram)
  -- is a float, not a grid view, so it is wired separately above.
  for n = 5, 9 do
    local vname = require("dadbod-grip.keymaps").TAB_VIEWS[n]
    wmap(tostring(n), function()
      local conn = cur_conn()
      if not conn then do_connect(); return end
      require("dadbod-grip.picker").pick_table(conn, function(t) grip().open(t, conn, { view = vname }) end)
    end, vname .. " view")
  end

  -- Dev secret: Chonk at the center of the grip vortex
  wmap(";", function()
    local secret = {
      "",
      "∿ ∿  dadbod-grip vortex  ∿ ∿",
      "",
      "·   · · · · · · · · · · ·   ·",
      "·   ╭───────────────────╮   ·",
      "·   │ · · · · · · · · · │   ·",
      "·   │  ╭─────────────╮  │   ·",
      "·   │  │    ▄▄▄▄▄    │  │   ·",
      "·   │  │   ▐█████▌   │  │   ·",
      "·   │  │ ▄█████████▄ │  │   ·",
      "·   │  │▐█  ◦   ◦  █▌│  │   ·",
      "·   │  │▐█  ─────  █▌│  │   ·",
      "·   │  │▐███████████▌│  │   ·",
      "·   │  │▐█  D·B·G  █▌│  │   ·",
      "·   │  │▀███████████▀│  │   ·",
      "·   │  │  ▐██▌ ▐██▌  │  │   ·",
      "·   │  │  ████ ████  │  │   ·",
      "·   │  │  ▀▀▀▀ ▀▀▀▀  │  │   ·",
      "·   │  ╰─────────────╯  │   ·",
      "·   │ · · · · · · · · · │   ·",
      "·   ╰───────────────────╯   ·",
      "·   · · · · · · · · · · ·   ·",
      "",
      "   Chonk holds the center.",
      "",
      "q to close",
      "",
    }
    local sbuf = vim.api.nvim_create_buf(false, true)
    -- Center the art as a block: all lines share the same left offset based
    -- on the widest line.  Per-line centering causes shorter lines (like
    -- "q to close") to drift right and misalign with the frame.
    -- · (U+00B7) and ∿ (U+223F) are ambiguous-width; floor of 40 pads for
    -- terminals that render them as 2-wide while ambiwidth=single counts 1.
    local max_lw = 0
    for _, l in ipairs(secret) do
      max_lw = math.max(max_lw, vim.fn.strdisplaywidth(l))
    end
    local sw      = math.max(max_lw, 40)
    local base_pad = math.max(0, math.floor((sw - max_lw) / 2))
    local lines = {}
    for _, l in ipairs(secret) do
      table.insert(lines, string.rep(" ", base_pad) .. l)
    end
    vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
    local sh   = #lines
    local swin = ui.info_float({
      buf    = sbuf,
      width  = sw,
      height = sh,
      zindex = 60,
    })
    vim.bo[sbuf].modifiable = false
    vim.bo[sbuf].buftype    = "nofile"
    local function close_secret()
      if vim.api.nvim_win_is_valid(swin) then
        vim.api.nvim_win_close(swin, true)
      end
    end
    vim.keymap.set("n", "q",     close_secret, { buffer = sbuf, silent = true })
    vim.keymap.set("n", "<Esc>", close_secret, { buffer = sbuf, silent = true })
    vim.keymap.set("n", "<CR>",  close_secret, { buffer = sbuf, silent = true })
    vim.keymap.set("n", ";",     close_secret, { buffer = sbuf, silent = true })
    vim.api.nvim_create_autocmd("WinLeave", {
      group = _ag, buffer = sbuf, once = true,
      callback = function() pcall(vim.api.nvim_win_close, swin, true) end,
    })
  end, "Dev secret")

end

return M
