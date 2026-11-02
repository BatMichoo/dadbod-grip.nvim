-- ui.lua: shared UI primitives for dadbod-grip.
-- Kept small: only patterns that are reused across modules.

local M = {}

-- ── display-width text layout ─────────────────────────────────────────────
-- Shared by view.lua (the grid) and properties.lua/profile.lua/diff.lua (the
-- auxiliary report views), so alignment logic for non-ASCII column/cell
-- values (Cyrillic, CJK, emoji) lives in one place. er_diagram.lua does NOT
-- use this: it already routes every width through vim.fn.strdisplaywidth
-- directly and keeps its own truncate_col (verified correct, Task 11).
--
-- Bytes \32-\126 are exactly space..~ printable ASCII. The range deliberately
-- excludes tab (\9, whose width depends on 'tabstop'), every other control byte
-- and DEL (strdisplaywidth renders those as a 2-cell "^X"), and everything
-- >= 0x80 (UTF-8 lead/continuation bytes). For a string of only such bytes, and
-- only then, one byte is one character is one display cell — so #s is the
-- display width and s:sub(1, n) is a correctly truncated prefix, with no vim.fn
-- round-trip per character. That is the common case for a grid of numbers, ids
-- and short labels, which is why it is worth a branch.
--
--- Display width of one character. nvim_strwidth is the faster call but
--- counts a tab or another control character as one cell, where the screen
--- shows a tab expanded and ^A as two; strdisplaywidth handles those.
--- (For a whole string strdisplaywidth stays: scanning it for control
--- characters first costs more than nvim_strwidth saves.)
local function char_width(ch)
  local b = ch:byte(1)
  if b < 32 or b == 127 then return vim.fn.strdisplaywidth(ch) end
  return vim.api.nvim_strwidth(ch)
end

