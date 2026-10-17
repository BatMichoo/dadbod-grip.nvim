-- query.lua: pure query composition.
-- No I/O. No state. No side effects. Values in, strings out.
-- Query spec is a plain Lua table (a value, not an object).

local sql_mod = require("dadbod-grip.sql")
local esc = sql_mod.escape_literal

local M = {}

-- ── deep copy (local, same pattern as data.lua) ─────────────────────────
local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local copy = {}
  for k, v in pairs(t) do copy[k] = deep_copy(v) end
  return copy
end

-- ── constructors ─────────────────────────────────────────────────────────

--- Create a spec for a table query. `limit` caps the rows Grip asks for, as
--- SSMS's "Select Top N Rows" does; nil or 0 asks for every row.
function M.new_table(table_name, limit)
  return {
    table_name = table_name,
    base_sql   = nil,
    sorts      = {},
    filters    = {},
    limit      = (limit and limit > 0) and limit or nil,
    is_raw     = false,
  }
end

--- Create a spec for a raw SELECT/WITH query. It runs exactly as written: the
--- user's SQL decides how many rows come back. `limit` is only for SQL Grip
--- writes itself (opening a file), which gets the same cap as a table.
function M.new_raw(sql_str, limit)
  -- Strip trailing semicolons: sorting or filtering wraps it in a subquery
  local cleaned = sql_str and sql_str:gsub(";%s*$", "") or sql_str
  return {
    table_name = nil,
    base_sql   = cleaned,
    sorts      = {},
    filters    = {},
    limit      = (limit and limit > 0) and limit or nil,
    is_raw     = true,
  }
end

-- ── sort modifiers ───────────────────────────────────────────────────────

--- Toggle sort on a column (replaces existing sorts).
--- Cycles: off → ASC → DESC → off.
function M.toggle_sort(spec, column)
  local new = deep_copy(spec)
  for i, s in ipairs(new.sorts) do
    if s.column == column then
      if s.dir == "ASC" then
        new.sorts[i].dir = "DESC"
      else
        table.remove(new.sorts, i)
      end
      return new
    end
  end
  -- Not found → replace all with ASC on this column
  new.sorts = { { column = column, dir = "ASC" } }
  return new
end

--- Add/toggle secondary sort (stacked).
function M.add_sort(spec, column)
  local new = deep_copy(spec)
  for i, s in ipairs(new.sorts) do
    if s.column == column then
      if s.dir == "ASC" then
        new.sorts[i].dir = "DESC"
      else
        table.remove(new.sorts, i)
      end
      return new
    end
  end
  table.insert(new.sorts, { column = column, dir = "ASC" })
  return new
end

--- Clear all sorts.
function M.clear_sorts(spec)
  local new = deep_copy(spec)
  new.sorts = {}
  return new
end

--- Get sort indicator for a column header.
--- Returns "▲", "▼", "▲1", "▼2", or nil.
function M.get_sort_indicator(spec, column)
  for i, s in ipairs(spec.sorts) do
    if s.column == column then
      local arrow = s.dir == "ASC" and "▲" or "▼"
      if #spec.sorts > 1 then
        return arrow .. tostring(i)
      end
      return arrow
    end
  end
  return nil
end

-- ── filter modifiers ─────────────────────────────────────────────────────

--- Add a WHERE clause fragment. Multiple filters are AND-ed.
--- opts.pinned = true marks the clause as part of the grid's identity rather than
--- a user-applied view modifier: FK navigation (gf/gm) pins the clause that scopes
--- the grid to the referenced/referencing rows. Pinned filters survive
--- clear_filters/reset/set_filters, are excluded from has_filters/user_filters, and
--- show up in clean_sql. See the pinned-filter block in tests/spec/query_spec.lua.
function M.add_filter(spec, clause, opts)
  local new = deep_copy(spec)
  local entry = { clause = clause }
  if opts and opts.pinned then entry.pinned = true end
  table.insert(new.filters, entry)
  return new
end

