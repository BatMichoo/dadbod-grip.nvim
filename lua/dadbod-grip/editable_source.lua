-- editable_source.lua: decide whether a SELECT reads one base table plainly
-- enough for its result grid to be edited, and which table that is.

local M = {}

-- Share the token stream between projection and source checks: comments and
-- quoted identifiers must never supply a different FROM to either check.
local function tokenize_select(sql_text, adapter_kind)
  local tokens = {}
  local i = 1
  local len = #sql_text
  -- Keep UTF-8 identifier bytes together; punctuation still ends the word.
  local word_start = "[%a_\128-\255]"
  local word_part = "[%w_$\128-\255]"
  local function skip_space()
    while i <= len and sql_text:sub(i, i):match("%s") do i = i + 1 end
  end

  local function read_word()
    local start = i
    if not sql_text:sub(i, i):match(word_start) then return nil end
    i = i + 1
    while i <= len and sql_text:sub(i, i):match(word_part) do i = i + 1 end
    return sql_text:sub(start, i - 1)
  end

  local function read_number()
    local prefix = sql_text:sub(i, i + 1):lower()
    local radix_pattern = prefix == "0x" and "^0[xX]_?[%da-fA-F][%da-fA-F_]*"
      or prefix == "0b" and "^0[bB]_?[01][01_]*"
      or prefix == "0o" and "^0[oO]_?[0-7][0-7_]*"
    local _, finish
    if radix_pattern then
      _, finish = sql_text:find(radix_pattern, i)
      if not finish then return false end
    else
      _, finish = sql_text:find("^%d[%d_]*", i)
      finish = finish or (i - 1)
      if sql_text:sub(finish + 1, finish + 1) == "." then
        _, finish = sql_text:find("^%.[%d_]*", finish + 1)
      end
      local _, exponent_end = sql_text:find("^[eE][+-]?%d[%d_]*", finish + 1)
      finish = exponent_end or finish
    end
    i = finish + 1
    -- Numeric suffixes must not become identifiers in qualification checks.
    return not sql_text:sub(i, i):match(word_start)
  end

  local function read_quoted(quote, escape_string)
    local close_quote = quote == "[" and "]" or quote
    local value = {}
    i = i + 1
    while i <= len do
      local ch = sql_text:sub(i, i)
      if ch == "\\" and quote == "'" then
        local start = i
        while sql_text:sub(i, i) == "\\" do i = i + 1 end
        local odd = (i - start) % 2 == 1
        if escape_string and odd then
          if i > len then return nil end
          i = i + 1
        elseif odd and sql_text:sub(i, i) == "'"
            and (adapter_kind == "postgresql" or adapter_kind == "mysql") then
          -- Session escape settings can change this quote's closing boundary.
          return nil
        end
        value[#value + 1] = sql_text:sub(start, i - 1)
      elseif ch == close_quote then
        if sql_text:sub(i + 1, i + 1) == close_quote then
          value[#value + 1] = close_quote
          i = i + 2
        else
          i = i + 1
          return table.concat(value)
        end
      else
        value[#value + 1] = ch
        i = i + 1
      end
    end
    return nil
  end

  while i <= len do
    skip_space()
    if i > len then break end

    local ch = sql_text:sub(i, i)
    local next_ch = sql_text:sub(i + 1, i + 1)

    if ch == "-" and next_ch == "-" then
      -- MySQL requires whitespace/control after --; otherwise it can be
      -- arithmetic, e.g. total--1 AS status, rather than a comment.
      local following = sql_text:sub(i + 2, i + 2)
      if adapter_kind == "mysql" and following ~= ""
          and not following:match("[%s%c]") then return nil end
      local newline = sql_text:find("[\r\n]", i + 2)
      -- PostgreSQL and DuckDB also end comments at a bare CR. Other clients
      -- differ, so accept their shared CRLF form and reject an ambiguous CR.
      if newline and sql_text:sub(newline, newline) == "\r"
          and sql_text:sub(newline + 1, newline + 1) ~= "\n"
          and adapter_kind ~= "postgresql" and adapter_kind ~= "duckdb" then return nil end
      i = newline and (newline + 1) or (len + 1)
    elseif ch == "/" and next_ch == "*" then
      -- MySQL/MariaDB execute SQL inside these comment forms. Skipping them
      -- could hide an alias or expression from the projection check.
      if adapter_kind == "mysql"
          and (sql_text:sub(i + 2, i + 2) == "!"
            or sql_text:sub(i + 2, i + 3) == "M!") then return nil end
      local depth = 1
      i = i + 2
      while i <= len and depth > 0 do
        local pair = sql_text:sub(i, i + 1)
        if pair == "/*" then
          if adapter_kind ~= "postgresql" then return nil end
          depth = depth + 1
          i = i + 2
        elseif pair == "*/" then
          depth = depth - 1
          i = i + 2
        else
          i = i + 1
        end
      end
      if depth ~= 0 then return nil end
    elseif ch == '"' or ch == "`" or ch == "'"
        or (ch == "[" and adapter_kind ~= "postgresql" and adapter_kind ~= "duckdb") then
      -- The MySQL/MariaDB adapter enables ANSI_QUOTES before each query,
      -- so double quotes denote identifiers there too.
      -- Adjacent string segments retain E-string escapes across newlines.
      local previous = tokens[#tokens]
      local escape_string = ch == "'" and previous and previous.escape_string
      local ident = read_quoted(ch, escape_string)
      if not ident then return nil end
      tokens[#tokens + 1] = {
        kind = ch == "'" and "literal" or "ident", text = ident, escape_string = escape_string,
      }
    elseif ch:match("%d") or (ch == "." and next_ch:match("%d")) then
      if not read_number() then return nil end
      tokens[#tokens + 1] = { kind = "literal" }
    elseif ch:match(word_start) then
      local word = read_word()
      if word:upper() == "E" and sql_text:sub(i, i) == "'"
          and (adapter_kind == "postgresql" or adapter_kind == "duckdb") then
        local value = read_quoted("'", true)
        if not value then return nil end
        tokens[#tokens + 1] = { kind = "literal", text = value, escape_string = true }
      else
        tokens[#tokens + 1] = { kind = "ident", text = word, upper = word:upper() }
      end
    elseif ch == "$" and (adapter_kind == "postgresql" or adapter_kind == "duckdb") then
      local delimiter = sql_text:match("^%$%$", i)
        or sql_text:match("^%$[%a_\128-\255][%w_\128-\255]*%$", i)
      if not delimiter then return nil end
      local close = sql_text:find(delimiter, i + #delimiter, true)
      if not close then return nil end
      tokens[#tokens + 1] = { kind = "literal" }
      i = close + #delimiter
    elseif ch == "$" or (ch == "#" and adapter_kind ~= "postgresql" and adapter_kind ~= "duckdb") then
      return nil
    else
      tokens[#tokens + 1] = { kind = ch }
      i = i + 1
    end
  end
  return tokens
end

-- Expose metadata only for direct columns of one known source. A dotted name
-- may be a struct field, so its qualifier must match the actual table/alias.
local function select_editable_table(sql_text, adapter_kind)
  local tokens = tokenize_select(sql_text, adapter_kind)
  if not tokens or not tokens[1] or tokens[1].upper ~= "SELECT" then return nil end

  local from
  for idx = 2, #tokens do
    if tokens[idx].upper == "FROM" then
      from = idx
      break
    end
  end
  if not from then return nil end

  local pos = from + 1
  local source = {}
  while tokens[pos] and tokens[pos].kind == "ident" do
    local part = tokens[pos]
    if part.upper == "ONLY" or part.upper == "LATERAL" then return nil end
    -- Table metadata represents schema separators as dots; a literal dot in
    -- a quoted name would point mutations at a different qualified table.
    if part.text == "" or part.text:find(".", 1, true) then return nil end
    source[#source + 1] = part
    pos = pos + 1
    if not tokens[pos] or tokens[pos].kind ~= "." then break end
    pos = pos + 1
    if not tokens[pos] or tokens[pos].kind ~= "ident" then return nil end
  end
  if #source == 0 then return nil end

  local clauses = {
    WHERE = true, GROUP = true, HAVING = true, ORDER = true, LIMIT = true,
    OFFSET = true, FETCH = true, FOR = true, WINDOW = true, QUALIFY = true,
  }
  local blocked = {
    JOIN = true, INNER = true, LEFT = true, RIGHT = true, FULL = true,
    CROSS = true, NATURAL = true, UNION = true, INTERSECT = true, EXCEPT = true,
  }
  local set_operations = { UNION = true, INTERSECT = true, EXCEPT = true }
  local alias
  local next_token = tokens[pos]
  if next_token and next_token.upper == "AS" then
    pos = pos + 1
    next_token = tokens[pos]
    if not next_token or next_token.kind ~= "ident" then return nil end
    alias = next_token
    pos = pos + 1
  elseif next_token and next_token.kind == "ident"
      and not clauses[next_token.upper] and not blocked[next_token.upper] then
    alias = next_token
    pos = pos + 1
  end
  next_token = tokens[pos]
  if next_token and next_token.kind ~= ";" and not clauses[next_token.upper] then return nil end

  -- Tail expressions do not change column lineage, but a top-level set
  -- operation can append rows from an unrelated source under the same names.
  local depth = 0
  for idx = pos, #tokens do
    local token = tokens[idx]
    if token.kind == "(" then depth = depth + 1 end
    if token.kind == ")" then depth = depth - 1 end
    -- Require an identifier before the dot: 1. UNION is still a set operation.
    local qualified = idx >= 3 and tokens[idx - 1].kind == "."
      and tokens[idx - 2].kind == "ident"
    if depth < 0 or (depth == 0 and not qualified and set_operations[token.upper]) then return nil end
    if token.kind == ";" and (depth ~= 0 or idx ~= #tokens) then return nil end
  end
  if depth ~= 0 then return nil end

  local function normalized(token)
    if adapter_kind == "postgresql" then
      return token.upper and token.text:lower() or token.text
    end
    return token.text:lower()
  end

  local value_keywords = {
    CURRENT_DATE = true, CURRENT_TIME = true, CURRENT_TIMESTAMP = true,
    ["NULL"] = true,
  }
  local dialect_values = {
    postgresql = {
      "LOCALTIME", "LOCALTIMESTAMP", "CURRENT_CATALOG", "CURRENT_ROLE",
      "CURRENT_SCHEMA", "CURRENT_USER", "SESSION_USER", "SYSTEM_USER", "USER",
      "TRUE", "FALSE",
    },
    mysql = {
      "CURRENT_USER", "CURRENT_ROLE", "LOCALTIME", "LOCALTIMESTAMP",
      "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP", "TRUE", "FALSE",
    },
    sqlserver = { "CURRENT_USER", "SESSION_USER", "SYSTEM_USER", "USER" },
  }
  for _, keyword in ipairs(dialect_values[adapter_kind] or {}) do
    value_keywords[keyword] = true
  end

  pos = 2
  if tokens[pos] and (tokens[pos].upper == "DISTINCT" or tokens[pos].upper == "ALL") then
    pos = pos + 1
  end
  local function consume_item()
    local parts = {}
    while pos < from do
      local token = tokens[pos]
      if token.kind ~= "ident" and token.kind ~= "*" then return false end
      parts[#parts + 1] = token
      pos = pos + 1
      if tokens[pos].kind ~= "." then break end
      if token.kind == "*" then return false end
      pos = pos + 1
      if pos >= from then return false end
    end
    if #parts == 0 then return false end
    if #parts == 1 then
      return not value_keywords[parts[1].upper]
    end
    local qualifiers = #parts - 1
    if alias then
      return qualifiers == 1 and normalized(parts[1]) == normalized(alias)
    end
    if qualifiers == 1 then
      return normalized(parts[1]) == normalized(source[#source])
    end
    if qualifiers ~= #source then return false end
    for idx = 1, qualifiers do
      if normalized(parts[idx]) ~= normalized(source[idx]) then return false end
    end
    return true
  end

  if not consume_item() then return nil end
  while pos < from do
    if tokens[pos].kind ~= "," then return nil end
    pos = pos + 1
    if not consume_item() then return nil end
  end
  local names = {}
  for _, part in ipairs(source) do
    names[#names + 1] = adapter_kind == "postgresql" and normalized(part) or part.text
  end
  return table.concat(names, ".")
end

M.tokenize_select = tokenize_select
M.select_editable_table = select_editable_table

return M
