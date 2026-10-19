-- format.lua: SQL formatter for the dadbod-grip query pad.
-- gF in normal mode reformats the query pad buffer.
--
-- Public API:
--   M.format(sql)       -> string  (external tool cascade -> Lua fallback)
--   M.detect_tool()     -> string|nil
--   M._format_lua(sql)  -> string  (pure Lua, always available; exposed for tests)

local M = {}

-- ─── Tokenizer ───────────────────────────────────────────────────────────────
--
-- Produces a flat list of tokens from a SQL string.
-- Each token: { type, text }
--
-- Types:
--   "word"    alphanumeric/underscore run (identifier or keyword candidate)
--             numbers starting with digits are also "word" type
--   "literal" single-quoted string, double-quoted identifier, or dollar-quoted block
--             Content is passed through verbatim - keywords inside are NOT processed.
--   "comment" -- line comment or /* block comment */
--             Content is passed through verbatim.
--   "ws"      whitespace run (spaces, tabs, newlines) - collapsed by the formatter
--   "other"   punctuation or an operator (one to three characters)

-- Multi-character operators, grouped by length. Matched longest-first so that
-- e.g. "->>" is not split into "->" and ">" (which silently corrupted jsonb
-- and array queries in the Lua fallback).
local OP3 = {
  ["->>"] = true, ["#>>"] = true,   -- jsonb path as text
  ["!~*"] = true, ["~~*"] = true,   -- case-insensitive regex / LIKE
  ["<=>"] = true,                   -- MySQL null-safe equality
  ["<<="] = true, [">>="] = true,   -- inet contained-within-or-equals
}
local OP2 = {
  ["!="] = true, ["<>"] = true, ["<="] = true, [">="] = true,
  ["||"] = true, ["::"] = true,
  ["->"] = true, ["#>"] = true,                                 -- jsonb path
  ["@>"] = true, ["<@"] = true, ["&&"] = true,                  -- containment / overlap
  ["<<"] = true, [">>"] = true,                                 -- shift / inet
  ["~~"] = true, ["~*"] = true, ["!~"] = true,                  -- LIKE / regex
  ["@@"] = true,                                                -- full-text match
}

