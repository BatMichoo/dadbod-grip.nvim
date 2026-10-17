-- view/help.lua: the full keymap help popup (?), shared by grid, query pad and sidebar.

local ui      = require("dadbod-grip.ui")
local VERSION = require("dadbod-grip.version")

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripHelp", { clear = true })

--- Open the full help popup. Called from grid, query pad, and schema sidebar.
--- opts.readonly = true → show read-only notice instead of editing section.
function M.show_help(opts)
  opts = opts or {}
  local grip_win = vim.api.nvim_get_current_win()
  local ro = opts.readonly
  local help = {
      "",
      "    D   ███████╗███████╗██╗███████╗",
      "    A  ██╔═════╝██╔══██║██║██╔══██║",
      "    D  ██║  ███╗██████╔╝██║███████║",
      "    b  ██║   ██║██╔══██╗██║██╔════╝",
      "    o  ╚██████╔╝██║  ██║██║██║",
      "    d   ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝",
      "",
      " ───────────────────────────────────────────",
      "",
      "  Navigation",
      "  j/k       Move between rows",
      "  h/l       Move cursor within row",
      "  w/b       Next / previous column",
      "  Tab/S-Tab Next / previous column",
      "  gg        First data row",
      "  G         Last data row",
      "  0/^       First column",
      "  -         Hide column under cursor",
      "  g-        Restore all hidden columns",
      "  gH        Column visibility picker",
      "  =         Cycle column width: compact → expanded → reset",
      "  $         Last column",
      "  e         Next column, land at end of cell",
      "  {/}       Prev / next modified row",
      "  <CR> / i  Edit cell under cursor (JSON cells: pretty-printed in editor)",
      "  gB        Open cell value in split buffer (JSON: ft=json; :w stages)",
      "  gU        Set current column across all visible rows",
      "  K         Row view (vertical transpose; JSON cells auto-expanded)",
      "  gK        JSON tree drilldown (expand/collapse keys, yank value or JSONPath)",
      "  y         Yank cell value to clipboard",
      "  Y         Yank row as CSV",
      "  gY        Yank entire table as CSV",
      "  gy        Yank table as Markdown pipe table",
      "",
      "  Sort / Filter",
      "  s         Toggle sort on column (ASC→DESC→off)",
      "  S         Stack sort on column (stackable: press S on multiple cols for ▲1 ▼2 ▲3)",
      "  f         Quick filter by cell value",
      "  gn        Filter: column IS NULL",
      "  gF        Filter builder (=, !=, >, <, LIKE, IN, BETWEEN, NULL, NOT NULL)",
      "  <C-f>     Freeform WHERE clause filter",
      "            ↳ e.g.: status = 'active'",
      "            ↳ e.g.: created_at > '2024-01-01' AND amount > 100",
      "            ↳ e.g.: name ILIKE '%alice%'",
      "            ↳ F clears all filters",
      "  F         Clear all filters",
      "  gp        Load saved filter preset",
      "  gP        Save current filter as preset",
      "  X         Reset view (clear sort/filter)",
      "",
      "  FK Navigation",
      "  gf        Follow foreign key under cursor",
      "  gm        Open rows that reference the current row",
      "  <C-o>     Go back in FK navigation stack",
      "",
      "  Analysis & Export",
      "  ga        Aggregate selected cells (visual mode)",
      "  gS        Column statistics popup",
      "  gR        Table profile (sparkline distributions)",
      "  gV        Show CREATE TABLE DDL",
      "  gQ        Explain current query plan",
      "  gx        Open URL in current cell (http/https/ftp)",
      "  gD        Diff against another table",
      "  gE        Export to clipboard (CSV, TSV, JSON, SQL, Markdown, Grip Table)",
      "  gX        Export to file (csv/json/sql)  :GripExport",
      "",
      "  Tab Views (1-9)",
      "  Surface navigation (press again = secondary action):",
      "  1         Schema sidebar  (again: connections picker)",
      "  2         Query pad       (again: query history)",
      "  3         Grid / records  (again: table picker)",
      "  Depth views (consistent across grid, sidebar, query pad):",
      "  4         ER diagram: all tables and FK relationships",
      "  5         Column Stats: count, nulls%, distinct, min, max",
      "  6         Columns: name, type, nullable, default, key",
      "  7         Foreign Keys: outbound and inbound",
      "  8         Indexes: name, type, columns covered",
      "  9         Constraints: CHECK, UNIQUE, NOT NULL",
      "  (explain query plan: gQ)",
      "",
      "  Schema & Workflow",
      "  go/gT/gt  Pick table (floating picker)",
      "  gb        Schema browser (toggle/focus)",
      "  gG        ER diagram: focus current table neighborhood",
      "            ↳ <CR> on a table header to open that table",
      "            ↳ press gG again from the grid to return to the map",
      "  gO        Open as editable table (read-only → table)",
      "  gC/<C-g>  Switch database connection",
      "  gW        Toggle watch mode (auto-refresh on timer)",
      "  gL        Pin / unpin result (pinned: survives next query execution)",
      "  gJ        Result switcher (all open results, pick to focus)",
      "  g!        Toggle write mode (apply overwrites file)",
      "  Q         Welcome screen (home)",
      "  q         Open query pad",
      "  gq        Load saved query",
      "  gh        Query history browser",
      "  :GripAttach  Attach external DB to DuckDB session",
      "  :GripDetach  Detach attached database",
      "  :GripOpen    Open file/HTTPS/s3:// without saving to connections",
      "",
      "  Actions",
      "  r         Refresh (re-run query)",
      "  :q        Close grip buffer",
      "  ?         Toggle this help",
    }
    if ro then
      vim.list_extend(help, {
        "",
        " ┌─ Read-Only Mode ────────────────────────┐",
        " │ This table has no primary key detected.  │",
        " │ Grip needs a PK to build WHERE clauses   │",
        " │ for UPDATE and DELETE statements.         │",
        " │ Without a PK, edits cannot target a      │",
        " │ specific row safely.                      │",
        " └──────────────────────────────────────────┘",
        "",
        "  Connections",
        "  gc / gC     connection picker (* ok  o unknown  x fail)",
        "  T           retest file connection health (in picker)",
        "  s           save local file as named connection (in picker)",
        "",
        " ───────────────────────────────────────────",
        "",
        "  ╔═╦═╦═╗",
        '  ║d║b║g║  dadbod-grip v' .. VERSION,
        "  ╚═╩═╩═╝",
        "  docs: jorypestorious.com/dadbod-grip-web",
      })
    else
      vim.list_extend(help, {
        "",
        "  Editing",
        "  <CR> / i  Edit cell under cursor",
        "  gB        Open cell value in split buffer (:w stages the change)",
        "  x         Set cell to NULL",
        "  p         Paste clipboard into cell",
        "  P         Paste multi-line into rows",
        "  o         Insert new row after cursor",
        "  c         Clone row (copy values, clear PKs)",
        "  d         Toggle delete on current row",
        "  u         Undo last edit (multi-level)",
        "  <C-r>     Redo",
        "  U         Undo all (reset to original)",
        "  a         Apply all staged changes to DB",
        "",
        "  Batch Edit (visual mode)",
        "  e         Set selected cells to same value",
        "  d         Toggle delete on selected rows",
        "  x         Set selected cells to NULL",
        "  y         Yank selected cells in column",
        "  gd        Diff exactly 2 rows (highlights differing cells)",
        "  K         Stack selected rows in one float (vertical inspect)",
        "",
        "  Inspection",
        "  gs        Preview staged SQL",
        "  gc        Copy staged SQL to clipboard",
        "  gi        Table info (columns, types, PKs)",
        "  gI        Table properties (full detail)",
        "  gN        Rename column under cursor",
        "  ge        Explain cell under cursor",
        "",
        "  Advanced",
        "  gl        Toggle live SQL preview",
        "  T         Toggle column type annotations",
        "",
        "  Colors: modified=violet  deleted=red  inserted=green",
        "          negative=red  true=green  false=red",
        "          past-date=dim  url=underline",
        "",
        "  Connections",
        "  gc / gC     connection picker (* ok  o unknown  x fail)",
        "  T           retest file connection health (in picker)",
        "  s           save local file as named connection (in picker)",
        "",
        " ───────────────────────────────────────────",
        "",
        "  ╔═╦═╦═╗",
        '  ║d║b║g║  dadbod-grip v' .. VERSION,
        "  ╚═╩═╩═╝",
        "  docs: jorypestorious.com/dadbod-grip-web",
      })
    end
    local max_w = 0
    for _, line in ipairs(help) do max_w = math.max(max_w, #line) end
    max_w = math.max(max_w + 2, 46)
    local popup_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, help)
    -- Full help highlights: logo, section headers, keymap keys, separators, RO box, portal
    local ns_h = vim.api.nvim_create_namespace("grip_help_hl")
    local function hadd(ln, group, s, e)
      -- Missing or negative end column means "to the end of the line": add_highlight
      -- took col_end = -1 for that, set_extmark wants end_row = ln + 1 / end_col = 0.
      local ext = { hl_group = group }
      if e and e >= 0 then ext.end_col = e else ext.end_row, ext.end_col = ln + 1, 0 end
      vim.api.nvim_buf_set_extmark(popup_buf, ns_h, ln, s or 0, ext)
    end
    local in_ro_box = false
    for i, line in ipairs(help) do
      local ln = i - 1
      if    line:match("^    %a") then                                           hadd(ln, "Special")
      elseif line:find("╔═╦") or line:find("║d║") or line:find("╚═╩") then     hadd(ln, "Special")
      elseif line:find("┌─") then    in_ro_box = true;  hadd(ln, "DiagnosticWarn")
      elseif in_ro_box then          hadd(ln, "DiagnosticWarn"); if line:find("└──") then in_ro_box = false end
      elseif line:match("^%s+[─═]") then hadd(ln, "Comment")
      elseif line:find("\xe2\x86\xb3") then hadd(ln, "Comment")   -- ↳ continuation
      elseif line:find("Colors:")    then hadd(ln, "Comment")
      elseif line:match("^  %S") and not line:find("%s%s", 3) then  hadd(ln, "Title")
      elseif line:match("^  %S") then
        local key_end = line:find("%s%s", 3)
        if key_end then hadd(ln, "Identifier", 2, key_end - 1) end
      end
    end
    local win = ui.info_float({
      buf = popup_buf,
      width = max_w,
      height = #help,
      title = " Help ",
      title_pos = "center",
      zindex = 50,
    })
    local function close()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end

    vim.api.nvim_create_autocmd("WinLeave", {
      group  = _ag,
      buffer = popup_buf,
      once = true,
      callback = function() vim.schedule(close) end,
    })

    for _, key in ipairs({ "q", "?", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        close()
        if vim.api.nvim_win_is_valid(grip_win) then
          vim.api.nvim_set_current_win(grip_win)
        end
      end, { buffer = popup_buf })
    end

    vim.keymap.set("n", "gx", function()
      local url = "https://jorypestorious.com/dadbod-grip-web"
      if vim.ui.open then
        vim.ui.open(url)
      elseif vim.fn.has("mac") == 1 then
        vim.fn.jobstart({ "open", url }, { detach = true })
      else
        vim.fn.jobstart({ "xdg-open", url }, { detach = true })
      end
    end, { buffer = popup_buf, desc = "Open docs" })
end

return M
