-- view/highlights.lua: Grip highlight groups and the per-connection accent colour.

local M = {}

-- ── highlight group setup ──────────────────────────────────────────────────
-- Groups are re-applied on ColorScheme so they survive :colorscheme switches.
local _hl_ag = vim.api.nvim_create_augroup("DadbodGripHL", { clear = true })

-- Per-connection accent palette. Every hex here is already in use by one of
-- the groups below, so a coloured connection tints the UI with the plugin's
-- own colours instead of introducing a second palette:
--   green  GripBoolTrue/GripInserted   orange GripNullStaged
--   red    GripNegative/GripDeleted    blue   GripUrl/GripWatch
--   violet GripBorder (the default)    yellow GripStatusOk
local ACCENTS = {
  green  = { hex = "#a6e3a1", cterm = 113 },
  orange = { hex = "#fab387", cterm = 216 },
  red    = { hex = "#f38ba8", cterm = 203 },
  blue   = { hex = "#89b4fa", cterm = 117 },
  violet = { hex = "#cba6f7", cterm = 147 },
  yellow = { hex = "#f9e2af", cterm = 229 },
}
-- No connection colour, an entry with no `color`, or a value neither this
-- palette nor #rrggbb: the UI looks exactly as it did before the option
-- existed. This is GripBorder's historical definition.
local DEFAULT_ACCENT = ACCENTS.violet

--- Nearest xterm-256 index for a hex colour.
---
--- Every group in this file pairs a gui hex with a ctermfg, so an accent has
--- to carry one too or a 256-colour terminal would silently drop the colour a
--- palette name still gets. The palette names above ship their index; only a
--- user's own #rrggbb needs approximating.
---
--- The 240 colours above the ANSI 16 are a 6x6x6 cube (levels
--- 0/95/135/175/215/255) plus a 24-step grey ramp (8 + 10i). Both candidates
--- are computed and the nearer one wins: picking the ramp only for an exact
--- r == g == b makes a colour that is grey to within one unit -- #2f2f30 --
--- come back as a saturated dark blue, and picking the cube for every grey
--- loses the ramp's much finer steps.
local function cterm_for(hex)
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  local function dist(cr, cg, cb)
    return (r - cr) ^ 2 + (g - cg) ^ 2 + (b - cb) ^ 2
  end

  -- Cube. The levels are unevenly spaced at the bottom, hence the two special
  -- cases before the arithmetic takes over.
  local function level(v)
    if v < 48  then return 0 end
    if v < 115 then return 1 end
    return math.floor((v - 35) / 40)
  end
  local function level_value(i) return i == 0 and 0 or 55 + i * 40 end
  local ri, gi, bi = level(r), level(g), level(b)
  local cube_d = dist(level_value(ri), level_value(gi), level_value(bi))

  -- Grey ramp, indexed off the average channel.
  local gi_ramp = math.floor(((r + g + b) / 3 - 8) / 10 + 0.5)
  gi_ramp = math.max(0, math.min(23, gi_ramp))
  local grey = 8 + 10 * gi_ramp

  if dist(grey, grey, grey) < cube_d then return 232 + gi_ramp end
  return 16 + 36 * ri + 6 * gi + bi
end

--- A palette name or "#rrggbb" as an accent, or nil for anything else.
--- Unknown values are nil rather than an error: a typo in connections.json
--- must cost the colour, not the connection.
local function resolve_accent(color)
  if type(color) ~= "string" then return nil end
  local named = ACCENTS[color:lower()]
  if named then return named end
  local hex = color:match("^#%x%x%x%x%x%x$")
  if hex then return { hex = hex, cterm = cterm_for(hex) } end
  return nil
end

-- The accent of the connection currently switched to. Read by
-- ensure_highlights, so it is re-applied on every :colorscheme too.
local _accent = nil

