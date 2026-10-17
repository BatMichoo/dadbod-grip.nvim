-- view/fk_nav.lua: in-place navigation inside a grid — reverse FK jumps and
-- keeping the query pad in step with the spec on screen.

local sql  = require("dadbod-grip.sql")
local db   = require("dadbod-grip.db")
local data = require("dadbod-grip.data")
local ui   = require("dadbod-grip.ui")
local qmod = require("dadbod-grip.query")

local M = {}

local function view()
  return require("dadbod-grip.view")
end

-- ── in-place navigation: query pad sync ───────────────────────────────────
--- Sync the query pad with a spec the grid just switched to.
--- init.open() syncs the pad for grids that open from outside it (sidebar, table
--- picker, :Grip). FK navigation instead swaps the spec inside an existing grid
--- and never goes through init.open(), so each in-place jump must sync itself —
--- otherwise the pad keeps advertising the table you started from, three FK hops
--- ago. clean_sql() keeps this honest: the pinned FK clause is included (the pad
--- describes the rows on screen) while sorts, user filters and pagination are not.
function M._sync_pad(spec)
  if not spec then return end
  require("dadbod-grip.query_pad").sync_query(qmod.clean_sql(spec))
end

-- ── reverse FK navigation ─────────────────────────────────────────────────
--- Jump from the current row to the rows in other tables that reference it.
--- Mirror of grid_fk_follow: same nav stack, query-spec, and render machinery.
--- Module-level (not a keymap closure) so tests can drive it directly.
function M._fk_referencing(bufnr)
  local session = view()._sessions[bufnr]
  if not session or not session.state or not session.state.table_name then
    vim.notify("Reverse FK navigation requires a table name", vim.log.levels.INFO)
    return
  end
  local tbl = session.state.table_name

  -- Compute the reverse-FK map once per session per table (mirrors fk_cache).
  if not session.rev_fk_cache then session.rev_fk_cache = {} end
  if not session.rev_fk_cache[tbl] then
    local refs, rev_err = db.get_referencing_foreign_keys(tbl, session.state.url)
    if rev_err and (not refs or #refs == 0) then
      vim.notify("Reverse FK lookup failed: " .. rev_err, vim.log.levels.WARN)
      return
    end
    session.rev_fk_cache[tbl] = refs or {}
  end
  local refs = session.rev_fk_cache[tbl]
  if #refs == 0 then
    vim.notify("No tables reference " .. tbl, vim.log.levels.INFO)
    return
  end

  local cell = view().get_cell(bufnr)
  if not cell then
    vim.notify("Move cursor to a data row", vim.log.levels.INFO)
    return
  end

  -- Source column: the cursor column if some FK references it,
  -- otherwise the row's single-column primary key.
  local referenced = {}
  for _, r in ipairs(refs) do referenced[r.ref_column] = true end
  local src_col, src_val
  if referenced[cell.col_name] then
    src_col, src_val = cell.col_name, cell.value
  else
    local pks = session.state.pks or {}
    if #pks ~= 1 then
      vim.notify(
        "No referenced column at cursor and no single-column primary key",
        vim.log.levels.INFO)
      return
    end
    src_col = pks[1]
    src_val = data.effective_value(session.state, cell.row_idx, src_col)
  end

  local candidates = {}
  for _, r in ipairs(refs) do
    if r.ref_column == src_col then table.insert(candidates, r) end
  end
  if #candidates == 0 then
    vim.notify("No tables reference " .. tbl .. "." .. src_col, vim.log.levels.INFO)
    return
  end
  -- effective_value returns nil for NULL originals, but staged INSERT rows
  -- (insert_row_with_values: GripImport, INSERT mutation preview) can carry a
  -- raw "" that it passes through — keep treating "" as NULL here.
  if src_val == nil or src_val == "" then
    vim.notify("NULL value: cannot find referencing rows", vim.log.levels.INFO)
    return
  end

  local function jump(ref)
    if ref.composite then
      vim.notify(
        "Composite foreign key " .. ref.table .. " (" .. ref.column ..
        "): reverse navigation not supported", vim.log.levels.INFO)
      return
    end

    -- Push current state to nav stack (shared with forward FK navigation)
    if not session.nav_stack then session.nav_stack = {} end
    table.insert(session.nav_stack, {
      query_spec = session.query_spec,
      state = session.state,
      table_name = tbl,
      cursor_pos = vim.api.nvim_win_get_cursor(0),
    })

    -- Build query for the referencing rows
    local ref_spec = qmod.new_table(ref.table, session.query_spec and session.query_spec.limit)
    -- Pinned: this clause is what the grid IS ("the rows referencing that row"),
    -- so F/X must not drop it and the [filtered] badge must not claim the user
    -- filtered anything.
    ref_spec = qmod.add_filter(ref_spec,
      sql.quote_ident(ref.column) .. " = " .. sql.quote_value(src_val),
      { pinned = true })
    local ref_sql = qmod.build_sql(ref_spec)

    -- Up to three round-trips (rows, columns, PKs) behind one spinner: without
    -- it the jump is a dead editor for as long as the connection takes.
    -- One table out, never a bare `nil, err`: ui.blocking() forwards through
    -- table.unpack, which drops everything after a leading nil.
    local row_count
    local fetched = ui.blocking("  querying " .. ref.table .. "...", function()
      local res, qerr = db.query(ref_sql, session.state.url)
      if qerr then return { err = qerr } end

      -- Empty result: fetch columns from schema (same guard as grid_fk_follow)
      if #res.columns == 0 then
        local col_info = db.get_column_info(ref.table, session.state.url)
        if col_info then
          for _, ci in ipairs(col_info) do
            table.insert(res.columns, ci.column_name)
          end
        end
      end

      -- Fetch PKs for the referencing table
      res.primary_keys = db.get_primary_keys(ref.table, session.state.url) or {}
      -- FK navigation lands on a different table but the same connection, so a
      -- read-only one stays read-only here too.
      res.readonly = db.is_readonly(session.state.url)
      res.table_name = ref.table
      res.url = session.state.url
      res.sql = ref_sql
      row_count = #res.rows
      return { result = res }
    end)
    if not fetched or not fetched.result then
      table.remove(session.nav_stack) -- pop on failure
      vim.notify("Reverse FK query failed: " .. tostring((fetched and fetched.err) or "unknown error"),
        vim.log.levels.WARN)
      return
    end
    local result = fetched.result

    local new_state = data.new(result)
    session.query_spec = ref_spec
    view().render(bufnr, new_state)
    view()._sync_pad(ref_spec)
    vim.notify(
      ref.table .. "." .. ref.column .. " ← " .. tbl ..
      " (" .. row_count .. (row_count == 1 and " row)" or " rows)"),
      vim.log.levels.INFO)
  end

  if #candidates == 1 then
    jump(candidates[1])
    return
  end
  require("dadbod-grip.grip_picker").pick({
    title = "Tables referencing " .. tbl .. "." .. src_col,
    items = candidates,
    display = function(c)
      return c.table .. "." .. c.column .. (c.composite and " (composite)" or "")
    end,
    on_select = jump,
  })
end

return M
