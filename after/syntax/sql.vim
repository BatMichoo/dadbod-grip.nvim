" after/syntax/sql.vim  -  dadbod-grip supplemental SQL syntax
"
" Loaded automatically when ft=sql (query pad, any SQL buffer).
" Adds distinct highlight groups for SQL roles that the default runtime
" sql.vim collapses into a single 'sqlKeyword -> Statement' group.
"
" Highlight groups are linked to standard @-prefixed semantic tokens so
" any modern Neovim colorscheme renders them with meaningful, distinct colours.
"
" When nvim-treesitter is active its highlights visually win over :syntax;
" this file acts as the fallback for users without the SQL tree-sitter parser.

" Case-insensitive matching for all SQL keyword groups below.
syntax case ignore

" ── DML verbs ──────────────────────────────────────────────────────────────
" SELECT  INSERT  UPDATE  DELETE  MERGE  UPSERT  REPLACE  TRUNCATE
" WITH    UNION   INTERSECT  EXCEPT  ALL  DISTINCT DECLARE
syntax keyword gripSqlDML
  \ SELECT INSERT UPDATE DELETE MERGE UPSERT REPLACE TRUNCATE
  \ WITH UNION INTERSECT EXCEPT ALL DISTINCT DECLARE

" ── Clause keywords ────────────────────────────────────────────────────────
" FROM  WHERE  JOIN family  GROUP BY  ORDER BY  HAVING  etc.
" These are syntactically distinct from DML verbs: they structure queries
" rather than name the operation.
syntax keyword gripSqlClause
  \ FROM WHERE
  \ JOIN LEFT RIGHT INNER OUTER FULL CROSS NATURAL
  \ ON USING
  \ HAVING LIMIT OFFSET FETCH ONLY ROWS
  \ INTO VALUES SET RETURNING
  \ LATERAL RECURSIVE LATERAL
  \ OVER PARTITION WINDOW FILTER
  \ GROUP ORDER BY

" ── Aggregate and built-in functions ───────────────────────────────────────
" avg  count  sum  min  max  coalesce  etc.
" Window functions: row_number  rank  dense_rank  lag  lead  first_value  last_value
syntax keyword gripSqlFunction
  \ avg count sum min max
  \ coalesce nullif cast greatest least
  \ trim ltrim rtrim upper lower length
  \ substr substring split_part
  \ now current_timestamp current_date current_time
  \ date_trunc date_part extract epoch
  \ row_number rank dense_rank
  \ lag lead first_value last_value nth_value ntile
  \ array_agg string_agg json_agg jsonb_agg
  \ to_char to_date to_timestamp to_number
  \ concat concat_ws format replace
  \ round ceil floor abs mod power sqrt
  \ encode decode md5 gen_random_uuid uuid_generate_v4
  \ exists any all some
  \ array_length array_append array_prepend unnest
  \ jsonb_build_object json_build_object jsonb_array_elements json_array_elements
  \ to_json to_jsonb row_to_json
  \ regexp_match regexp_replace regexp_split_to_table
  \ generate_series pg_sleep

" ── Type names ─────────────────────────────────────────────────────────────
syntax keyword gripSqlType
  \ INTEGER INT BIGINT SMALLINT TINYINT SERIAL BIGSERIAL
  \ TEXT VARCHAR CHAR CHARACTER VARYING NVARCHAR
  \ BOOLEAN BOOL
  \ NUMERIC DECIMAL FLOAT REAL DOUBLE PRECISION MONEY
  \ TIMESTAMP TIMESTAMPTZ DATE TIME TIMETZ INTERVAL
  \ UUID JSONB JSON XML BYTEA
  \ ARRAY
  \ INET CIDR MACADDR MACADDR8
  \ POINT LINE LSEG BOX PATH POLYGON CIRCLE
  \ BIT VARBIT
  \ OID REGPROC REGPROCEDURE REGOPER REGOPERATOR REGCLASS REGTYPE

" ── Operators and conditional keywords ────────────────────────────────────
" AND  OR  NOT  IN  LIKE  ILIKE  BETWEEN  IS  NULL  etc.
" CASE  WHEN  THEN  ELSE  END
" AS  (alias keyword - treated as operator-level)
syntax keyword gripSqlOperator
  \ AND OR NOT
  \ IN LIKE ILIKE SIMILAR BETWEEN
  \ IS NULL
  \ CASE WHEN THEN ELSE END
  \ AS
  \ PRIMARY KEY FOREIGN REFERENCES UNIQUE CHECK DEFAULT
  \ INDEX TABLE VIEW CREATE ALTER DROP
  \ IF CONSTRAINT

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