local function ensure_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "GripHeader",       { bold = true })
  -- Sticky-header counterpart of GripColHighlight: same bg, so the column the
  -- cursor is in reads the same in the winbar as it does in the grid.
  hl(0, "GripHeaderActive", { bold = true, bg = "#313244", ctermbg = 237 })
  hl(0, "GripNull",         { italic = true, fg = "#6c7086", ctermfg = 243 })
  -- Staged groups carry guibg to visually distinguish pending mutations.
  -- Staged NULL: peach/flamingo fg signals "value cleared" (distinct from red=deleted, violet=modified)
  hl(0, "GripModified",     { bold = true,         fg = "#c084fc", ctermfg = 177, bg = "#1a0a30", ctermbg = 236 })
  hl(0, "GripDeleted",      { strikethrough = true, fg = "#f38ba8", ctermfg = 203, bg = "#2d1418", ctermbg = 236 })
  hl(0, "GripInserted",     { bold = true,         fg = "#a6e3a1", ctermfg = 113, bg = "#162d18", ctermbg = 236 })
  hl(0, "GripNullStaged",   { bold = true,         fg = "#fab387", ctermfg = 216, bg = "#2d1800", ctermbg = 236 })
  hl(0, "GripReadonly",     { italic = true,       fg = "#6c7086", ctermfg = 243 })
  hl(0, "GripStatusOk",     { bold = true,         fg = "#f9e2af", ctermfg = 229 })
  hl(0, "GripStatusChg",    { bold = true,         fg = "#f9e2af", ctermfg = 229 })
  hl(0, "GripNegative",     { bold = true,         fg = "#f38ba8", ctermfg = 203 })
  hl(0, "GripBoolTrue",     { bold = true,         fg = "#a6e3a1", ctermfg = 113 })
  hl(0, "GripBoolFalse",    { bold = true,         fg = "#f38ba8", ctermfg = 203 })
  hl(0, "GripDatePast",     { italic = true,       fg = "#6c7086", ctermfg = 243 })
  hl(0, "GripUrl",          { underline = true,    fg = "#89b4fa", ctermfg = 117 })
  hl(0, "GripWatch",        { bold = true,         fg = "#89b4fa", ctermfg = 117 })
  hl(0, "GripColHighlight", { bg = "#313244", ctermbg = 237 })
  -- Dim marker group: filter-line bullets, column type annotations.
  hl(0, "GripColType",      { fg = "#6c7086", ctermfg = 243 })
  -- Connection accent. GripBorder is defined from it rather than beside the
  -- groups above, so an uncoloured connection restores its historical violet
  -- instead of leaving the last coloured connection's border behind.
  local accent = _accent or DEFAULT_ACCENT
  hl(0, "GripConnAccent",     {              fg = accent.hex, ctermfg = accent.cterm })
  hl(0, "GripConnAccentBold", { bold = true, fg = accent.hex, ctermfg = accent.cterm })
  hl(0, "GripBorder",         { bold = true, fg = accent.hex, ctermfg = accent.cterm })
end
ensure_highlights() -- define groups on module load so welcome screen can use them
vim.api.nvim_create_autocmd("ColorScheme", {
  group    = _hl_ag,
  callback = ensure_highlights,
})

--- Tint the accent groups for the connection being switched to.
---
--- Called from connections.switch() with the entry's `color` -- nil, an
--- unknown name and a non-string all mean "no accent", which restores the
--- defaults rather than leaving the previous connection's colour on screen:
--- coming back from a red prod connection to an uncoloured local one must not
--- keep the red border.
---
--- The accent is stored, not just applied, because ensure_highlights() runs
--- again on every ColorScheme -- that is what keeps the accent alive across a
--- :colorscheme switch.
--- @param color string|nil  a palette name (green/orange/red/blue/violet/yellow) or "#rrggbb"
function M.set_connection_accent(color)
  _accent = resolve_accent(color)
  ensure_highlights()
end

M.ensure = ensure_highlights

return M