--- Build a SQL filter clause string from a column, operator, and user-supplied value.
--- Handles quoting: numeric strings are unquoted, all others get single-quote wrapping.
--- Operators: "=", "!=", ">", "<", "LIKE", "IN", "BETWEEN", "NULL", "NOT NULL"
--- For "IN": value is comma-separated, each item quoted/unquoted individually.
--- For "BETWEEN": value is "low,high": two comma-separated values.
--- For "LIKE": auto-wraps value with %…% if no % present (substring intent assumed).
--- For "NULL" / "NOT NULL": value is ignored.
function M.build_filter_clause(col, op, value)
  local col_q = sql_mod.quote_ident(col)

  -- IS NULL / IS NOT NULL: no value needed
  if op == "NULL" then
    return col_q .. " IS NULL"
  elseif op == "NOT NULL" then
    return col_q .. " IS NOT NULL"
  end

  -- Helper: quote a single user-supplied string value.
  -- Numeric strings pass through raw; everything else gets single-quoted with escaping.
  local function quote_user_val(v)
    if tonumber(v) then
      return v  -- raw numeric string, e.g. "42", "3.14", "-1"
    end
    return "'" .. esc(tostring(v)) .. "'"
  end

  -- IN: parse comma-separated list, quote each part
  if op == "IN" then
    local parts = {}
    for item in tostring(value):gmatch("[^,]+") do
      -- Trim surrounding whitespace
      local trimmed = item:match("^%s*(.-)%s*$")
      table.insert(parts, quote_user_val(trimmed))
    end
    return col_q .. " IN (" .. table.concat(parts, ",") .. ")"
  end

  -- BETWEEN: parse "low,high": two comma-separated values
  if op == "BETWEEN" then
    local parts = {}
    for item in tostring(value):gmatch("[^,]+") do
      local trimmed = item:match("^%s*(.-)%s*$")
      table.insert(parts, quote_user_val(trimmed))
    end
    if #parts ~= 2 then
      error("BETWEEN requires exactly two values (low,high)")
    end
    return col_q .. " BETWEEN " .. parts[1] .. " AND " .. parts[2]
  end

  -- LIKE: auto-wrap with % wildcards if user didn't include any
  local val_str = tostring(value or "")
  if op == "LIKE" and not val_str:find("%%") then
    val_str = "%" .. val_str .. "%"
  end

  -- =, !=, >, <, LIKE: single value
  return col_q .. " " .. op .. " " .. quote_user_val(val_str)
end

--- Quick-filter: "column = value" or "column IS NULL".
function M.quick_filter(spec, column, value)
  local clause
  if value == nil then
    clause = sql_mod.quote_ident(column) .. " IS NULL"
  else
    clause = sql_mod.quote_ident(column) .. " = " .. sql_mod.quote_value(value)
  end
  return M.add_filter(spec, clause)
end

--- Return the pinned filters of a spec, in order. Local helper: callers outside
--- this module care about user filters, never about the pinned ones directly.
local function pinned_filters(spec)
  local kept = {}
  for _, f in ipairs(spec.filters) do
    if f.pinned then table.insert(kept, f) end
  end
  return kept
end

--- Clear the user's filters. Pinned filters (FK navigation context) are kept:
--- dropping them would silently widen the grid to the whole table.
function M.clear_filters(spec)
  local new = deep_copy(spec)
  new.filters = pinned_filters(new)
  return new
end

--- Return the user-applied (unpinned) filters, in order.
function M.user_filters(spec)
  local user = {}
  for _, f in ipairs(spec.filters) do
    if not f.pinned then table.insert(user, f) end
  end
  return user
end

--- Check if spec has active user filters. Pinned filters don't count: they are
--- navigation context, not something the user applied and can clear.
function M.has_filters(spec)
  return #M.user_filters(spec) > 0
end

--- Human-readable filter summary (full clauses, no truncation).
function M.filter_summary(spec)
  if #spec.filters == 0 then return "" end
  if #spec.filters == 1 then
    return "filter: " .. spec.filters[1].clause
  end
  local parts = {}
  for _, f in ipairs(spec.filters) do
    table.insert(parts, f.clause)
  end
  return "filters: " .. table.concat(parts, "  \xC2\xB7  ")
end

--- Replace the user's filters with a single clause (for loading presets).
--- Pinned filters are kept and stay first, so a preset narrows the FK context
--- instead of escaping it.
function M.set_filters(spec, clause)
  local new = deep_copy(spec)
  new.filters = pinned_filters(new)
  table.insert(new.filters, { clause = clause })
  return new
end

