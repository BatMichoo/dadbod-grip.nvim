" after/syntax/sql.vim  -  dadbod-grip supplemental SQL syntax
"
" Loaded automatically when ft=sql (query pad, any SQL buffer).
" Adds distinct highlight groups for SQL roles that the default runtime
" sql.vim collapses into a single 'sqlKeyword -> Statement' group, and the
" T-SQL, PostgreSQL, MySQL, SQLite and DuckDB words its Oracle-flavoured
" default leaves unhighlighted.
"
" Highlight groups are linked to standard @-prefixed semantic tokens so
" any modern Neovim colorscheme renders them with meaningful, distinct colours.
"
" When nvim-treesitter is active its highlights visually win over :syntax;
" this file acts as the fallback for users without the SQL tree-sitter parser.
"
" A keyword highlights wherever it appears, so words that are common column
" names (target, source, next, map, list, ...) are left out on purpose.

" Case-insensitive matching for all SQL keyword groups below.
syntax case ignore

" ── DML verbs and statements ───────────────────────────────────────────────
" SELECT  INSERT  UPDATE  DELETE  MERGE  UPSERT  TRUNCATE
" WITH    UNION   INTERSECT  EXCEPT  ALL  DISTINCT  DECLARE
" T-SQL batches and procedures, transactions, database commands
" REPLACE stays a function (the runtime keyword wins over any match), so
" REPLACE INTO also shows as one.
syntax keyword gripSqlDML
  \ SELECT INSERT UPDATE DELETE MERGE UPSERT TRUNCATE
  \ WITH UNION INTERSECT EXCEPT ALL DISTINCT DECLARE
  \ EXEC PROC RETURNS GO USE PRINT RAISERROR WAITFOR DENY
  \ TRAN TRANSACTION
  \ VACUUM PRAGMA ATTACH DETACH COPY INSTALL LOAD DESCRIBE SHOW SUMMARIZE

" ── Clause keywords ────────────────────────────────────────────────────────
" FROM  WHERE  JOIN family  GROUP BY  ORDER BY  HAVING  etc.
" These are syntactically distinct from DML verbs: they structure queries
" rather than name the operation.
syntax keyword gripSqlClause
  \ FROM WHERE
  \ JOIN LEFT RIGHT INNER OUTER FULL CROSS NATURAL APPLY
  \ ON USING
  \ HAVING LIMIT OFFSET FETCH ONLY ROWS TOP
  \ INTO VALUES SET RETURNING OUTPUT
  \ LATERAL RECURSIVE
  \ OVER PARTITION WINDOW FILTER
  \ RANGE GROUPS PRECEDING FOLLOWING UNBOUNDED EXCLUDE TIES
  \ GROUP ORDER BY NULLS COLLATE
  \ SETS CUBE ROLLUP
  \ PIVOT UNPIVOT QUALIFY SAMPLE TABLESAMPLE
  \ MATCHED CONFLICT DO NOTHING EXCLUDED DUPLICATE IGNORE

" ── Aggregate and built-in functions ───────────────────────────────────────
" avg  count  sum  min  max  coalesce  etc.
" Window functions: row_number  rank  dense_rank  lag  lead  first_value  last_value
syntax keyword gripSqlFunction
  \ avg count sum min max
  \ coalesce nullif cast greatest least
  \ trim ltrim rtrim upper lower length char_length
  \ substr substring split_part repeat
  \ now current_timestamp current_date current_time
  \ current_user session_user system_user
  \ date_trunc date_part extract epoch
  \ row_number rank dense_rank
  \ lag lead first_value last_value nth_value ntile
  \ array_agg string_agg json_agg jsonb_agg
  \ to_char to_date to_timestamp to_number
  \ concat concat_ws format
  \ round ceil floor abs mod power sqrt rand random
  \ encode decode md5 hashbytes gen_random_uuid uuid_generate_v4
  \ exists any some
  \ array_length array_append array_prepend unnest
  \ jsonb_build_object json_build_object jsonb_array_elements json_array_elements
  \ json_object json_array
  \ to_json to_jsonb row_to_json
  \ regexp_match regexp_matches regexp_replace regexp_split_to_table
  \ generate_series pg_sleep typeof last_insert_id

