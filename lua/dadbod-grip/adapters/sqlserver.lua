-- adapters/sqlserver.lua: SQL Server adapter (sqlcmd CLI).
-- Read-only grid support for v1. All functions return (result, err).

local adapters = require("dadbod-grip.adapters")
local db_util  = require("dadbod-grip.db")
local sql_util = require("dadbod-grip.sql")
local esc = sql_util.escape_literal

local M = { readonly = true }

-- Column-stats query rules; see db.stats_dialect.
M.stats_dialect = {
  quote = function(n) return "[" .. n:gsub("%]", "]]") .. "]" end,
  text = "NVARCHAR(100)",
  -- COUNT(DISTINCT), MIN and MAX all fail on these.
  no_compare = { text = true, ntext = true, image = true, xml = true, geography = true, geometry = true },
  -- MIN/MAX reject bit; compare it as a number instead.
  cast_from = { bit = "INT" },
}

local DEFAULT_TIMEOUT = 30000

--- go-sqlcmd answers --version; mssql-tools sqlcmd rejects it with exit 1.
--- Cached per session: the binary does not change under a running Neovim.
local _is_go_sqlcmd
local function is_go_sqlcmd()
  if _is_go_sqlcmd == nil then
    local ok, result = pcall(function()
      return vim.system({ "sqlcmd", "--version" }, { text = true }):wait(5000)
    end)
    _is_go_sqlcmd = ok and result.code == 0
  end
  return _is_go_sqlcmd
end