--- Truncate `s` to fit `width` display cells. When it doesn't fit and
--- `ellipsize ~= false`, cuts to width - width(marker) cells and appends
--- `marker` (default "…"); properties.lua/diff.lua use "~" to match their
--- established style. `ellipsize == false` just cuts to fit, no marker.
--- @return string truncated, integer display_width
function M.truncate_display(s, width, ellipsize, marker)
  s = tostring(s or "")
  if width <= 0 then return "", 0 end

  local ascii = not s:find("[^\32-\126]")

  local dw = ascii and #s or vim.fn.strdisplaywidth(s)
  if dw <= width then return s, dw end

  local ell = ellipsize ~= false and (marker or "…") or ""
  -- Not hoisted to a constant: 'ambiwidth' can change at runtime.
  local ell_w = vim.fn.strdisplaywidth(ell)
  if ell ~= "" and ell_w == width then
    return ell, ell_w
  end

  local target = math.max(0, width - ell_w)
  local out, used
  if ascii then
    -- dw > width >= target, so the prefix is always exactly `target` bytes.
    out = s:sub(1, target)
    used = #out
  else
    local parts = {}
    used = 0
    -- One UTF-8 character per match (a lead byte plus its continuation bytes)
    for ch in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
      local cw = char_width(ch)
      if used + cw > target then break end
      parts[#parts + 1] = ch
      used = used + cw
    end
    out = table.concat(parts)
  end

  if ell ~= "" and used + ell_w <= width then
    out = out .. ell
    used = used + ell_w
  end
  return out, used
end

--- Truncate (see M.truncate_display) then right-pad with spaces to exactly
--- `width` display cells.
--- @return string padded, integer display_width_before_padding
function M.pad_display(s, width, ellipsize, marker)
  local trimmed, dw = M.truncate_display(s, width, ellipsize, marker)
  return trimmed .. string.rep(" ", math.max(0, width - dw)), dw
end

--- Slice `width` display cells out of `s`, starting `from` cells in.
--- `from` is 0-based and in the same units as winsaveview().leftcol.
--- @return string
function M.slice_display(s, from, width)
  s = tostring(s or "")
  if width <= 0 then return "" end

  local out, used, skipped = {}, 0, 0
  for i = 0, vim.fn.strchars(s) - 1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if skipped + cw <= from then
      skipped = skipped + cw
    elseif skipped < from then
      -- `from` lands inside a wide glyph: only its trailing cells are visible.
      -- Emitting the glyph itself would pull everything after it one cell left
      -- of the grid row underneath, so pad with what is actually on screen.
      local visible = math.min(skipped + cw - from, width - used)
      out[#out + 1] = string.rep(" ", visible)
      used = used + visible
      skipped = skipped + cw
    else
      if used + cw > width then
        -- Mirror of the `from` case at the right edge: a glyph straddling the
        -- end of the slice contributes only the cells that fit.
        out[#out + 1] = string.rep(" ", width - used)
        break
      end
      out[#out + 1] = ch
      used = used + cw
    end
  end
  return table.concat(out)
end

--- Return the configured float border style.
--- Lazy-requires init to avoid circular dependency.
function M.border()
  return require("dadbod-grip.config").values.border
end

local function report_height(line_count)
  return math.min(30, line_count + 2)
end

--- Open a read-only report in a bottom split and return its buffer and window.
---
--- The shape shared by GripDiff and GripProfile: a named scratch buffer, a
--- botright split sized to the content (capped at 30 lines), cursorline on and
--- wrap off. Callers add their own highlights and keymaps afterwards.
---
--- @param lines string[]  report body
--- @param name  string    buffer name, e.g. "grip://profile/users"
--- @return integer bufnr, integer winid
function M.report_split(lines, name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  pcall(vim.api.nvim_buf_set_name, bufnr, name)

  vim.cmd("botright split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_height(winid, report_height(#lines))
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("wrap", false, { win = winid })

  return bufnr, winid
end

M._report_height = report_height

--- Prompt on the cmdline; return nil when the user cancels.
---
--- vim.fn.input() signals a cancel two ways: <Esc> returns `cancelreturn`, while
--- <C-c> raises. Both mean nil here. An empty answer counts as a cancel too
--- unless `allow_empty` is set — which is what almost every prompt here wants.
---
--- vim.fn.input() and not vim.ui.input() on purpose: it always uses the native
--- cmdline, so it is never intercepted by dressing.nvim/noice floats.
---
--- @param opts table   prompt, default?, completion?, allow_empty?
--- @return string|nil  the answer, or nil if cancelled
function M.input(opts)
  local CANCEL = "\0"
  local ok, answer = pcall(vim.fn.input, {
    prompt       = opts.prompt,
    default      = opts.default,
    completion   = opts.completion,
    cancelreturn = CANCEL,
  })
  if not ok or answer == CANCEL then return nil end
  if answer == "" and not opts.allow_empty then return nil end
  return answer
end

--- Ask a yes/no question. Only a literal "y"/"yes" is a yes; anything else —
--- including an empty answer or a cancel — is a no.
--- @param prompt string  spell out the default, e.g. "Drop table? (y/N): "
--- @return boolean
function M.confirm(prompt)
  local answer = M.input({ prompt = prompt, allow_empty = true })
  return answer == "y" or answer == "yes"
end

--- Fit a float to the screen it is drawn on.
---
--- Callers size these floats to their content, and content is regularly larger
--- than the editor: the `?` help is 164 rows. In a TUI Neovim clamps such a
--- window for us, so it ends up shorter than its buffer and scrolls. Under
--- `ext_multigrid` the UI draws windows itself and Neovim hands out the size
--- that was asked for: the whole buffer then fits inside the window, so
--- nothing ever scrolls and everything past the screen edge is unreachable --
--- `<C-d>` and `G` both leave `topline` at 1. Neovide runs that way, and the
--- help is unusable there without this.
---
--- The same four cells come off both axes, for different reasons: vertically
--- two rows of border plus the status line and the command line, horizontally
--- two columns of border plus one spare column on each side, which keeps a
--- full-width frame off the screen edge. The offset is the one this module has
--- always used, so a float that already fits opens exactly where it did
--- before, and a fitted one lands on [1, total - 2] with its frame whole.
---
--- @param size  integer requested rows or columns
--- @param total integer rows or columns the editor has
--- @return integer size, integer offset
function M.fit(size, total)
  local fitted = math.min(size, math.max(1, total - 4))
  return fitted, math.floor((total - fitted) / 2)
end

--- Keep a caller's own offset on screen. Counting its border, a float occupies
--- [offset - 1, offset + size], so total - 1 - size is the last offset that
--- leaves the far edge of the frame visible.
---
--- A caller that derives an offset from content it never clamped -- editor.lua
--- centres its error float on its line count -- otherwise pushes the float off
--- the top of the editor, and what runs off is unreachable there for the same
--- reason an oversized float's tail is. Flush against the near edge is a
--- placement a caller can mean, though, so 0 is left alone: only what would
--- land outside the editor is pulled back.
---
--- @param offset integer requested row or column
--- @param size   integer fitted rows or columns of the float
--- @param total  integer rows or columns the editor has
--- @return integer offset
local function onscreen(offset, size, total)
  return math.max(0, math.min(offset, total - 1 - size))
end

--- Open an editor-relative float and return its window and buffer.
---
--- Covers only what the info floats across the plugin share: a scratch buffer,
--- centered geometry, style = "minimal" and the configured border. How big a
--- float wants to be stays with the caller — every float has its own idea of
--- how wide it should be — but how big it is allowed to be does not: whatever
--- is asked for goes through M.fit, so no caller can ask for a float larger
--- than the screen. Keys left nil are not passed to nvim_open_win at all, so a
--- caller that never set `title`/`zindex` keeps the stock window it had before.
---
--- @param opts table
---   lines      string[]|nil  fill a fresh scratch buffer with these
---   buf        integer|nil   use this buffer instead of creating one (pass it
---                            when buffer options must be set before the window
---                            exists, e.g. filetype)
---   width      integer       required
---   height     integer       required
---   relative   string|nil    default "editor"
---   row, col   integer|nil   default: centered for the fitted width/height.
---                            An editor-relative float is held on screen,
---                            frame included, whether the offset is the
---                            caller's or the default; against anything else
---                            the caller's offset is passed through untouched
---                            and defaults to 0.
---   enter      boolean|nil   focus the float (default true)
---   style, border, title, title_pos, zindex, footer, footer_pos
---                            forwarded as-is; style/border default to
---                            "minimal" / M.border()
--- @return integer win, integer buf
function M.info_float(opts)
  local buf = opts.buf
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    if opts.lines then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
    end
  end

  local relative    = opts.relative or "editor"
  local height, row = M.fit(opts.height, vim.o.lines)
  local width,  col = M.fit(opts.width,  vim.o.columns)

  -- Both offsets are editor coordinates, so they only mean anything for an
  -- editor-relative float: there the caller's own offset is held on screen
  -- alongside the centred default. Against the cursor the caller owns its
  -- placement outright -- editor.lua opens above the cursor row with a
  -- negative offset, which clamping would throw away -- so nothing is imposed
  -- on it beyond the size.
  if relative == "editor" then
    row = onscreen(opts.row or row, height, vim.o.lines)
    col = onscreen(opts.col or col, width,  vim.o.columns)
  else
    row = opts.row or 0
    col = opts.col or 0
  end

  local cfg = {
    relative  = relative,
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = opts.style or "minimal",
    border    = opts.border or M.border(),
    title     = opts.title,
    title_pos = opts.title_pos,
    zindex    = opts.zindex,
  }

  local enter = opts.enter ~= false

  -- A footer needs a border; fall back silently when nvim rejects the config
  -- (border = "none").
  if opts.footer then
    local with_footer = vim.tbl_extend("force", cfg,
      { footer = opts.footer, footer_pos = opts.footer_pos })
    local ok, win = pcall(vim.api.nvim_open_win, buf, enter, with_footer)
    if ok then return win, buf end
  end

  return vim.api.nvim_open_win(buf, enter, cfg), buf
end

--- Wire the standard dismissal for a focused info float: `q` and `<Esc>` close
--- it and hand focus back to the window it was opened from, and leaving the
--- float's window closes it as well.
---
--- The augroup is a parameter, not a constant: each module registers the
--- WinLeave in its own group so that its own reload/clear keeps owning it.
---
--- close() owns the whole float: it drops the autocmd, closes the window and
--- deletes the buffer. The buffer has to go with the window — info_float's
--- scratch buffer is unlisted with bufhidden=hide, so closing only the window
--- leaves it hidden (and invisible to :ls) for the rest of the session, one
--- more every time a float is opened. Deleting it is also what retires the
--- buffer-local WinLeave when the float was opened with `enter = false`: a
--- window that was never entered is never left, so the autocmd would otherwise
--- outlive the float it was watching.
---
--- @param opts table
---   win        integer  the float window
---   buf        integer  the float buffer (keymaps and WinLeave are buffer-local)
---   caller_win integer  window to focus after q/<Esc>
---   group      integer  augroup id for the WinLeave autocmd
--- @return function close  closes the float without moving focus
function M.dismiss_float(opts)
  local win, buf, caller_win = opts.win, opts.buf, opts.caller_win

  local au_id

  -- Every step is guarded and nothing is allowed to raise: close() runs twice
  -- whenever it is called by hand from a window it is also watching (the manual
  -- call plus the WinLeave it triggers), the window may already be gone because
  -- the user typed :q, and the second half of it runs inside an autocmd.
  local function close()
    -- Dropping the autocmd up front, before the window goes, is what keeps
    -- close() from being re-entered through the WinLeave that closing a focused
    -- float fires: no redundant close gets scheduled to land after the caller
    -- has moved on (properties.lua's gI closes and reopens in one breath).
    -- `once = true` already dropped the id if the WinLeave did fire, hence pcall.
    if au_id then
      pcall(vim.api.nvim_del_autocmd, au_id)
      au_id = nil
    end
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  au_id = vim.api.nvim_create_autocmd("WinLeave", {
    group  = opts.group,
    buffer = buf,
    once = true,
    callback = function() vim.schedule(close) end,
  })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      close()
      if vim.api.nvim_win_is_valid(caller_win) then
        vim.api.nvim_set_current_win(caller_win)
      end
    end, { buffer = buf })
  end

  return close
end

-- Neovim 0.12 progress messages (nvim_echo kind="progress"): shown by ui2, the
-- default cmdline, statusline components (vim.ui.progress_status()) and
-- progress plugins alike. Older versions get the spinner float.
local HAS_PROGRESS = vim.fn.has("nvim-0.12") == 1

-- Test seam: nil decides by version and attached UI, true/false forces it.
local _force_progress = nil
function M._set_progress(value)
  _force_progress = value
end

--- Whether blocking() reports through progress messages. Without a UI (a
--- headless script) nvim_echo writes to stdout, so it keeps the float there.
local function use_progress()
  if _force_progress ~= nil then return _force_progress end
  return HAS_PROGRESS and #vim.api.nvim_list_uis() > 0
end

-- While the outermost blocking() call runs on progress messages, notifications
-- are queued here and shown after its final progress update, which would
-- otherwise paint over them in the default cmdline.
local _held = nil

--- Whether vim.notify is still Neovim's own, which ignores its opts (so no
--- message id) and just calls nvim_echo, rather than a notification plugin's.
local function core_notify()
  local source = debug.getinfo(vim.notify, "S").source
  -- "vim/_core/editor" when precompiled, a path ending in editor.lua if not.
  return source:find("vim/_core/editor", 1, true) ~= nil
end

--- vim.notify for a status message that replaces its previous one instead of
--- stacking up: a toggle flipped twice, an undo countdown, repeated yanks.
--- On Neovim 0.12 with the built-in vim.notify it is echoed with a message id,
--- which ui2 uses to update the message in place (:messages still keeps each
--- one); a notification plugin receives the id as opts.id, which the ones that
--- support replacing use.
--- @param msg   string
--- @param level integer|nil  vim.log.levels
--- @param id    string       per-purpose name, e.g. "watch"
function M.notify(msg, level, id)
  if _held then
    _held[#_held + 1] = function() M.notify(msg, level, id) end
    return
  end
  id = "dadbod-grip." .. id
  if HAS_PROGRESS and core_notify() then
    -- Same rendering as the built-in vim.notify, plus the id.
    vim.api.nvim_echo({ { msg, level == vim.log.levels.WARN and "WarningMsg" or nil } }, true,
      { id = id, err = level == vim.log.levels.ERROR })
  else
    vim.notify(msg, level, { id = id })
  end
end

-- { ok, r1, r2, ... } with the count kept in `n`: `#` stops at the first nil,
-- so a plain table would drop the err of a (nil, nil, err) return.
local function pack(...)
  return { n = select("#", ...), ... }
end

-- table.unpack is nil on the LuaJIT Neovim embeds; probed so this keeps
-- working if Neovim ever moves to a 5.2+ VM, where bare `unpack` is gone.
local unpack_ = table.unpack or unpack -- luacheck: ignore 143

--- Spinner float, centered on the editor (Neovim < 0.12).
local function float_spinner(msg)
  local spinner = { msg = msg }
  local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local fi = 1

  local display = "  " .. msg
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  " .. display, "" })
  local w = math.min(vim.fn.strdisplaywidth(display) + 6, vim.o.columns - 4)

  -- Suppress plugin autocmds during float create to avoid 200-400ms overhead.
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", style = "minimal", border = M.border(),
    width    = w, height = 3,
    row      = math.floor((vim.o.lines   - 3) / 2),
    col      = math.floor((vim.o.columns - w) / 2),
    noautocmd = true,
  })

  -- Best-effort paint before fn() runs. Keep this on Neovim's stable Ex
  -- command rather than the experimental nvim__redraw API.
  pcall(vim.cmd, "redraw")

  -- Animate: timer fires during vim.system():wait() and vim.wait() event loop pumps.
  -- libuv timer callbacks are "fast events" - nvim API calls are forbidden there.
  -- vim.schedule_wrap defers the API work into the main loop, which pumps during wait().
  -- Reads spinner.msg, not the upvalue, so a nested call's label shows while
  -- it runs.
  local timer = vim.uv.new_timer()
  timer:start(80, 80, vim.schedule_wrap(function()
    fi = (fi % #frames) + 1
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false,
        { "", "  " .. frames[fi] .. " " .. spinner.msg, "" })
      pcall(vim.cmd, "redraw")
    end
  end))

  function spinner.label(text)
    spinner.msg = text
  end

  function spinner.close()
    timer:stop()
    timer:close()
    -- Close float, suppressing autocmds again (nvim_win_close has no
    -- noautocmd option; both calls are pcall'd, so the option is always restored).
    local ei = vim.o.eventignore
    vim.o.eventignore = "all"
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.o.eventignore = ei
    -- Flush the close to terminal so the float disappears before the next render.
    pcall(vim.cmd, "redraw")
  end

  return spinner
end

--- Progress message (Neovim 0.12+). The callers' labels are padded for the
--- float, so they are trimmed here.
local function progress_spinner(msg)
  local opts = { kind = "progress", source = "dadbod-grip", title = "grip", status = "running" }
  local function echo(text)
    opts.id = vim.api.nvim_echo({ { vim.trim(text) } }, false, opts)
  end
  local spinner = { msg = msg }
  -- Redraw first: right after a confirm() dialog its lines are still on the
  -- message area, and echoing below them would raise a hit-enter prompt.
  pcall(vim.cmd, "redraw")
  echo(msg)
  pcall(vim.cmd, "redraw")

  local held, real_notify = {}, vim.notify
  local function hold(...)
    local args = pack(...)
    held[#held + 1] = function() vim.notify(unpack_(args, 1, args.n)) end
  end
  _held, vim.notify = held, hold

  -- No redraw: an inner call's label shows on the next one, so it does not
  -- flush a half-built layout (see M.blocking).
  function spinner.label(text)
    spinner.msg = text
    echo(text)
  end

  function spinner.close(ok)
    _held = nil
    if vim.notify == hold then vim.notify = real_notify end
    opts.status = ok and "success" or "failed"
    echo(msg:gsub("%.*%s*$", "") .. (ok and ": done" or ": failed"))
    -- The default cmdline would keep showing the finished message; ui2 and
    -- progress plugins have their own way of retiring it.
    vim.api.nvim_echo({}, false, {})
    for _, show in ipairs(held) do show() end
  end

  return spinner
end

--- The spinner owned by the outermost blocking() call, or nil when none is up.
--- @type table|nil  { msg: string, label: fun(text), close: fun(ok) }
local _spinner = nil

--- Show progress for fn(): a progress message on Neovim 0.12+ (see
--- |progress-message|), an animated spinner float before that.
---
--- IMPORTANT: fn() must be synchronous OR use vim.wait() for async work.
--- If fn() returns before work is done, the spinner ends prematurely.
--- For async callers (e.g. curl/jobstart), use this pattern inside fn():
---
---   local done = false
---   start_async(function(result) ... done = true end)
---   vim.wait(30000, function() return done end, 50)
---
--- The float's braille frames animate during vim.system():wait() and
--- vim.wait() calls inside fn() because both pump the libuv event loop.
--- The float opens with noautocmd and closes under eventignore="all": plugin
--- autocmds (WinNew/WinEnter) add 200-400ms from noice/treesitter/nvim-cmp.
---
--- With progress messages, notifications raised inside fn() are shown after
--- the final progress update rather than underneath it.
---
--- Calls nest: only the outermost one owns the spinner, and an inner call just
--- relabels it for the duration of its own work. Closing the inner float would
--- flush whatever the outer call has built so far to the terminal -- for the
--- workspace that means a half-open sidebar over an empty content area, the
--- exact flicker the spinner is there to cover.
---
--- @param msg string
--- @param fn  function  must be synchronous or use vim.wait() internally
--- @return    any       all return values from fn() forwarded
function M.blocking(msg, fn)
  -- Nested: borrow the spinner that is already up, restoring its message so
  -- the outer call goes back to describing its own work when this one returns.
  if _spinner then
    local spinner, outer_msg = _spinner, _spinner.msg
    spinner.label(msg)
    local rets = pack(pcall(fn))
    spinner.label(outer_msg)
    if not rets[1] then error(rets[2], 2) end
    return unpack_(rets, 2, rets.n)
  end

  -- Claimed only once the spinner is up: a nested call reaching this far
  -- would have had none to borrow, and every one after it must find a live
  -- spinner to relabel.
  local spinner = (use_progress() and progress_spinner or float_spinner)(msg)
  _spinner = spinner

  local rets = pack(pcall(fn))

  -- Released before closing: anything the cleanup triggers must see no
  -- spinner rather than one that is about to vanish.
  _spinner = nil
  spinner.close(rets[1])

  if not rets[1] then error(rets[2], 2) end
  return unpack_(rets, 2, rets.n)
end

return M