--- Reset all modifiers: clear sorts and user filters.
--- Pinned filters survive, same rationale as clear_filters.
function M.reset(spec)
  local new = deep_copy(spec)
  new.sorts = {}
  new.filters = pinned_filters(new)
  return new
end

-- ── SQL composition ──────────────────────────────────────────────────────

--- "WHERE (a) AND (b)" for a list of filter entries; nil when the list is empty.
local function where_clause(filters)
  if #filters == 0 then return nil end
  local parts = {}
  for _, f in ipairs(filters) do
    table.insert(parts, "(" .. f.clause .. ")")
  end
  return "WHERE " .. table.concat(parts, " AND ")
end

--- A raw query as a subquery. The closing parenthesis goes on its own line
--- when the query has a -- comment, or a comment on its last line would
--- swallow it.
local function wrap_raw(base_sql)
  local close = base_sql:find("--", 1, true) and "\n)" or ")"
  return "(" .. base_sql .. close .. " AS _grip"
end

--- Build the data query SQL from a spec. Raw SQL with no sort or filter is
--- returned as written. opts.uncapped=true keeps the filters and sorts but
--- drops a table's LIMIT (used by all-row export).
function M.build_sql(spec, opts)
  local parts = {}
  if spec.is_raw and #spec.sorts == 0 and #spec.filters == 0 and not spec.limit then
    return spec.base_sql
  end

  -- FROM clause
  local from
  if spec.is_raw then
    from = wrap_raw(spec.base_sql)
  else
    from = sql_mod.quote_ident(spec.table_name)
  end

  table.insert(parts, "SELECT * FROM " .. from)

  -- WHERE clause: pinned and user filters alike
  local where = where_clause(spec.filters)
  if where then table.insert(parts, where) end

  -- ORDER BY clause
  if #spec.sorts > 0 then
    local order_parts = {}
    for _, s in ipairs(spec.sorts) do
      table.insert(order_parts, sql_mod.quote_ident(s.column) .. " " .. s.dir)
    end
    table.insert(parts, "ORDER BY " .. table.concat(order_parts, ", "))
  end

  -- The table cap; each adapter translates LIMIT to its dialect (TOP/FETCH)
  if spec.limit and not (opts and opts.uncapped) then
    table.insert(parts, "LIMIT " .. spec.limit)
  end

  return table.concat(parts, " ")
end

--- Build COUNT query: every row the spec's filters match (all-row export).
function M.build_count_sql(spec)
  local parts = {}
  local from
  if spec.is_raw then
    from = wrap_raw(spec.base_sql)
  else
    from = sql_mod.quote_ident(spec.table_name)
  end

  table.insert(parts, "SELECT COUNT(*) AS _grip_count FROM " .. from)

  local where = where_clause(spec.filters)
  if where then table.insert(parts, where) end

  return table.concat(parts, " ")
end

--- Return the user-visible SQL for a spec (no pagination wrapper).
--- Use this to pre-fill the query pad. build_sql() is for DB execution only.
--- For raw specs returns spec.base_sql; for table specs returns
--- 'SELECT * FROM table' plus the WHERE of any pinned filters. Identifiers are
--- quoted only where `kind`'s dialect needs it (sql.display_ident): the query
--- still runs as-is against reserved-word or, on Postgres, mixed-case tables.
--- Pinned filters are included because they define which rows the grid is showing
--- (FK navigation): without them the pad would advertise a query returning a
--- different result set than the grid below it. User filters, sorts and pagination
--- are excluded — those are transient view state, and rewriting the pad on every
--- f/s/H keypress would clobber whatever the user is composing there.
function M.clean_sql(spec, kind)
  if spec.is_raw then
    return spec.base_sql
  end
  local out = "SELECT * FROM " .. sql_mod.display_ident(spec.table_name or "", kind)
  -- Pinned clauses start with the column quote_ident wrote ("col" = 'v');
  -- only that leading identifier is touched, never a string literal.
  local pinned = {}
  for _, f in ipairs(pinned_filters(spec)) do
    local clause = f.clause:gsub('^("[^"]+")', function(id)
      return sql_mod.display_ident(id, kind)
    end)
    table.insert(pinned, { clause = clause })
  end
  local where = where_clause(pinned)
  if where then out = out .. " " .. where end
  return out
end

return M
