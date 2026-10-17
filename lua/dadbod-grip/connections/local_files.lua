-- connections/local_files.lua: file-backed connections — recognising them,
-- finding data files in the working directory, and short display names.

local M = {}

local filetypes = require("dadbod-grip.filetypes")


--- Detect if a URL or path points to a file DuckDB can query directly.
local function is_file_url(url)
  if not url or url == "" then return false end
  -- A bare S3 prefix is a supported GripOpen target and expands to a glob.
  if url:match("^s3://") and not filetypes.has_supported_extension(url) then return true end
  return filetypes.has_supported_extension(url)
end

--- Returns true when a connection maps to a local file that filereadable() can test.
--- This includes DuckDB/SQLite file connections in addition to data-format files.
local function is_testable_locally(c)
  if not c then return false end
  if c._local_file or c.type == "file" then return true end
  if not c.url or c.url == "" then return false end
  if c._new or c._temp or c._section_header then return false end
  -- duckdb::memory: has no file to test
  if c.url == "duckdb::memory:" then return false end
  -- SQLite connections are always file-backed
  if c.url:match("^sqlite:") then return true end
  -- DuckDB file connections: duckdb:/path (double-colon = memory, already excluded)
  if c.url:match("^duckdb:[^:]") then return true end
  -- Data-format files (.csv, .parquet, etc.) accessed as local paths
  if is_file_url(c.url) and not c.url:match("^https?://") and not c.url:match("^s3://") then
    return true
  end
  return false
end

--- Strip scheme prefix from a connection URL to get the raw local filesystem path.
local function extract_local_path(url)
  if not url then return url end
  return (url:gsub("^sqlite://", ""):gsub("^sqlite:", "")
             :gsub("^duckdb://", ""):gsub("^duckdb:", ""))
end

--- Format a byte count for compact display (B / KB / MB / GB).
local function fmt_size(bytes)
  if not bytes or bytes < 0 then return "" end
  if bytes < 1024             then return tostring(bytes) .. " B"  end
  if bytes < 1048576          then return string.format("%.1f KB", bytes / 1024) end
  if bytes < 1073741824       then return string.format("%.1f MB", bytes / 1048576) end
  return string.format("%.1f GB", bytes / 1073741824)
end

--- Scan cwd for supported data files and return them as picker-ready items.
--- Scans root of cwd and one level of subdirectories (data/, etc.).
--- Files are sorted alphabetically by display name.
local function scan_local_files()
  local cwd = vim.fn.getcwd()
  local result = {}
  local seen = {}
  for _, ext in ipairs(filetypes.extensions) do
    -- Root-level files: display as bare filename
    local root_files = vim.fn.glob(cwd .. "/*" .. ext, false, true)
    for _, path in ipairs(root_files) do
      if not seen[path] then
        seen[path] = true
        table.insert(result, {
          name        = vim.fn.fnamemodify(path, ":t"),
          url         = path,
          type        = "file",
          _local_file = true,
          size_bytes  = vim.fn.getfsize(path),
        })
      end
    end
    -- One level deep: display as "subdir/filename" so origin is clear
    local sub_files = vim.fn.glob(cwd .. "/*/*" .. ext, false, true)
    for _, path in ipairs(sub_files) do
      if not seen[path] then
        seen[path] = true
        local subdir = vim.fn.fnamemodify(path, ":h:t")
        local fname  = vim.fn.fnamemodify(path, ":t")
        table.insert(result, {
          name        = subdir .. "/" .. fname,
          url         = path,
          type        = "file",
          _local_file = true,
          size_bytes  = vim.fn.getfsize(path),
        })
      end
    end
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

--- Short URL for display: strips credentials, keeps host/dbname or filename only.
local function short_url(url)
  if not url or url == "" then return url end
  -- duckdb::memory: stays as-is
  if url == "duckdb::memory:" then return "duckdb::memory:" end
  -- Strip credentials: scheme://user:pass@host → scheme://host
  local stripped = url:gsub("(://)[^:@/]*:[^@/]*@", "%1")
  stripped = stripped:gsub("(://)[^:@/]*@", "%1")
  -- For postgres/mysql: keep scheme://host/dbname only
  local pg = stripped:match("^(postgres[^:]*://[^/?]+/[^/?]+)")
    or stripped:match("^(mysql[^:]*://[^/?]+/[^/?]+)")
  if pg then
    local out = pg:gsub("^[^:]+://", "")  -- drop scheme
    if #out > 40 then out = out:sub(1, 39) .. "…" end
    return out
  end
  -- For sqlite/duckdb file paths: keep filename only
  local fname = stripped:match("([^/\\]+%.%a+)$")
  if fname then
    if #fname > 40 then fname = fname:sub(1, 39) .. "…" end
    return fname
  end
  -- Fallback: strip scheme, truncate
  local bare = stripped:gsub("^%a[%a%d+%-%.]*://", "")
  if bare == "" then bare = stripped end
  if #bare > 40 then bare = bare:sub(1, 39) .. "…" end
  return bare
end

M.is_file_url = is_file_url
M.is_testable_locally = is_testable_locally
M.extract_local_path = extract_local_path
M.fmt_size = fmt_size
M.scan_local_files = scan_local_files
M.short_url = short_url

return M