" ── Type names ─────────────────────────────────────────────────────────────
syntax keyword gripSqlType
  \ INTEGER INT BIGINT SMALLINT TINYINT SERIAL BIGSERIAL
  \ INT2 INT4 INT8 FLOAT4 FLOAT8 UBIGINT UINTEGER
  \ TEXT VARCHAR CHAR CHARACTER VARYING NVARCHAR
  \ TINYTEXT MEDIUMTEXT LONGTEXT LONGBLOB ENUM CITEXT
  \ BOOLEAN BOOL
  \ NUMERIC DECIMAL FLOAT REAL DOUBLE PRECISION MONEY
  \ TIMESTAMP TIMESTAMPTZ DATE TIME TIMETZ INTERVAL
  \ UUID JSONB JSON XML BYTEA HSTORE STRUCT
  \ ARRAY
  \ INET CIDR MACADDR MACADDR8
  \ POINT LINE LSEG BOX PATH POLYGON CIRCLE
  \ GEOGRAPHY GEOMETRY HIERARCHYID
  \ TSVECTOR TSQUERY
  \ INT4RANGE INT8RANGE NUMRANGE TSRANGE TSTZRANGE DATERANGE
  \ BIT VARBIT
  \ OID REGPROC REGPROCEDURE REGOPER REGOPERATOR REGCLASS REGTYPE

" ── Operators and conditional keywords ────────────────────────────────────
" AND  OR  NOT  IN  LIKE  ILIKE  BETWEEN  IS  NULL  etc.
" CASE  WHEN  THEN  ELSE  END,  T-SQL control flow
" AS  (alias keyword - treated as operator-level)
" DDL objects and column/table options
syntax keyword gripSqlOperator
  \ AND OR NOT
  \ IN LIKE ILIKE SIMILAR BETWEEN GLOB REGEXP RLIKE
  \ IS NULL UNKNOWN
  \ CASE WHEN THEN ELSE END
  \ IF WHILE BREAK CONTINUE GOTO TRY CATCH THROW
  \ AS
  \ PRIMARY KEY FOREIGN REFERENCES UNIQUE CHECK DEFAULT
  \ CASCADE RESTRICT
  \ INDEX TABLE VIEW CREATE ALTER DROP
  \ SCHEMA DATABASE SEQUENCE TEMPORARY TEMP MATERIALIZED
  \ GENERATED ALWAYS STORED VIRTUAL IDENTITY
  \ AUTO_INCREMENT AUTOINCREMENT UNSIGNED ENGINE
  \ NOLOCK NOCOUNT XACT_ABORT
  \ CONSTRAINT

" ── Words shared with the SQL formatter ────────────────────────────────────
" T-SQL types (DATETIME2, UNIQUEIDENTIFIER, ...) and dialect functions
" (ISNULL, IIF, DATEADD, ...) the formatter also knows. One list in format.lua
" feeds both; defined last so these win over the runtime groups.
let s:words = luaeval('require("dadbod-grip.format").syntax_words')
execute 'syntax keyword gripSqlDML' join(s:words.statements)
execute 'syntax keyword gripSqlType' join(s:words.types)
execute 'syntax keyword gripSqlFunction' join(s:words.functions)
unlet s:words

" ── Highlight group links ──────────────────────────────────────────────────
" Using @-prefixed groups: they map to standard semantic tokens understood
" by Tree-sitter-aware colorschemes (catppuccin, tokyonight, gruvbox-flat,
" kanagawa, etc.).  Each @group falls back to a legacy group if undefined,
" so classic colorschemes also work.
"
"   @keyword           -> Keyword      (DML verbs: SELECT, INSERT, ...)
"   @tag               -> Tag          (clause words: FROM, WHERE, JOIN, ...)
"   @function.builtin  -> Function     (aggregate/built-in fns: avg, count, ...)
"   @type              -> Type         (SQL type names: INTEGER, JSONB, ...)
"   @keyword.operator  -> Operator     (AS, AND, IN, LIKE, CASE ...)
"
" Note: @tag is used for gripSqlClause (not @keyword.return) because Catppuccin
" Mocha and similar themes alias all @keyword.* groups to the same color. @tag
" maps to blue (#89b4fa in Catppuccin) which is visually distinct from keywords.

highlight default link gripSqlDML      @keyword
highlight default link gripSqlClause   @tag
highlight default link gripSqlFunction @function.builtin
highlight default link gripSqlType     @type
highlight default link gripSqlOperator @keyword.operator
