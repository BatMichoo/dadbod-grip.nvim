-- truncate_display_spec.lua
-- Contract: view._truncate_display(s, width, ellipsize) returns (truncated_string,
-- display_width) truncated to fit `width` display cells, appending an ellipsis
-- unless ellipsize == false.
--
-- An ASCII fast path (view.lua: bytes in \32-\126 only) skips the per-character
-- vim.fn.strdisplaywidth loop and uses s:sub() instead, since for that byte
-- range 1 byte == 1 char == 1 display cell.
--
-- Two layers of protection:
--   1. Fixed expectations below, written out by hand. These would catch a bug
--      that both implementations share.
--   2. A differential section at the bottom that keeps a verbatim copy of the
--      pre-optimisation implementation as an oracle and compares the two over a
--      large generated corpus, plus guards asserting the fast path is actually
--      taken. That runs on every test run rather than once in a throwaway
--      harness.
--
-- Cases intentionally probe the fast-path boundary: the printable-ASCII range
-- \32 (space) - \126 (~) must exclude tab (\9, whose width depends on
-- 'tabstop'), other control bytes and DEL (\127, both rendered as 2-cell
-- "^X"/"^?" by strdisplaywidth), and any byte >= 0x80 (multibyte UTF-8), all
-- of which must still take the slow path.
dofile("tests/minimal_init.lua")
local view = require("dadbod-grip.view")
local truncate_display = view._truncate_display

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end

local function check(label, s, width, ellipsize, want_s, want_w)
  test(label, function()
    local got_s, got_w = truncate_display(s, width, ellipsize)
    eq(got_s, want_s, label .. " (string)")
    eq(got_w, want_w, label .. " (width)")
  end)
end

-- ── ASCII fast path ──────────────────────────────────────────────────────
check("ascii short, room to spare", "hello", 10, true, "hello", 5)
check("ascii exact width", "hello", 5, true, "hello", 5)
check("ascii truncate w/ ellipsis", "hello world", 8, true, "hello w…", 8)
check("ascii truncate no ellipsis", "hello world", 8, false, "hello wo", 8)
check("ascii truncate width=1 (ellipsis only)", "hello world", 1, true, "…", 1)
check("ascii truncate width=0", "hello world", 0, true, "", 0)
check("ascii boundary bytes 0x20 and 0x7e only", " ~", 5, true, " ~", 2)
check("mixed ascii+control, fits (slow path, no truncation)", "ab\1cd", 20, true, "ab\1cd", 6)

-- ── empty / nil-ish ──────────────────────────────────────────────────────
check("empty string", "", 5, true, "", 0)
check("empty string, width=0", "", 0, true, "", 0)

-- ── non-ASCII: cyrillic, CJK, emoji, accented latin (slow path) ──────────
check("cyrillic short", "привет", 10, true, "привет", 6)
check("cyrillic exact width", "привет", 6, true, "привет", 6)
check("cyrillic truncate w/ ellipsis", "привет мир", 8, true, "привет …", 8)
check("cyrillic truncate no ellipsis", "привет мир", 8, false, "привет м", 8)
check("cyrillic truncate width=1", "привет мир", 1, true, "…", 1)

check("CJK short", "你好", 10, true, "你好", 4)
check("CJK exact width (2 cells/char)", "你好世界", 8, true, "你好世界", 8)
check("CJK truncate w/ ellipsis", "你好世界你好世界", 8, true, "你好世…", 7)
check("CJK truncate no ellipsis", "你好世界你好世界", 8, false, "你好世界", 8)
check("CJK truncate width=1 (narrower than one CJK cell)", "你好世界", 1, true, "…", 1)

check("emoji short", "😀😀", 10, true, "😀😀", 4)
check("emoji truncate w/ ellipsis", "😀😀😀😀😀", 6, true, "😀😀…", 5)
check("emoji truncate no ellipsis", "😀😀😀😀😀", 6, false, "😀😀😀", 6)

check("accented latin (2-byte utf8)", "café résumé", 8, true, "café ré…", 8)
check("accented latin exact width", "café", 4, true, "café", 4)

-- ── tabs: must NOT take the ASCII fast path (width depends on 'tabstop') ──
check("tab in middle, ellipsis", "a\tb\tc", 5, true, "a…", 2)
check("tab in middle, no ellipsis", "a\tb\tc", 5, false, "a", 1)
check("tab only", "\t\t", 3, true, "…", 1)

-- ── control chars / DEL: must NOT take the ASCII fast path (render as ^X/^?) ─
check("control char (SOH) renders as ^A", "a\1b", 3, true, "a…", 2)
check("control char truncated", "abc\1def", 4, true, "abc…", 4)
check("DEL char renders as ^?", "a\127b", 3, true, "a…", 2)
check("DEL truncated", "abc\127def", 4, true, "abc…", 4)
check("byte 0x1f control (just below space)", "a\31b", 3, true, "a…", 2)
check("byte 0x7f DEL boundary, fits without truncation", "a\127", 3, true, "a\127", 3)

-- ── ellipsis-width edge case ───────────────────────────────────────────────
check("width == ellipsis width exactly", "hello world", 1, true, "…", 1)

-- ── differential test against the pre-optimisation implementation ──────────