local function decode_query_value(value)
  return (value:gsub("+", " "):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Parse a dadbod-style SQL Server URL and its TLS query options.
--- Both sqlserver:// and mssql:// are accepted by the shared URL parser.
--- @return table|nil parsed
--- @return string|nil err
local function parse_url(url)
  local base, query = url:match("^(.-)%?(.*)$")
  local parsed = sql_util.parse_dadbod_url(base or url, "1433")
  if not parsed then return nil, "Invalid SQL Server URL: " .. sql_util.redact_url(url) end

  local params = {}
  for part in (query or ""):gmatch("[^&]+") do
    local key, value = part:match("^([^=]+)=?(.*)$")
    if key then params[decode_query_value(key):lower()] = decode_query_value(value) end
  end

  local encrypt = (params.encrypt or "mandatory"):lower()
  local encrypt_aliases = {
    optional = "optional", o = "optional", ["false"] = "optional", no = "optional", ["0"] = "optional",
    mandatory = "mandatory", m = "mandatory", ["true"] = "mandatory", yes = "mandatory", ["1"] = "mandatory",
    strict = "strict", s = "strict",
  }
  parsed.encrypt = encrypt_aliases[encrypt]
  if not parsed.encrypt then
    return nil, "SQL Server encrypt must be optional, mandatory, or strict"
  end

  local trust = (params.trust_server_certificate or "false"):lower()
  if trust == "true" or trust == "yes" or trust == "1" then
    parsed.trust_server_certificate = true
  elseif trust ~= "false" and trust ~= "no" and trust ~= "0" and trust ~= "" then
    return nil, "SQL Server trust_server_certificate must be true or false"
  end

  parsed.server_certificate = params.server_certificate
  if parsed.server_certificate == "" then parsed.server_certificate = nil end
  if parsed.server_certificate and parsed.encrypt == "optional" then
    return nil, "SQL Server server_certificate requires mandatory or strict encryption"
  end
  if parsed.server_certificate and parsed.trust_server_certificate then
    return nil, "SQL Server server_certificate cannot be combined with trust_server_certificate=true"
  end

  -- Microsoft Entra ID (Azure AD) and other go-sqlcmd login methods, e.g.
  -- authentication=ActiveDirectoryDefault to reuse an `az login` session.
  -- Passed through to --authentication-method; sqlcmd validates the name.
  local authentication = params.authentication
  if authentication and authentication ~= "" then
    if not authentication:match("^%a+$") then
      return nil, "SQL Server authentication must be a sqlcmd authentication method name"
    end
    parsed.authentication = authentication
  end
  return parsed
end

--- Split a possibly schema-qualified table name; unqualified names are "dbo".
local function split_table_name(table_name, default_schema)
  return sql_util.split_table_name(table_name, default_schema or "dbo")
end

--- Build connection-only argv. Statements always arrive through stdin.
local function sqlcmd_args(parsed)
  local server = parsed.host or "127.0.0.1"
  if parsed.port and parsed.port ~= "" then
    server = server .. "," .. parsed.port
  end

  local args = {
    "sqlcmd",
    "-S", server,
    -- Supplying -N makes sqlcmd validate the server certificate unless the
    -- URL explicitly opts into -C. Mandatory is the secure default.
    "-N" .. ({ optional = "o", mandatory = "m", strict = "s" })[parsed.encrypt or "mandatory"],
    "-W",
    "-s", "\t",
    -- Without -b sqlcmd exits 0 even when the server rejects the statement, so
    -- every `code ~= 0` guard below would be dead and a refused DROP would be
    -- reported as a success.
    "-b",
  }

  -- Both clients cut (n)varchar(max)/xml values at 256 characters by default,
  -- which breaks long JSON cells. The sqlserver_max_type_width option raises
  -- that (0 = unlimited) via -y. go-sqlcmd allows -y next to -W; mssql-tools
  -- sqlcmd rejects the combination, so it keeps its default limit.
  local max_type_width = require("dadbod-grip.config").values.sqlserver_max_type_width
  if max_type_width and is_go_sqlcmd() then
    args[#args + 1] = "-y"
    args[#args + 1] = tostring(max_type_width)
  end

  if parsed.trust_server_certificate then args[#args + 1] = "-C" end
  if parsed.server_certificate then
    args[#args + 1] = "-J"
    args[#args + 1] = parsed.server_certificate
  end

  if parsed.dbname and parsed.dbname ~= "" then
    table.insert(args, 4, parsed.dbname)
    table.insert(args, 4, "-d")
  end

  if parsed.user and parsed.user ~= "" then
    table.insert(args, 4, parsed.user)
    table.insert(args, 4, "-U")
  elseif not parsed.authentication then
    table.insert(args, 4, "-E")
  end

  if parsed.authentication then
    table.insert(args, 4, parsed.authentication)
    table.insert(args, 4, "--authentication-method")
  end

  return args
end

--- Prefix the session settings required by ordinary query execution, and
--- terminate the final batch with GO: mssql-tools sqlcmd runs a trailing
--- unterminated batch at EOF, but go-sqlcmd silently drops it.
local function sqlcmd_stdin(sql_str, opts)
  opts = opts or {}
  local session = "SET QUOTED_IDENTIFIER ON;\n"
  if opts.nocount ~= false then session = session .. "SET NOCOUNT ON;\n" end
  local terminator = "\nGO\n"
  local last_line = sql_str:match("([^\n]*)%s*$") or ""
  if last_line:match("^%s*[Gg][Oo]%s*$") then terminator = "\n" end
  return session .. sql_str .. terminator
end

--- opts.env for one sqlcmd invocation: SQLCMDPASSWORD carrying the password so
--- it never appears in argv (visible via `ps`) -- the env-var equivalent of the
--- -P flag this replaces. No percent-decoding, same verbatim contract as
--- sqlcmd_args. Set (even to "") whenever a user is given, mirroring the old
--- -P/-P "" pairing with -U; empty when there is no user, since that means
--- -E integrated auth, which ignores any password.
local function sqlcmd_env(parsed)
  if not parsed.user or parsed.user == "" then return {} end
  return { SQLCMDPASSWORD = parsed.pass or "" }
end

--- Build and run the sqlcmd command, blocking.
local function sqlcmd(parsed, sql_str, timeout_ms, opts)
  return adapters.run_cmd(sqlcmd_args(parsed),
    timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT),
    { stdin = sqlcmd_stdin(sql_str, opts), env = sqlcmd_env(parsed) })
end

--- Run GO-separated batches by feeding them to sqlcmd on stdin. `-Q` can only
--- carry one batch, and SET SHOWPLAN_TEXT has to be alone in its own.
local function sqlcmd_batch(parsed, batches, timeout_ms)
  local script = table.concat(batches, "\nGO\n") .. "\nGO\n"
  return adapters.run_cmd(sqlcmd_args(parsed),
    timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT),
    { stdin = script, env = sqlcmd_env(parsed) })
end

--- Message for a non-zero sqlcmd exit. With -b the server's "Msg 208, ..." text
--- lands on stdout and stderr stays empty (stderr only carries client-side
--- failures), so stdout is the fallback before the bare exit code.
--- A batch that fails at run time (rather than at compile time) has already
--- printed the earlier statements' "(N rows affected)" by then, so report from
--- the server message onwards; output with no such line is passed through whole.
local function sqlcmd_error(stdout, stderr, code)
  if stderr and stderr ~= "" then return stderr end
  local out = vim.trim(stdout or "")
  if out ~= "" then
    local lines = vim.split(out, "\n", { plain = true })
    for i, line in ipairs(lines) do
      if line:match("^Msg %d") then
        return table.concat(lines, "\n", i)
      end
    end
    return out
  end
  return "sqlcmd exited with code " .. tostring(code)
end

--- Parse sqlcmd's -W -s "\t" output: a header line, a line of dashes, then
--- one line per row. Only the first result set is read.
---
--- A value holding a newline spans several output lines; with more than one
--- column the row is joined back until it has all its tab separators. (With a
--- single column there is nothing to count, so each line is a row.) A blank
--- line where a row starts ends the result set: a row of two or more columns
--- always contains a tab. The separator is recognised only right below the
--- header, so a value of dashes stays a row. NULL arrives as the text NULL and
--- becomes "", which the grid shows as NULL.
local function parse_sqlcmd_table(raw)
  if not raw or raw == "" then
    return { columns = {}, rows = {} }
  end

  local lines = vim.split((raw:gsub("\r\n", "\n")), "\n", { plain = true })
  local function is_count(line)
    return vim.trim(line):match("^%(%d+ rows? affected%)$") ~= nil
  end
  local function is_separator(line)
    return line:find("-", 1, true) ~= nil and line:gsub("[\t %-]", "") == ""
  end
  local function split(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
      if field == "NULL" then field = "" end
      table.insert(fields, field)
    end
    return fields
  end
  local function tabs(line)
    local _, n = line:gsub("\t", "")
    return n
  end

  local header, first_row
  for i = 1, #lines - 1 do
    if lines[i] ~= "" and not is_count(lines[i]) and is_separator(lines[i + 1]) then
      header, first_row = i, i + 2
      break
    end
  end
  if not header then
    -- No separator line: take the first line as the header, rows follow it.
    for i, line in ipairs(lines) do
      if vim.trim(line) ~= "" and not is_count(line) then
        header, first_row = i, i + 1
        break
      end
    end
    if not header then return { columns = {}, rows = {} } end
  end

  local columns = split(lines[header])
  local ncols = #columns
  local rows = {}
  local last = #lines
  while last >= first_row and vim.trim(lines[last]) == "" do last = last - 1 end
  local i = first_row
  while i <= last do
    local line = lines[i]
    if is_count(line) then
      -- "(N rows affected)" closes the result set
      break
    end
    if line == "" and ncols > 1 then break end
    if line == "" and i + 2 <= last and is_separator(lines[i + 2]) then break end
    if ncols > 1 then
      while tabs(line) < ncols - 1 and i < last do
        i = i + 1
        line = line .. "\n" .. lines[i]
      end
    end
    local row = split(line)
    while #row < ncols do table.insert(row, "") end
    table.insert(rows, row)
    i = i + 1
  end

  return { columns = columns, rows = rows }
end

--- Lower-cased copy of `sql` with everything that is not top-level SQL blanked:
--- string literals, [bracketed] and "quoted" names, comments and the inside
--- of parentheses. Positions line up with `sql`, so a keyword found here is a
--- top-level keyword at the same index there.
local function mask_top_level(sql)
  local out, depth, i, n = {}, 0, 1, #sql
  local function blank(from, to)
    for k = from, to do out[k] = " " end
  end
  while i <= n do
    local c, two = sql:sub(i, i), sql:sub(i, i + 1)
    local stop
    if two == "--" then
      stop = (sql:find("\n", i, true) or (n + 1)) - 1
    elseif two == "/*" then
      local _, e = sql:find("*/", i + 2, true)
      stop = e or n
    elseif c == "'" or c == '"' or c == "[" then
      local close = c == "[" and "]" or c
      local j = i + 1
      while j <= n do
        if sql:sub(j, j) == close then
          if sql:sub(j + 1, j + 1) == close then j = j + 1 else break end
        end
        j = j + 1
      end
      stop = math.min(j, n)
    end
    if stop then
      blank(i, stop)
      i = stop + 1
    else
      if c == "(" then depth = depth + 1 end
      out[i] = depth > 0 and " " or c:lower()
      if c == ")" then depth = math.max(depth - 1, 0) end
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Make a raw query valid as the subquery Grip wraps it in to sort or filter
--- (SELECT * FROM (<query>) AS _grip ...). SQL Server rejects two things
--- there that it accepts on their own:
---   * a CTE: WITH has to come before the outer SELECT, so it is moved out;
---   * ORDER BY without TOP or OFFSET: it gets OFFSET 0 ROWS, which keeps the
---     query's own order meaning and makes the subquery legal.
local function normalize_wrapped(sql_str)
  local pre, inner, post = sql_str:match("^(SELECT .-FROM %()(.*)(%s*%) AS _grip.*)$")
  if not inner then return sql_str end

  local cte = ""
  local masked = mask_top_level(inner)
  if masked:match("^%s*with%f[^%w_]") then
    local sel = masked:find("%f[%w_]select%f[^%w_]")
    if not sel then return sql_str end
    cte = inner:sub(1, sel - 1)
    inner = inner:sub(sel)
    masked = masked:sub(sel)
  end

  local order_at
  local from = 1
  while true do
    local s = masked:find("%f[%w_]order%s+by%f[^%w_]", from)
    if not s then break end
    order_at, from = s, s + 1
  end
  local has_top = masked:match("^%s*select%s+top%f[^%w_]")
    or masked:match("^%s*select%s+distinct%s+top%f[^%w_]")
  if order_at and not has_top
      and not masked:sub(order_at):find("%f[%w_]offset%f[^%w_]")
      and not masked:sub(order_at):find("%f[%w_]for%s+[xj]") then
    inner = inner .. "\nOFFSET 0 ROWS"
  end
  return cte .. pre .. inner .. post
end
M._normalize_wrapped = normalize_wrapped

--- Translate the LIMIT/OFFSET tail emitted by the shared query builder into
--- SQL Server's OFFSET/FETCH syntax. The adapter boundary is the only place
--- that knows the dialect, so every initial query and requery gets the fix.
local function normalize_query_sql(sql_str)
  sql_str = normalize_wrapped(sql_str)
  local base, limit, offset = sql_str:match(
    "^(.-)%s+[Ll][Ii][Mm][Ii][Tt]%s+(%d+)%s+[Oo][Ff][Ff][Ss][Ee][Tt]%s+(%d+)%s*;?%s*$")
  if not base then
    base, limit = sql_str:match("^(.-)%s+[Ll][Ii][Mm][Ii][Tt]%s+(%d+)%s*;?%s*$")
    offset = "0"
  end
  if not base then return sql_str end

  -- OFFSET/FETCH requires an outer ORDER BY. Ignore any ORDER BY inside the
  -- raw-query wrapper; it does not satisfy SQL Server's outer SELECT.
  local lower = base:lower()
  local raw_alias_end = lower:find("%)%s+as%s+_grip")
  local outer = raw_alias_end and lower:sub(raw_alias_end) or lower
  if not outer:find("%sorder%s+by%s") then
    base = base .. " ORDER BY (SELECT NULL)"
  end
  return string.format("%s OFFSET %s ROWS FETCH NEXT %s ROWS ONLY", base, offset, limit)
end

local function run_query(sql_str, url, timeout_ms)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end

  local parsed, parse_err = parse_url(url)
  if not parsed then return nil, parse_err end

  local stdout, stderr, code = sqlcmd(parsed, normalize_query_sql(sql_str), timeout_ms)
  if code ~= 0 then
    return nil, sqlcmd_error(stdout, stderr, code)
  end
  return parse_sqlcmd_table(stdout), nil
end

function M.query(sql_str, url)
  local parsed, err = run_query(sql_str, url)
  if not parsed then return nil, err end
  return {
    rows = parsed.rows,
    columns = parsed.columns,
    primary_keys = {},
  }, nil
end

function M.execute(sql_str, url)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end
  local parsed, parse_err = parse_url(url)
  if not parsed then return nil, parse_err end
  local stdout, stderr, code = sqlcmd(parsed, sql_str, nil, { nocount = false })
  if code ~= 0 then
    return nil, sqlcmd_error(stdout, stderr, code)
  end
  local n = stdout:match("%((%d+) rows? affected%)") or stderr:match("%((%d+) rows? affected%)") or "0"
  return { affected = tonumber(n) or 0, message = stdout:gsub("%s+$", "") }, nil
end

function M.ping(url)
  if vim.fn.executable("sqlcmd") == 0 then return false end
  local parsed = parse_url(url)
  if not parsed then return false end
  local _, _, code = sqlcmd(parsed, "SELECT 1", 5000)
  return code == 0
end

function M.list_tables(url)
  local result, err = run_query([[
    SELECT
      CASE WHEN TABLE_SCHEMA = 'dbo' THEN TABLE_NAME ELSE TABLE_SCHEMA + '.' + TABLE_NAME END AS table_name,
      CASE TABLE_TYPE WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS table_type
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_TYPE IN ('BASE TABLE', 'VIEW')
    ORDER BY TABLE_SCHEMA, table_type DESC, TABLE_NAME
  ]], url)
  if not result then return nil, err end
  local out = {}
  for _, row in ipairs(result.rows) do
    table.insert(out, { name = row[1] or "", type = row[2] or "table" })
  end
  return out, nil
end

--- Both FK directions in one sqlcmd run, for the Foreign Keys view: each
--- run is a separate login. Returns (outbound fks, inbound refs, err) in the
--- shapes get_foreign_keys and get_referencing_foreign_keys return.
function M.get_all_foreign_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local name = function(s, t)
    return string.format("CASE WHEN %s.name = 'dbo' THEN %s.name ELSE %s.name + '.' + %s.name END", s, t, s, t)
  end
  local body = [[
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    JOIN sys.tables pt ON pt.object_id = fk.parent_object_id
    JOIN sys.schemas ps ON ps.schema_id = pt.schema_id
    JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
    JOIN sys.schemas rs ON rs.schema_id = rt.schema_id
    JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
    JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id]]
  local sql_str = string.format([[
    SELECT 'OUT' AS dir, pc.name AS col, %s AS other_table, rc.name AS other_col,
      fk.name AS fk_name, fkc.constraint_column_id AS pos
%s
    WHERE ps.name = '%s' AND pt.name = '%s'
    UNION ALL
    SELECT 'IN', pc.name, %s, rc.name, fk.name, fkc.constraint_column_id
%s
    WHERE rs.name = '%s' AND rt.name = '%s'
    ORDER BY dir DESC, other_table, fk_name, pos
  ]], name("rs", "rt"), body, esc(schema), esc(tbl), name("ps", "pt"), body, esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, {}, err end
  local fks, inbound = {}, {}
  for _, row in ipairs(result.rows) do
    if row[1] == "OUT" then
      table.insert(fks, { column = row[2] or "", ref_table = row[3] or "", ref_column = row[4] or "" })
    elseif row[1] == "IN" then
      table.insert(inbound, { table = row[3] or "", column = row[2] or "", ref_column = row[4] or "", key = row[5] or "" })
    end
  end
  return fks, db_util.group_referencing_fks(inbound), nil
end

--- Reverse FK lookup: which tables reference table_name?
--- One schema-aware sys.foreign_keys query, so a qualified target
--- ("dbo.users") is resolved server-side instead of going through db.lua's
--- bare-name scan, which ddl._filter_referencing has to discard as ambiguous.
--- Returns { {table, column, ref_column, composite?}, ... }, err.
function M.get_referencing_foreign_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      cs.name AS child_schema,
      ct.name AS child_table,
      cc.name AS fk_column,
      rc.name AS ref_column,
      fk.name AS constraint_name
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    JOIN sys.tables ct ON ct.object_id = fk.parent_object_id
    JOIN sys.schemas cs ON cs.schema_id = ct.schema_id
    JOIN sys.tables pt ON pt.object_id = fk.referenced_object_id
    JOIN sys.schemas ps ON ps.schema_id = pt.schema_id
    JOIN sys.columns cc ON cc.object_id = fkc.parent_object_id
      AND cc.column_id = fkc.parent_column_id
    JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id
      AND rc.column_id = fkc.referenced_column_id
    WHERE ps.name = '%s'
      AND pt.name = '%s'
    ORDER BY cs.name, ct.name, fk.name, fkc.constraint_column_id
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end

  local entries = {}
  for _, row in ipairs(result.rows) do
    local child_schema = row[1] or "dbo"
    local child_tbl = row[2] or ""
    -- Same naming as list_tables: dbo is implicit, other schemas are qualified.
    local full_name = (child_schema == "dbo") and child_tbl or (child_schema .. "." .. child_tbl)
    table.insert(entries, {
      table      = full_name,
      column     = row[3] or "",
      ref_column = row[4] or "",
      key        = row[5] or "",
    })
  end
  return db_util.group_referencing_fks(entries), nil
end

--- The length/precision-suffixed data_type expression used by get_column_info.
--- SQL Server reports CHARACTER_MAXIMUM_LENGTH = -1 for the MAX types
--- (nvarchar(max), varbinary(max)), hence the dedicated arm ahead of the
--- positive-length one.
local DATA_TYPE_EXPR = [[
      DATA_TYPE +
        CASE
          WHEN CHARACTER_MAXIMUM_LENGTH = -1 THEN '(max)'
          WHEN CHARACTER_MAXIMUM_LENGTH IS NOT NULL AND CHARACTER_MAXIMUM_LENGTH > 0
            THEN '(' + CAST(CHARACTER_MAXIMUM_LENGTH AS varchar(20)) + ')'
          WHEN NUMERIC_PRECISION IS NOT NULL AND DATA_TYPE NOT IN ('int','bigint','smallint','tinyint','bit')
            THEN '(' + CAST(NUMERIC_PRECISION AS varchar(20)) +
                 CASE WHEN NUMERIC_SCALE > 0 THEN ',' + CAST(NUMERIC_SCALE AS varchar(20)) ELSE '' END + ')'
          ELSE ''
        END AS data_type]]

function M.get_column_info(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      COLUMN_NAME,
%s,
      IS_NULLABLE,
      COALESCE(COLUMN_DEFAULT, '') AS column_default,
      ''
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = '%s'
      AND TABLE_NAME = '%s'
    ORDER BY ORDINAL_POSITION
  ]], DATA_TYPE_EXPR, esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return nil, err end

  local cols = {}
  for _, row in ipairs(result.rows) do
    table.insert(cols, {
      column_name = row[1] or "",
      data_type = row[2] or "",
      is_nullable = row[3] or "",
      column_default = row[4] or "",
      constraints = row[5] or "",
    })
  end
  return cols, nil
end

-- FROM/WHERE bodies shared by the single-purpose key lookups and the combined
-- get_table_keys, so the two paths can never select different keys.
local PK_FROM = [[
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
      ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
      AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
    WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
      AND tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s']]

local FK_FROM = [[
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
      ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
      AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
    JOIN INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc
      ON rc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND rc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    JOIN INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE ccu
      ON ccu.CONSTRAINT_NAME = rc.UNIQUE_CONSTRAINT_NAME
      AND ccu.CONSTRAINT_SCHEMA = rc.UNIQUE_CONSTRAINT_SCHEMA
    WHERE tc.CONSTRAINT_TYPE = 'FOREIGN KEY'
      AND tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s']]

local function key_from(body, table_name)
  local schema, tbl = split_table_name(table_name, "dbo")
  return string.format(body, esc(schema), esc(tbl))
end

function M.get_primary_keys(table_name, url)
  local sql_str = "SELECT kcu.COLUMN_NAME" .. key_from(PK_FROM, table_name)
    .. "\n    ORDER BY kcu.ORDINAL_POSITION"
  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local pks = {}
  for _, row in ipairs(result.rows) do
    if row[1] and row[1] ~= "" then table.insert(pks, row[1]) end
  end
  return pks, nil
end

function M.get_foreign_keys(table_name, url)
  local sql_str = "SELECT kcu.COLUMN_NAME, ccu.TABLE_NAME AS ref_table, ccu.COLUMN_NAME AS ref_column"
    .. key_from(FK_FROM, table_name) .. "\n    ORDER BY kcu.ORDINAL_POSITION"
  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local fks = {}
  for _, row in ipairs(result.rows) do
    table.insert(fks, {
      column = row[1] or "",
      ref_table = row[2] or "",
      ref_column = row[3] or "",
    })
  end
  return fks, nil
end

--- Primary and foreign keys in one sqlcmd run: (pks, fks, err). Each sqlcmd
--- process logs in again, so the sidebar's Keys folder asks for both at once.
function M.get_table_keys(table_name, url)
  local sql_str = "SELECT key_kind, column_name, ref_table, ref_column FROM (\n"
    .. "    SELECT 'PK' AS key_kind, kcu.COLUMN_NAME AS column_name, '' AS ref_table,"
    .. " '' AS ref_column, kcu.ORDINAL_POSITION AS pos" .. key_from(PK_FROM, table_name)
    .. "\n    UNION ALL\n"
    .. "    SELECT 'FK', kcu.COLUMN_NAME, ccu.TABLE_NAME, ccu.COLUMN_NAME, kcu.ORDINAL_POSITION"
    .. key_from(FK_FROM, table_name)
    .. "\n  ) k ORDER BY key_kind DESC, pos"
  local result, err = run_query(sql_str, url)
  if not result then return {}, {}, err end
  local pks, fks = {}, {}
  for _, row in ipairs(result.rows) do
    if row[1] == "PK" and row[2] and row[2] ~= "" then
      table.insert(pks, row[2])
    elseif row[1] == "FK" then
      table.insert(fks, { column = row[2] or "", ref_table = row[3] or "", ref_column = row[4] or "" })
    end
  end
  return pks, fks, nil
end

function M.get_indexes(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      i.name AS index_name,
      CASE WHEN i.is_primary_key = 1 THEN 'PRIMARY'
           WHEN i.is_unique = 1 THEN 'UNIQUE'
           ELSE 'INDEX' END AS index_type,
      STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS columns
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    JOIN sys.objects o ON o.object_id = i.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE s.name = '%s'
      AND o.name = '%s'
      AND i.name IS NOT NULL
    GROUP BY i.name, i.is_primary_key, i.is_unique
    ORDER BY i.is_primary_key DESC, i.name
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local indexes = {}
  for _, row in ipairs(result.rows) do
    local cols = {}
    for col in (row[3] or ""):gmatch("([^,]+)") do table.insert(cols, vim.trim(col)) end
    table.insert(indexes, { name = row[1] or "", type = row[2] or "INDEX", columns = cols })
  end
  return indexes, nil
end

function M.get_constraints(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      tc.CONSTRAINT_NAME,
      tc.CONSTRAINT_TYPE,
      COALESCE(cc.CHECK_CLAUSE, '') AS definition
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    LEFT JOIN INFORMATION_SCHEMA.CHECK_CONSTRAINTS cc
      ON cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    WHERE tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
      AND tc.CONSTRAINT_TYPE IN ('CHECK', 'UNIQUE')
    ORDER BY tc.CONSTRAINT_TYPE, tc.CONSTRAINT_NAME
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local constraints = {}
  for _, row in ipairs(result.rows) do
    table.insert(constraints, { name = row[1] or "", type = row[2] or "", definition = row[3] or "" })
  end
  return constraints, nil
end

function M.get_table_stats(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      SUM(row_count) AS row_estimate,
      SUM(reserved_page_count) * 8192 AS size_bytes
    FROM sys.dm_db_partition_stats ps
    JOIN sys.objects o ON o.object_id = ps.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE s.name = '%s'
      AND o.name = '%s'
      AND ps.index_id IN (0, 1)
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result or not result.rows[1] then return nil, err or "No stats found" end
  return {
    row_estimate = tonumber(result.rows[1][1]) or 0,
    size_bytes = tonumber(result.rows[1][2]) or 0,
  }, nil
end

--- SHOWPLAN_TEXT has to be the only statement in its batch, so the plan cannot
--- go through run_query's single stdin script (which also prefixes SET NOCOUNT ON):
--- the server answers every such attempt with "The SET SHOWPLAN statements must
--- be the only statements in the batch". Two GO-separated batches on stdin.
function M.explain(sql_str, url)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end
  local parsed, parse_err = parse_url(url)
  if not parsed then return nil, parse_err end

  local stdout, stderr, code = sqlcmd_batch(parsed,
    { "SET SHOWPLAN_TEXT ON", normalize_query_sql(sql_str) })
  if code ~= 0 then
    return nil, sqlcmd_error(stdout, stderr, code)
  end

  local result = parse_sqlcmd_table(stdout)
  local header = result.columns[1]
  local lines = {}
  for _, row in ipairs(result.rows) do
    local line = table.concat(row, " | ")
    -- SHOWPLAN emits one result set per statement and sqlcmd repeats the
    -- StmtText header for each, so the header shows up again mid-plan.
    if line ~= header then table.insert(lines, line) end
  end
  return { lines = lines }, nil
end

M._parse_url = parse_url
M._set_go_sqlcmd = function(value) _is_go_sqlcmd = value end
M._parse_sqlcmd_table = parse_sqlcmd_table
M._sqlcmd_args = sqlcmd_args
M._sqlcmd_env = sqlcmd_env
M._sqlcmd_stdin = sqlcmd_stdin
M._normalize_query_sql = normalize_query_sql

return M