local function tokenize(sql)
  local tokens = {}
  local i = 1
  local n = #sql

  while i <= n do
    local c  = sql:sub(i, i)
    local c2 = sql:sub(i, i + 1)

    -- Line comment: -- ... newline
    if c2 == "--" then
      local nl = sql:find("\n", i + 2, true)
      if nl then
        table.insert(tokens, { type = "comment", text = sql:sub(i, nl) })
        i = nl + 1
      else
        table.insert(tokens, { type = "comment", text = sql:sub(i) })
        i = n + 1
      end

    -- Block comment: /* ... */
    elseif c2 == "/*" then
      local ce = sql:find("*/", i + 2, true)
      if ce then
        table.insert(tokens, { type = "comment", text = sql:sub(i, ce + 1) })
        i = ce + 2
      else
        table.insert(tokens, { type = "comment", text = sql:sub(i) })
        i = n + 1
      end

    -- Dollar-quoted string: $$...$$ or $tag$...$tag$
    -- Uses plain string search (string.find plain=true) so no escaping needed.
    elseif c == "$" then
      local tag_end = sql:find("$", i + 1, true)
      local matched = false
      if tag_end then
        local inner_tag = sql:sub(i + 1, tag_end - 1)
        if inner_tag:match("^[%a_]*$") then   -- valid dollar-quote tag chars
          local tag = sql:sub(i, tag_end)     -- e.g. "$$" or "$func$"
          local cs  = sql:find(tag, tag_end + 1, true)
          if cs then
            table.insert(tokens, { type = "literal", text = sql:sub(i, cs + #tag - 1) })
            i = cs + #tag
            matched = true
          end
        end
      end
      if not matched then
        table.insert(tokens, { type = "other", text = "$" })
        i = i + 1
      end

    -- Single-quoted string: '...' with '' as escaped quote
    elseif c == "'" then
      local j = i + 1
      while j <= n do
        local ch = sql:sub(j, j)
        if ch == "'" then
          if sql:sub(j + 1, j + 1) == "'" then j = j + 2
          else j = j + 1; break end
        else j = j + 1 end
      end
      table.insert(tokens, { type = "literal", text = sql:sub(i, j - 1) })
      i = j

    -- Double-quoted identifier: "..." with "" as escaped quote
    elseif c == '"' then
      local j = i + 1
      while j <= n do
        local ch = sql:sub(j, j)
        if ch == '"' then
          if sql:sub(j + 1, j + 1) == '"' then j = j + 2
          else j = j + 1; break end
        else j = j + 1 end
      end
      table.insert(tokens, { type = "literal", text = sql:sub(i, j - 1) })
      i = j

    -- Whitespace: space, tab, newline
    elseif c:match("^%s$") then
      local j = i + 1
      while j <= n and sql:sub(j, j):match("^%s$") do j = j + 1 end
      table.insert(tokens, { type = "ws", text = sql:sub(i, j - 1) })
      i = j

    -- Variable (@n, @@ROWCOUNT; SQL Server and MySQL): one word, so the formatter
    -- never splits it into "@ n". Operators like @> and <@ have no letter after @.
    elseif sql:match("^@@?[%a_]", i) then
      local j = i + (sql:sub(i + 1, i + 1) == "@" and 2 or 1)
      while j <= n and sql:sub(j, j):match("^[%w_]$") do j = j + 1 end
      table.insert(tokens, { type = "word", text = sql:sub(i, j - 1) })
      i = j

    -- Word: starts with letter, underscore, or digit; continues with [A-Za-z0-9_]
    -- Digits starting sequences are numbers (handled as "word" to preserve sequences
    -- like "1e10", "0x1F", etc.)
    elseif c:match("^[%a_%d]$") then
      local j = i + 1
      while j <= n and sql:sub(j, j):match("^[%w_]$") do j = j + 1 end
      table.insert(tokens, { type = "word", text = sql:sub(i, j - 1) })
      i = j

    -- Multi-char operators: longest match first, before falling to single-char
    elseif OP3[sql:sub(i, i + 2)] then
      table.insert(tokens, { type = "other", text = sql:sub(i, i + 2) })
      i = i + 3

    elseif OP2[c2] then
      table.insert(tokens, { type = "other", text = c2 })
      i = i + 2

    -- Any other single character (operator, punctuation, etc.)
    else
      table.insert(tokens, { type = "other", text = c })
      i = i + 1
    end
  end

  return tokens
end

-- ─── Keyword tables ──────────────────────────────────────────────────────────

-- SQL reserved words to uppercase on encounter.
-- Intentionally excludes function names (COUNT, SUM, etc.) to avoid uppercasing
-- user-defined functions that share names.
local UPCASE = {}
for _, w in ipairs({
  "SELECT", "FROM", "WHERE", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET",
  "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "LATERAL",
  "ON", "USING", "AS", "WITH", "DISTINCT", "ALL", "ASC", "DESC", "NULLS", "LAST", "FIRST",
  "UNION", "INTERSECT", "EXCEPT",
  "AND", "OR", "NOT", "IN", "IS", "NULL", "BETWEEN", "LIKE", "ILIKE", "SIMILAR",
  "CASE", "WHEN", "THEN", "ELSE", "END", "EXISTS", "ANY", "SOME",
  "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "RETURNING",
  "CREATE", "TABLE", "VIEW", "INDEX", "ALTER", "DROP", "IF", "CASCADE", "RESTRICT",
  "WINDOW", "OVER", "PARTITION", "ROWS", "RANGE", "GROUPS",
  "PRECEDING", "FOLLOWING", "CURRENT", "ROW", "UNBOUNDED",
  "PIVOT", "UNPIVOT", "QUALIFY", "SAMPLE", "DESCRIBE", "SHOW", "EXPLAIN", "ANALYZE",
  "FILTER", "WITHIN", "TRUE", "FALSE", "UNKNOWN",
  "TO", "RECURSIVE", "MATERIALIZED", "TEMPORARY", "TEMP",
  "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK", "DEFAULT",
  "CONSTRAINT", "NOT", "DECLARE",
}) do UPCASE[w] = true end

-- Data type names, uppercased like keywords. Kept apart from UPCASE because a
-- type is written like a function call: VARCHAR(50), not VARCHAR (50).
local TYPES = {}
for _, w in ipairs({
  "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT", "HUGEINT",
  "DECIMAL", "NUMERIC", "REAL", "FLOAT", "DOUBLE", "PRECISION", "MONEY", "SMALLMONEY",
  "BIT", "BOOL", "BOOLEAN",
  "CHAR", "NCHAR", "VARCHAR", "NVARCHAR", "CHARACTER", "VARYING", "TEXT", "NTEXT", "CLOB",
  "BINARY", "VARBINARY", "BLOB", "BYTEA", "IMAGE",
  "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "DATETIME", "DATETIME2", "SMALLDATETIME",
  "DATETIMEOFFSET", "INTERVAL", "ZONE",
  "UUID", "UNIQUEIDENTIFIER", "JSON", "JSONB", "XML",
  "SERIAL", "SMALLSERIAL", "BIGSERIAL", "ROWVERSION", "SQL_VARIANT",
}) do TYPES[w] = true end

-- Single-word clause keywords: trigger a newline before them at parenthesis depth 0.
local CLAUSE_SINGLE = {}
for _, w in ipairs({
  "SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "OFFSET", "JOIN", "ON", "WITH",
  "UNION", "INTERSECT", "EXCEPT",
  "PIVOT", "UNPIVOT", "QUALIFY", "SAMPLE",
  "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "RETURNING", "WINDOW",
}) do CLAUSE_SINGLE[w] = true end

-- ─── Multi-word keyword detection ────────────────────────────────────────────

-- Skip past whitespace tokens starting from index `from+1`.
-- Returns (index, upper_text) of the next "word" token, or nil if a non-ws/non-word
-- token is encountered first (which would break a multi-word match).
local function next_word(toks, from)
  local j = from + 1
  while j <= #toks do
    local t = toks[j]
    if     t.type == "word" then return j, t.text:upper()
    elseif t.type == "ws"   then j = j + 1
    else                         return nil
    end
  end
  return nil
end

-- Multi-word clause patterns: maps first_word -> second_word -> result_text
-- (or second_word -> { third_word -> result_text } for three-word compounds)
local MULTI_PATTERNS = {
  GROUP     = { BY    = "GROUP BY" },
  ORDER     = { BY    = "ORDER BY" },
  PARTITION = { BY    = "PARTITION BY" },  -- inside OVER(); depth guard handles it
  INNER     = { JOIN  = "INNER JOIN" },
  CROSS     = { JOIN  = "CROSS JOIN" },
  NATURAL   = { JOIN  = "NATURAL JOIN" },
  UNION     = { ALL   = "UNION ALL" },
  INTERSECT = { ALL   = "INTERSECT ALL" },
  EXCEPT    = { ALL   = "EXCEPT ALL" },
  INSERT    = { INTO  = "INSERT INTO" },
  DELETE    = { FROM  = "DELETE FROM" },
  -- LEFT/RIGHT/FULL: may be JOIN or OUTER JOIN (three words)
  LEFT      = { JOIN  = "LEFT JOIN",  OUTER = { JOIN = "LEFT OUTER JOIN"  } },
  RIGHT     = { JOIN  = "RIGHT JOIN", OUTER = { JOIN = "RIGHT OUTER JOIN" } },
  FULL      = { JOIN  = "FULL JOIN",  OUTER = { JOIN = "FULL OUTER JOIN"  } },
}

-- Compounds that trigger a clause-level newline at depth 0.
local COMPOUND_CLAUSE = {
  ["GROUP BY"]          = true, ["ORDER BY"]           = true,
  ["INNER JOIN"]        = true, ["CROSS JOIN"]         = true,
  ["NATURAL JOIN"]      = true,
  ["LEFT JOIN"]         = true, ["LEFT OUTER JOIN"]    = true,
  ["RIGHT JOIN"]        = true, ["RIGHT OUTER JOIN"]   = true,
  ["FULL JOIN"]         = true, ["FULL OUTER JOIN"]    = true,
  ["UNION ALL"]         = true, ["INTERSECT ALL"]      = true, ["EXCEPT ALL"] = true,
  ["INSERT INTO"]       = true,
  ["DELETE FROM"]       = true,
  ["PARTITION BY"]      = true,  -- only a clause if at depth 0 (rare outside OVER)
}

-- Try to detect a multi-word keyword starting at toks[i].
-- Returns { text, consume } where consume = tokens to skip beyond i,
-- or nil if no match.
local function try_multi(toks, i)
  local w1  = toks[i].text:upper()
  local p2  = MULTI_PATTERNS[w1]
  if not p2 then return nil end

  local j2, w2 = next_word(toks, i)
  if not j2 or not p2[w2] then return nil end

  local val = p2[w2]

  -- Three-word match: LEFT OUTER JOIN, RIGHT OUTER JOIN, FULL OUTER JOIN
  if type(val) == "table" then
    local j3, w3 = next_word(toks, j2)
    if j3 and val[w3] then
      return { text = val[w3], consume = j3 - i }
    end
    -- Two-word fallback for LEFT/RIGHT/FULL not possible when second word is OUTER
    -- and third is missing (unusual). Skip.
    return nil
  end

  return { text = val, consume = j2 - i }
end

-- ─── Pure Lua formatter ──────────────────────────────────────────────────────

local function _format_lua(sql)
  if not sql or sql:match("^%s*$") then return "" end

  local toks   = tokenize(sql)
  local parts  = {}       -- output parts, joined at the end
  local last   = ""       -- last non-empty character emitted
  local depth  = 0        -- parenthesis nesting depth
  local first  = true     -- suppress leading \n before the very first clause keyword
  local last_kw = false   -- was the last meaningful token a SQL keyword?
  -- Clause context at depth 0:
  --   "select"  between SELECT and the next depth-0 FROM
  --   "where"   between WHERE and next depth-0 clause keyword
  --   "having"  between HAVING and next depth-0 clause keyword
  --   "cte"     after WITH before the main query
  --   "none"    everywhere else
  local ctx    = "none"

  local function emit(s)
    if #s > 0 then
      parts[#parts + 1] = s
      last = s:sub(-1)
    end
  end

  -- Append a single space if the last emitted character warrants one.
  -- No space after: nothing, newline, existing space, open-paren, dot.
  local function maybe_space()
    if last ~= "" and last ~= "\n" and last ~= " " and last ~= "(" and last ~= "." then
      emit(" ")
    end
  end

  -- Emit a clause keyword: prepend \n (unless first token in output).
  local function emit_clause(kw)
    if not first then emit("\n") end
    emit(kw)
    first    = false
    last_kw  = true
  end

  -- Update clause context after emitting a clause keyword.
  local function update_ctx(kw)
    local kw1 = kw:match("^%S+")  -- first word of compound
    if     kw == "SELECT"              then ctx = "select"
    elseif kw == "FROM"                then ctx = "none"
    elseif kw == "WHERE"               then ctx = "where"
    elseif kw == "HAVING"              then ctx = "having"
    elseif kw == "WITH"                then ctx = "cte"
    elseif kw == "DELETE FROM"         then ctx = "none"
    elseif kw == "INSERT INTO"         then ctx = "none"
    elseif kw1 == "ORDER" or kw1 == "GROUP" or kw1 == "UNION" or
           kw1 == "INTERSECT" or kw1 == "EXCEPT" or kw:find("JOIN$") or
           kw == "LIMIT" or kw == "OFFSET" or kw == "HAVING" or
           kw == "RETURNING" or kw == "WINDOW" or kw == "ON"  then
      ctx = "none"
    end
  end

  local i = 1
  while i <= #toks do
    local tok = toks[i]

    -- ── Whitespace: skip (we reconstruct spacing) ──────────────────────────
    if tok.type == "ws" then
      i = i + 1

    -- ── Comments and literals: verbatim with spacing ───────────────────────
    elseif tok.type == "comment" or tok.type == "literal" then
      maybe_space()
      emit(tok.text)
      first   = false
      last_kw = false
      i = i + 1

    -- ── Punctuation and operators ──────────────────────────────────────────
    elseif tok.type == "other" then
      local c = tok.text

      if c == "(" then
        -- Space before ( after SQL keywords (e.g. IN (, NOT (, WHERE ().
        -- No space after identifiers (function calls: count(, func(, etc.).
        if last_kw and last ~= "" and last ~= "\n" and last ~= " " then
          emit(" ")
        end
        emit("(")
        depth   = depth + 1
        first   = false
        last_kw = false

      elseif c == ")" then
        depth = depth - 1
        if depth < 0 then depth = 0 end
        emit(")")
        first   = false
        last_kw = false

      elseif c == "," then
        -- Depth-0 commas in SELECT list and CTE list: newline + indent.
        if depth == 0 and (ctx == "select" or ctx == "cte") then
          emit(",\n  ")
        else
          emit(",")
        end
        first   = false
        last_kw = false

      elseif c == ";" then
        emit(";")
        emit("\n")
        ctx   = "none"
        first = true

      elseif c == "." then
        -- No space before or after dots: schema.table, 1.5, memory.main.users
        emit(".")
        first   = false
        last_kw = false

      else
        -- Operators and other single/multi-char tokens: space on both sides.
        maybe_space()
        emit(c)
        first   = false
        last_kw = false
      end
      i = i + 1

    -- ── Words (identifiers and keywords) ──────────────────────────────────
    elseif tok.type == "word" then
      local text  = tok.text
      local upper = text:upper()
      local is_num = text:match("^%d")  -- starts with digit: number literal

      if is_num then
        -- Numbers: emit as-is (no case change, space as needed)
        maybe_space()
        emit(text)
        first   = false
        last_kw = false
        i = i + 1

      else
        -- Try multi-word keyword (only when it could be a clause-start)
        local mw = MULTI_PATTERNS[upper] and try_multi(toks, i) or nil

        if mw then
          local compound = mw.text
          local is_clause_kw = COMPOUND_CLAUSE[compound] and depth == 0

          if is_clause_kw then
            emit_clause(compound)
            update_ctx(compound)
          else
            -- Inside parens or non-clause compound (e.g. PARTITION BY at depth>0):
            -- emit inline with spacing.
            maybe_space()
            emit(compound)
            first   = false
            last_kw = false
          end
          i = i + mw.consume + 1

        else
          -- Single word
          local is_clause_kw = CLAUSE_SINGLE[upper] and depth == 0

          -- AND/OR in WHERE/HAVING context at depth 0 -> indent continuation
          local is_cond_kw = (upper == "AND" or upper == "OR") and depth == 0 and
                              (ctx == "where" or ctx == "having")

          if is_clause_kw then
            emit_clause(upper)
            update_ctx(upper)

          elseif is_cond_kw then
            emit("\n  ")
            emit(upper)
            first   = false
            last_kw = true

          else
            -- Regular word: space if needed, uppercase if keyword
            maybe_space()
            emit((UPCASE[upper] or TYPES[upper]) and upper or text)
            first   = false
            last_kw = UPCASE[upper] == true
          end
          i = i + 1
        end
      end

    else
      i = i + 1
    end
  end

  local result = table.concat(parts)
  -- Collapse multiple blank lines and trim surrounding whitespace.
  result = result:gsub("\n\n+", "\n")
  result = result:match("^%s*(.-)%s*$") or ""
  return result
end

M._format_lua = _format_lua

-- ─── External tool cascade ───────────────────────────────────────────────────

--- Detect the first available external SQL formatter on PATH.
--- Cascade order: sql-formatter (Node), pg_format (Perl), sqlfluff (Python).
--- @return string|nil
function M.detect_tool()
  for _, tool in ipairs({ "sql-formatter", "pg_format", "sqlfluff" }) do
    if vim.fn.executable(tool) == 1 then return tool end
  end
  return nil
end

--- Run an external formatter tool on sql. Returns formatted string or nil on failure.
local function run_external(tool, sql)
  local cmd
  if tool == "sql-formatter" then
    cmd = { "sql-formatter", "--language", "postgresql" }
  elseif tool == "pg_format" then
    cmd = { "pg_format", "-" }
  elseif tool == "sqlfluff" then
    cmd = { "sqlfluff", "fix", "--dialect", "ansi", "--stdin-filename", "query.sql", "-" }
  else
    return nil
  end

  -- vim.fn.system with a list + input avoids shell escaping issues.
  local result = vim.fn.system(cmd, sql)
  if vim.v.shell_error ~= 0 then return nil end
  result = result and result:match("^%s*(.-)%s*$") or ""
  if result == "" then return nil end
  return result
end

--- Format SQL using external tool cascade, falling back to pure Lua.
--- @param sql string
--- @return string
function M.format(sql)
  if not sql or sql:match("^%s*$") then return sql or "" end

  local tool = M.detect_tool()
  if tool then
    local result = run_external(tool, sql)
    if result then return result end
  end

  return _format_lua(sql)
end

return M