--- The implementation as it was before the fast path: every character's width
--- comes from vim.fn. This is the oracle; it must never grow a shortcut.
local function reference(s, width, ellipsize)
  s = tostring(s or "")
  if width <= 0 then return "", 0 end

  local dw = vim.fn.strdisplaywidth(s)
  if dw <= width then return s, dw end

  local ell = ellipsize ~= false and "…" or ""
  local ell_w = vim.fn.strdisplaywidth(ell)
  if ell ~= "" and ell_w <= width and width <= ell_w then
    return ell, ell_w
  end

  local target = math.max(0, width - ell_w)
  local out = {}
  local used = 0
  for i = 0, vim.fn.strchars(s) - 1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if used + cw > target then break end
    out[#out + 1] = ch
    used = used + cw
  end

  if ell ~= "" and used + ell_w <= width then
    out[#out + 1] = ell
    used = used + ell_w
  end
  return table.concat(out), used
end

local function differs(s, width, ellipsize)
  local got_s, got_w = truncate_display(s, width, ellipsize)
  local exp_s, exp_w = reference(s, width, ellipsize)
  if got_s == exp_s and got_w == exp_w then return nil end
  return string.format("%q width=%s ellipsize=%s: reference (%q,%s), got (%q,%s)",
    tostring(s), tostring(width), tostring(ellipsize),
    exp_s, tostring(exp_w), got_s, tostring(got_w))
end

local corpus = {
  -- pure printable ASCII: the fast path
  "", " ", "a", "ab", "hello world", "SELECT * FROM users WHERE id = 42",
  "0123456789", "-1.5e10", "NULL", "~", "!", "  padded  ", string.rep("x", 200),
  "quote'and\"double", "back\\slash",
  -- bytes just outside the range, at both ends and both positions
  "\31low", "low\31", "a\127b", "\127", "\1", "a\1", "\126\127",
  -- control characters and whitespace that is not a plain space
  "\tleading", "mid\ttab", "embedded\nnewline", "\r\n", "bell\7here",
  -- multi-byte, wide, combining
  "café", "ünïcödé", "привет мир", "日本語テキスト", "混合 mixed 文字",
  "emoji 🚀 here", "🚀🚀🚀", "e\204\129", "→ arrow", "…", "……", "a…b",
  "Ａ", "ＡＢＣ", "ascii-then-é", "é-then-ascii",
}
local widths = { -5, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 15, 32, 33, 199, 200, 201 }

test("differential: corpus × widths × ellipsize", function()
  local checked = 0
  for _, s in ipairs(corpus) do
    for _, w in ipairs(widths) do
      for _, ellipsize in ipairs({ true, false }) do
        local msg = differs(s, w, ellipsize)
        assert(not msg, msg)
        checked = checked + 1
      end
    end
  end
  eq(checked, #corpus * #widths * 2, "corpus fully covered")
end)

test("differential: every printable ASCII byte at every small width", function()
  for byte = 32, 126 do
    local ch = string.char(byte)
    for _, s in ipairs({ ch, ch .. ch, "pre" .. ch .. "post" }) do
      for w = 1, 8 do
        local msg = differs(s, w, true)
        assert(not msg, msg)
      end
    end
  end
end)

test("differential: non-string and nil arguments", function()
  for _, w in ipairs({ 0, 1, 5 }) do
    for _, v in ipairs({ 42, -1.5, true }) do
      local msg = differs(v, w, true)
      assert(not msg, msg)
    end
    local got_s, got_w = truncate_display(nil, w)
    local exp_s, exp_w = reference(nil, w)
    eq(got_s, exp_s, "nil at width " .. w)
    eq(got_w, exp_w, "nil width at " .. w)
  end
end)

test("differential: 2000 random ASCII strings", function()
  math.randomseed(20260727)
  for _ = 1, 2000 do
    local chars = {}
    for i = 1, math.random(0, 40) do chars[i] = string.char(math.random(32, 126)) end
    local msg = differs(table.concat(chars), math.random(-2, 45), math.random(2) == 1)
    assert(not msg, msg)
  end
end)

test("differential: 2000 random mixed ASCII / multi-byte strings", function()
  math.randomseed(20260728)
  local pool = { "a", "Z", "7", " ", "~", "é", "日", "🚀", "→", "\t", "\n", "\127", "\1" }
  for _ = 1, 2000 do
    local parts = {}
    for i = 1, math.random(0, 12) do parts[i] = pool[math.random(#pool)] end
    local msg = differs(table.concat(parts), math.random(-2, 30), math.random(2) == 1)
    assert(not msg, msg)
  end
end)

-- The point of the change: ASCII input must not touch vim.fn per character.
test("ASCII input makes no per-character vim.fn calls", function()
  local real_strcharpart, real_strchars = vim.fn.strcharpart, vim.fn.strchars
  local calls = 0
  vim.fn.strcharpart = function(...) calls = calls + 1; return real_strcharpart(...) end
  vim.fn.strchars   = function(...) calls = calls + 1; return real_strchars(...) end
  local ok, err = pcall(function()
    truncate_display(string.rep("abcdef", 40), 20)
    truncate_display("short", 100)
    truncate_display("SELECT * FROM users", 10, false)
  end)
  vim.fn.strcharpart, vim.fn.strchars = real_strcharpart, real_strchars
  if not ok then error(err, 0) end
  eq(calls, 0, "per-character vim.fn calls on the ASCII path")
end)

test("non-ASCII input is cut on character boundaries", function()
  local out, w = truncate_display("日本語テキストです", 6)
  eq(out, "日本…", "two wide characters and the marker")
  eq(w, 5, "display width")
  eq(vim.fn.strdisplaywidth(out), w, "reported width matches the screen")
end)

print(string.format("\ntruncate_display_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
