local M = {}
local layout = require('foyer.layout')
local window = require('foyer.window')
local clear_foyer_matches = window.clear_foyer_matches
local dismiss = window.dismiss
local set_window_title = window.set_window_title
local insert_at_end = window.insert_at_end
local create_window = window.create_window
local options = require('foyer.config')
local config = options.options
local project_root = options.project_root
local map = options.map
local context = require('foyer.context')
local selection_appendix = context.selection_appendix
local capture = context.capture
local mention = require('foyer.mention')
local last_output_time = {}

-- Terminals foyer started and that have not finished starting yet, with when
-- they were started. A program reads nothing it is sent while it starts: it
-- has not taken over the terminal, and taking it over commonly throws away
-- what was typed ahead. So a send to one of these waits, see send_command().
local starting = {}
-- How long a starting terminal must be quiet after its first output -- its
-- first screen drawn -- to count as started.
local SETTLE_MS = 500
-- How long a program may show nothing at all and still be taken as started:
-- one that draws nothing until it is spoken to.
local SILENT_MS = 3000
-- How long a send waits for a terminal that never settles before going anyway.
local START_TIMEOUT_MS = 15000


function M.is_idle(buf, threshold_ms)
    threshold_ms = threshold_ms or 1000
    local t = last_output_time[buf]
    return t == nil or (vim.uv.now() - t) > threshold_ms
end




-- A draft of nothing but whitespace is a draft the user never wrote: it closes
-- a window, it is not sent, and it is not remembered.
local function is_blank(s)
    return not s:find('%S')
end

local function buffer_text(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end


-- What the user typed, with the selection below it after a blank line. It
-- joins here, as the prompt is sent, and never sits in the command buffer: the
-- line stays the user's to edit and to navigate history with, and history
-- records the prompt without a selection that will not be true next time. A
-- blank prompt stays blank, so the send is dropped: a selection alone asks the
-- agent nothing.
local function with_selection(cmd, ref)
    if not ref or is_blank(cmd) then return cmd end
    return cmd .. '\n\n' .. ref
end


-- Command logger
local cache_file = vim.fn.stdpath('cache') .. '/foyer.json'
local history = {}

local function load_history()
    local file = io.open(cache_file, 'r')
    if file then
        local content = file:read('*a')
        file:close()
        local ok, data = pcall(vim.fn.json_decode, content)
        if ok and data then history = data end
    end
end

local function save_history()
    -- Nothing else of ours creates the cache directory, and a fresh Neovim may
    -- not have one yet: io.open() would then fail, and history go unsaved.
    vim.fn.mkdir(vim.fn.fnamemodify(cache_file, ':h'), 'p')
    local file = io.open(cache_file, 'w')
    if file then
        file:write(vim.fn.json_encode(history))
        file:close()
    end
end

local function get_term_name(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local term_name = name:match('([^/\\]+)$') or 'default'
    -- A terminal buffer name carries a PID prefix like "42098:".
    return (term_name:gsub('^%d+:', ''):gsub('^%s*(.-)%s*$', '%1')) or 'default'
end

local function log_command(cmd, term_bufnr)
    -- What the user wrote, not the code a mention put in with it: that would
    -- bloat every entry and be out of date by the time it is recalled.
    cmd = context.strip_selections(cmd)
    if is_blank(cmd) then return end

    local term_name = get_term_name(term_bufnr)
    if not history[term_name] then history[term_name] = {} end

    local entries = history[term_name]

    -- Sending a prompt again moves it to the end, the latest, and adds to how
    -- often it has been used: <Up> walks by the one, the picker ranks by both.
    local count = 0
    for i = #entries, 1, -1 do
        if entries[i].cmd == cmd then
            count = count + (entries[i].count or 1)
            table.remove(entries, i)
        end
    end

    table.insert(entries, {
        cmd = cmd,
        time = os.time(),
        count = count + 1,
    })

    save_history()
end

-- How much a history entry is worth recalling: how often it was used, halved
-- for every week since it last was. A prompt sent five times, last a week
-- ago, outranks one sent once today (2.5 to 1); a habit that stopped a month
-- ago has faded to a twentieth of its count.
local HALF_LIFE = 7 * 24 * 3600
local function frecency(entry, now)
    local age = math.max(0, now - (entry.time or now))
    return (entry.count or 1) * 0.5 ^ (age / HALF_LIFE)
end

-- A veil dimming the editor behind a picker, so the choice is the one thing
-- that reads. Returns the function that lifts it. Blending needs
-- 'termguicolors': without it the veil would be opaque and hide the editor
-- outright, so it is left out instead.
local function open_backdrop()
    if not vim.o.termguicolors then return function() end end
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 0,
        col = 0,
        width = vim.o.columns,
        -- The command line stays clear: messages land there.
        height = math.max(1, vim.o.lines - vim.o.cmdheight),
        style = 'minimal',
        focusable = false,
        noautocmd = true,
        zindex = 49,
    })
    vim.wo[win].winhighlight = 'Normal:FoyerBackdrop'
    vim.wo[win].winblend = 40
    return function()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
        if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
end

-- The most rows one prompt takes in the prompt picker; a longer one ends in
-- "…" there. Enough to tell prompts apart, not so many that one buries the
-- rest.
local PICK_ROWS = 4

-- {text} broken into rows no wider than {width} cells, at the last space that
-- fits, or mid-word when there is none. Stops once it has {max} rows, and
-- says whether anything was left over.
local function wrap(text, width, max)
    local rows = {}
    while #rows < max and vim.fn.strdisplaywidth(text) > width do
        local chars, fit = vim.fn.strchars(text), 0
        while fit < chars and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, fit + 1)) <= width do
            fit = fit + 1
        end
        local head = vim.fn.strcharpart(text, 0, math.max(fit, 1))
        -- The prefix is the same bytes in {head} and {text}.
        local space = head:match('^.*()%s')
        if space and space > 1 then
            table.insert(rows, (head:sub(1, space - 1):gsub('%s+$', '')))
            text = text:sub(space + 1):gsub('^%s+', '')
        else
            table.insert(rows, head)
            text = text:sub(#head + 1)
        end
    end
    if #rows < max then
        table.insert(rows, text)
        return rows, false
    end
    return rows, text ~= ''
end

-- The rows {cmd} is shown in, no wider than {width}: each of its lines
-- wrapped, blank ones dropped, at most PICK_ROWS, the last ending in "…"
-- if that is not all of it.
local function prompt_rows(cmd, width)
    local rows, more = {}, false
    for _, line in ipairs(vim.split(cmd:gsub('\t', '    '), '\n', {plain = true})) do
        if line:find('%S') then
            if #rows == PICK_ROWS then more = true; break end
            local wrapped, left = wrap(line:gsub('%s+$', ''), width, PICK_ROWS - #rows)
            vim.list_extend(rows, wrapped)
            if left then more = true; break end
        end
    end
    if more then
        local last = rows[#rows]
        while last ~= '' and vim.fn.strdisplaywidth(last) + 1 > width do
            last = vim.fn.strcharpart(last, 0, vim.fn.strchars(last) - 1)
        end
        rows[#rows] = last .. '\u{2026}'
    end
    return rows
end

-- The words of {query}, lowercased: what a prompt must hold, each of them,
-- in any order, to pass the filter. Only A to Z have their case ignored:
-- lowering anything else may change its length in bytes, and the highlight
-- finds the words by byte in the rows on screen.
local function query_words(query)
    local words = {}
    for word in query:lower():gmatch('%S+') do table.insert(words, word) end
    return words
end

-- Whether {cmd} holds every one of {words}, ignoring the case of A to Z.
local function holds_all(cmd, words)
    local text = cmd:lower()
    for _, word in ipairs(words) do
        if not text:find(word, 1, true) then return false end
    end
    return true
end

-- Where {words} are in {rows}, the rows a prompt is shown in, as
-- { row, start byte, end byte }, for the highlight: found afresh in what is
-- on screen, which wrapping and "…" may have cut.
local function word_marks(rows, words)
    local marks = {}
    for r, row in ipairs(rows) do
        local text = row:lower()
        for _, word in ipairs(words) do
            local from = 1
            while true do
                local s, e = text:find(word, from, true)
                if not s then break end
                table.insert(marks, { r, s - 1, e })
                from = e + 1
            end
        end
    end
    return marks
end

-- Whether {key}, as getcharstr() returns it, is a character to type rather
-- than a special key or a control character.
local function typed_char(key)
    local b = key:byte(1)
    return b ~= nil and b >= 0x20 and b ~= 0x7f and b ~= 0x80
end

-- {entries}, the most worth recalling first, in a popup at {prompt_win}'s cursor
-- with a hint label in front of each, as jump() draws them; one key picks.
-- One entry per label character, so a label is always a single key, and only
-- as many as the screen holds. Returns the entry and whether it was picked
-- with Shift -- to replace the draft, not just to add to it -- or nil once the
-- user backs out. A key that is no label is ignored: the choices are on screen, so
-- it is a slip of the finger.
--
-- `/` filters them: what is typed narrows the list as it goes, to the
-- prompts holding every word of it, in any order, over the whole history
-- rather than the few on screen, still most worth recalling first. <CR> goes
-- back to picking among what is left, the labels given out afresh. <Esc>
-- clears the filter, and once there is none closes the popup. The popup
-- keeps the size and place it opened with, and the filter is typed in its
-- top border, so nothing moves under the eye as the list narrows.
local function pick_prompt(entries, prompt_win)
    local jump = require('foyer.jump')
    local chars = config.jump.characters

    -- One width for the count column whatever the filter leaves, so the popup
    -- does not jump about as it narrows.
    local counts = {}
    local count_width = 0
    for _, entry in ipairs(entries) do
        -- The user's own prompts wear a star where history has its count.
        counts[entry] = entry.own and '\u{2605}' or ('%d\u{00d7}'):format(entry.count or 1)
        count_width = math.max(count_width, vim.fn.strdisplaywidth(counts[entry]))
    end

    -- As wide as the prompt, so the text wraps where the user wrote it, but
    -- never so narrow that it wraps every other word, nor off the screen.
    -- ' a  text  3\u{00d7} ': label, text, then the count in a column of its
    -- own; a prompt's further rows are indented under its first.
    local max_width = math.max(1, math.min(math.max(vim.api.nvim_win_get_width(prompt_win) - 2, 50),
        vim.o.columns - 4))
    local text_cap = math.max(10, max_width - 4 - 2 - count_width - 1)
    -- Just below the cursor, as a completion menu opens, so the list starts
    -- where the eye already is; above it when it fits there and not below.
    -- The screen cell the cursor is on counts the prompt's border and its
    -- wrapped lines, and is there past the end of a line, where Insert mode
    -- leaves it.
    local cursor = vim.api.nvim_win_get_cursor(prompt_win)
    local at = vim.fn.screenpos(prompt_win, cursor[1], cursor[2] + 1)
    if at.row == 0 then
        -- Off screen, somehow: the prompt's top left corner, then.
        local pos = vim.api.nvim_win_get_position(prompt_win)
        at = { row = pos[1] + 1, col = pos[2] + 1 }
    end
    local bottom = vim.o.lines - vim.o.cmdheight
    -- Rows each side has for the list, the border taken off.
    local below = bottom - at.row - 2
    local above = at.row - 1 - 2
    local max_rows = math.max(1, below, above)

    jump.setup_highlights()
    local buf = vim.api.nvim_create_buf(false, true)
    local ns = vim.api.nvim_create_namespace('foyer_pick_prompt')
    local win, fixed
    local query, typing = '', false

    -- The entries the filter leaves, in the order they came.
    local function matching()
        local words = query_words(query)
        if #words == 0 then return entries end
        return vim.tbl_filter(function(entry) return holds_all(entry.cmd, words) end, entries)
    end

    -- Draw what the filter leaves, labelled: in a popup fitted to the list on
    -- the first draw, and kept at that size and place after. Returns the
    -- entries behind the labels.
    local function render()
        local list = matching()
        local words = query_words(query)
        local n = math.min(#list, #chars)
        local rows, total = {}, 0
        local text_width = 0
        -- Once open, the popup's size is the one it opened with: the text
        -- wraps to it, and only as much as it holds is shown.
        local cap = fixed and math.max(10, fixed.width - 4 - 2 - count_width - 1) or text_cap
        local room = fixed and fixed.height or max_rows
        for i = 1, n do
            local r = prompt_rows(list[i].cmd, cap)
            if total + #r > room then
                if total > 0 then n = i - 1; break end
                r = { r[1] }
            end
            rows[i] = r
            total = total + #r
            for _, row in ipairs(r) do
                text_width = math.max(text_width, vim.fn.strdisplaywidth(row))
            end
        end

        local lines, labels, hits = {}, {}, {}
        for i = 1, n do
            local count = counts[list[i]]
            local first = (' %s  %s'):format(chars:sub(i, i), rows[i][1])
            first = first .. (' '):rep(4 + text_width - vim.fn.strdisplaywidth(first) + 2)
                .. (' '):rep(count_width - vim.fn.strdisplaywidth(count))
            table.insert(labels, { #lines, #first })
            if #words > 0 then
                for _, m in ipairs(word_marks(rows[i], words)) do
                    -- Every row starts 4 bytes in: the label's, or the indent.
                    table.insert(hits, { #lines + m[1] - 1, 4 + m[2], 4 + m[3] })
                end
            end
            table.insert(lines, first .. count .. ' ')
            for j = 2, #rows[i] do
                table.insert(lines, '    ' .. rows[i][j])
            end
        end
        if n == 0 then lines = { '    no match ' } end

        -- The filter in the top border, left-aligned, so it grows to the
        -- right as it is typed and the rest stays put.
        local title, title_pos = ' Frequent prompts / Foyer ', 'center'
        if typing or query ~= '' then
            title, title_pos = (' /%s%s '):format(query, typing and '\u{2581}' or ''), 'left'
        end
        local footer
        if typing then
            footer = ' <CR>: pick · <Esc>: clear '
        elseif query ~= '' then
            footer = ' label: insert · Shift: replace · <Esc>: clear '
        else
            footer = ' label: insert · Shift: replace · /: filter · <Esc> '
        end
        local width = 4 + text_width + 2 + count_width + 1
        width = math.min(vim.o.columns - 4, math.max(width, vim.fn.strdisplaywidth(footer), 14))

        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        for _, m in ipairs(labels) do
            vim.api.nvim_buf_set_extmark(buf, ns, m[1], 0, { end_col = 3, hl_group = jump.HL.label })
            vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = #lines[m[1] + 1], hl_group = 'Comment' })
        end
        for _, h in ipairs(hits) do
            vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = 'FoyerMatch' })
        end
        if n == 0 then
            vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #lines[1], hl_group = 'Comment' })
        end

        -- No backdrop: it would dim the prompt too, when that is a split.
        if not fixed then
            local height = math.min(#lines, max_rows)
            local row = at.row
            if height > below and above > below then row = at.row - 1 - height - 2 end
            -- Left-aligned with the cursor, pushed back left to stay on screen.
            local col = math.max(0, math.min(at.col - 1, vim.o.columns - width - 2))
            fixed = { width = width, height = height, row = row, col = col }
        end
        local cfg = {
            relative = 'editor',
            width = fixed.width,
            height = fixed.height,
            row = fixed.row,
            col = fixed.col,
            border = 'rounded',
            title = title,
            title_pos = title_pos,
            footer = footer,
            footer_pos = 'right',
        }
        if win then
            vim.api.nvim_win_set_config(win, cfg)
        else
            cfg.style = 'minimal'
            cfg.focusable = false
            cfg.noautocmd = true
            -- Above the prompt, should that be a float itself.
            cfg.zindex = 60
            win = vim.api.nvim_open_win(buf, false, cfg)
        end
        local shown = {}
        for i = 1, n do shown[i] = list[i] end
        return shown
    end

    -- Whatever goes wrong while it is up, the cursor comes back and the popup
    -- goes: a hidden cursor and a stray float would outlive the error.
    local restore_cursor, picked, replace
    local ok, err = pcall(function()
        local shown = render()
        restore_cursor = jump.hide_cursor()

        local esc, ctrl_c, cr = vim.keycode('<Esc>'), vim.keycode('<C-c>'), vim.keycode('<CR>')
        local bs, ctrl_h, ctrl_u = vim.keycode('<BS>'), vim.keycode('<C-h>'), vim.keycode('<C-u>')
        local ctrl_w = vim.keycode('<C-w>')
        while true do
            vim.cmd('redraw')
            local read, key = pcall(jump.read_key)
            if not read or key == ctrl_c then break end
            if typing then
                if key == esc then
                    query, typing = '', false
                elseif key == cr then
                    typing = false
                elseif key == bs or key == ctrl_h then
                    -- Past the start, back to picking, as a search line does.
                    if query == '' then typing = false end
                    query = vim.fn.strcharpart(query, 0, vim.fn.strchars(query) - 1)
                elseif key == ctrl_w then
                    -- The word before, and the spaces after it, as on the
                    -- command line.
                    query = query:gsub('%s+$', ''):gsub('%S+$', '')
                elseif key == ctrl_u then
                    query = ''
                elseif typed_char(key) then
                    query = query .. key
                end
                shown = render()
            elseif key == esc then
                if query == '' then break end
                query = ''
                shown = render()
            elseif key == '/' then
                typing = true
                shown = render()
            else
                -- Shift on a label replaces the draft, unless the shifted key
                -- is a label of its own.
                local idx = chars:find(key, 1, true)
                local shifted = false
                if not idx and key:lower() ~= key then
                    idx = chars:find(key:lower(), 1, true)
                    shifted = idx ~= nil
                end
                if idx and shown[idx] then
                    picked, replace = shown[idx], shifted
                    break
                end
            end
        end
    end)

    if restore_cursor then restore_cursor() end
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    if not ok then error(err, 0) end
    return picked, replace
end

load_history()

-- Highlight marking the filter text inside the history palette. Re-applied on
-- ColorScheme because :colorscheme clears default highlights.
local hl_group = vim.api.nvim_create_augroup('foyer_highlight', { clear = true })
local function set_default_hl()
    vim.api.nvim_set_hl(0, 'FoyerMatch', {
        bg = '#333333',
        fg = '#ff7700',
        bold = true,
        default = true,
    })
    -- The veil over the editor while the terminal picker is up.
    vim.api.nvim_set_hl(0, 'FoyerBackdrop', { bg = '#000000', default = true })
end
set_default_hl()
vim.api.nvim_create_autocmd('ColorScheme', { group = hl_group, callback = set_default_hl })

-- Text the receiver must take literally rather than act on. A bare newline in
-- the middle of a command reads as Enter to a shell, which would run the first
-- line on its own; bracketed paste says "this is pasted input" and gets the
-- newline inserted instead. Only a multi-line send is wrapped: a single-line
-- command never needed the protection. A receiver that does not understand the
-- escapes shows them as text, which is what `bracketed_paste = false` is for.
local function as_paste(cmd)
    if not config.bracketed_paste then return cmd end
    if not cmd:find('\n', 1, true) then return cmd end
    return '\x1b[200~' .. cmd .. '\x1b[201~'
end

-- Whether {buf} has finished starting: it has drawn its first screen and been
-- quiet for SETTLE_MS since, or drawn nothing for SILENT_MS. "Drawn" means text
-- in the buffer, not just a change to it: a new terminal reports its empty
-- screen being laid out before the program has said a word. A terminal foyer
-- did not start, or one that has started once, counts as started; one that is
-- merely busy later on is the busy check's business, not this one's.
local function started(buf)
    local since = starting[buf]
    if not since then return true end
    local now = vim.uv.now()
    local drawn = vim.iter(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):any(function(l) return l:find('%S') end)
    local t = last_output_time[buf]
    if (drawn and t and now - t > SETTLE_MS)
        or (not drawn and now - since > SILENT_MS)
        or now - since > START_TIMEOUT_MS then
        starting[buf] = nil
        return true
    end
    return false
end

-- Terminals foyer started that have not yet been seen taking a prompt: until
-- one has, a send there is typed without Enter, and the Enter goes only once
-- the text has shown, see deliver_confirmed().
local unconfirmed = {}
-- How long a typed prompt may take to show on the terminal's screen.
local ECHO_MS = 2000

local function term_label(buf)
    local cmdline = vim.api.nvim_buf_get_name(buf):match('//%d+:(.*)$')
    return cmdline and vim.fs.basename(cmdline:match('^%S+')) or 'the terminal'
end

local function screen(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

-- Call {fn} once {buf}'s screen has stopped changing for a moment, or after
-- {max_ms} regardless: whatever the program is still drawing -- its first
-- screen, a redraw -- is over by then, and not taken for what the next keys
-- do.
local function when_quiet(buf, max_ms, fn)
    local since, last, still = vim.uv.now(), screen(buf), vim.uv.now()
    local function check()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local now, current = vim.uv.now(), screen(buf)
        if current ~= last then last, still = current, now end
        if now - still >= 300 or now - since >= max_ms then return fn() end
        vim.defer_fn(check, 50)
    end
    vim.defer_fn(check, 50)
end

-- Put the cursor on the last line of {buf} in every window showing it, which
-- is what makes a terminal window in Normal mode follow its output: with the
-- cursor anywhere above, output runs on below the window and nothing scrolls.
-- A window in Terminal mode follows anyway, and its cursor is the terminal's.
local function follow(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local last = vim.api.nvim_buf_line_count(buf)
    local cur = vim.api.nvim_get_current_win()
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if not (win == cur and vim.api.nvim_get_mode().mode == 't') then
            vim.api.nvim_win_set_cursor(win, { last, 0 })
        end
    end
end

-- Send to a terminal that has not yet been seen taking a prompt, without
-- pressing Enter on anything else. A program can come up on a screen of its
-- own -- "Trust this workspace?", a login, an update -- and there the Enter
-- that ends a prompt is the answer to a question the user never saw. So the
-- text goes first, and the Enter only once the screen has changed for it: an
-- input box shows what is typed into it, if only as "12 lines" for a long
-- paste, while a question ignores it. Not shown, nothing more is sent: the
-- question is the user's to answer. {done} is called with 'sent', 'unseen',
-- or 'closed' for a terminal gone meanwhile.
local function deliver_confirmed(term_bufnr, cmd, suffix, done)
    local job = vim.b[term_bufnr].terminal_job_id
    when_quiet(term_bufnr, 1000, function()
        local before = screen(term_bufnr)
        vim.fn.chansend(job, as_paste(cmd))
        local typed = vim.uv.now()
        local function check()
            if not vim.api.nvim_buf_is_valid(term_bufnr) then return done('closed') end
            if screen(term_bufnr) ~= before then
                unconfirmed[term_bufnr] = nil
                vim.fn.chansend(job, suffix)
                -- The reply is still to come, a while after the window was
                -- last told to follow.
                follow(term_bufnr)
                return done('sent')
            end
            if vim.uv.now() - typed >= ECHO_MS then return done('unseen') end
            vim.defer_fn(check, 100)
        end
        vim.defer_fn(check, 100)
    end)
end

-- Send one prompt now: {done} is called as for deliver_confirmed().
local function deliver(term_bufnr, send, done)
    if not vim.api.nvim_buf_is_valid(term_bufnr) then return done('closed') end
    local job = vim.b[term_bufnr].terminal_job_id
    if unconfirmed[term_bufnr] and not is_blank(send.cmd) then
        -- Out of Terminal mode meanwhile: a key of the user's reaching the
        -- terminal -- an arrow moving through a question -- would change the
        -- screen, and be taken for the text arriving.
        return deliver_confirmed(term_bufnr, send.cmd, send.suffix, done)
    end
    vim.fn.chansend(job, as_paste(send.cmd) .. send.suffix)
    -- What the send brings back, in view wherever the terminal is shown.
    follow(term_bufnr)
    done('sent')
end

-- Sends not yet made, per terminal, in the order they were asked for: one at
-- a time, since one being confirmed takes a moment.
local pending = {}

local function run_queue(term_bufnr)
    local name = term_label(term_bufnr)
    local since = vim.uv.now()
    local said = false
    local function next_send()
        local queue = pending[term_bufnr]
        if not queue or not vim.api.nvim_buf_is_valid(term_bufnr) then
            pending[term_bufnr] = nil
            return
        end
        if not started(term_bufnr) then
            if not said then
                said = true
                vim.notify(('foyer.nvim: waiting for %s to start'):format(name), vim.log.levels.INFO)
            end
            return vim.defer_fn(next_send, 100)
        end
        if said and vim.uv.now() - since > START_TIMEOUT_MS then
            said = false
            vim.notify(('foyer.nvim: %s did not settle; sending anyway'):format(name), vim.log.levels.WARN)
        end
        local send = table.remove(queue, 1)
        if not send then
            pending[term_bufnr] = nil
            return
        end
        deliver(term_bufnr, send, function(outcome)
            if outcome == 'sent' then return next_send() end
            -- Whatever was queued behind it would meet the same screen.
            pending[term_bufnr] = nil
            if outcome == 'unseen' then
                vim.notify(('foyer.nvim: %s did not show the prompt, so it was not sent. It may be asking '
                    .. 'something in its terminal: answer it there, then send again -- the prompt is in '
                    .. 'history, one <Up> away.'):format(name), vim.log.levels.WARN)
            end
        end)
    end
    next_send()
end

-- Send {cmd} to {term_bufnr} as it is, with {suffix} -- the Enter, if any --
-- once the terminal has started, and in order with any other send still
-- waiting for it.
local function send_command(term_bufnr, cmd, suffix)
    local send = { cmd = cmd, suffix = suffix }
    if pending[term_bufnr] then
        table.insert(pending[term_bufnr], send)
        return
    end
    pending[term_bufnr] = { send }
    run_queue(term_bufnr)
end

local term_keymaps_group = vim.api.nvim_create_augroup('foyer_keymaps', { clear = false })

-- When each terminal was last used, as a count rather than a time, so two uses
-- in the same millisecond still come in order: launched, shown, or its prompt
-- entered. What switch_terminal() goes back to.
local last_used = {}
local use_count = 0
local function touch(term_buf)
    use_count = use_count + 1
    last_used[term_buf] = use_count
end

vim.api.nvim_create_autocmd('BufEnter', {
    group = vim.api.nvim_create_augroup('foyer_last_used', { clear = true }),
    callback = function(ev)
        if vim.b[ev.buf].foyer_terminal then
            touch(ev.buf)
        elseif vim.b[ev.buf].foyer_prompt and vim.b[ev.buf].foyer_term then
            touch(vim.b[ev.buf].foyer_term)
        end
    end,
})
local term_setup_done = {}

local function setup_terminal_keymaps(buf)
    -- Called from every path that reaches a terminal, so it must be idempotent:
    -- a second run would stack another buf_attach and another TextYankPost
    -- autocmd on the same buffer.
    if term_setup_done[buf] then return end
    term_setup_done[buf] = true

    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
            last_output_time[buf] = vim.uv.now()
        end,
        on_detach = function()
            term_setup_done[buf] = nil
            last_output_time[buf] = nil
            last_used[buf] = nil
            starting[buf] = nil
            pending[buf] = nil
            unconfirmed[buf] = nil
        end,
    })

    -- <C-t> goes back up the tag stack, which a terminal never is on, so the
    -- key is free for something of foyer's own.
    map(buf, 'terminal', 'switch', function() M.switch_terminal() end,
        { desc = 'Switch to the terminal used last' })

    vim.api.nvim_create_autocmd('TextYankPost', {
        group = term_keymaps_group,
        buffer = buf,
        callback = function()
            local event = vim.v.event
            if event.operator == 'y' then
                local content = vim.tbl_map(function(line) return line:gsub('%s+$', '') end, event.regcontents)
                local reg = event.regname ~= '' and event.regname or '"'
                vim.fn.setreg(reg, content, event.regtype)
                if reg == '"' then
                    vim.fn.setreg('+', content, event.regtype)
                    vim.fn.setreg('*', content, event.regtype)
                end
            end
        end,
    })
end

-- A window's prompt, the one its terminal's <C-o> goes back to, lasts while
-- the window shows a prompt or a terminal. Once it shows anything else -- a
-- file the user opened in it, the buffer a borrowed window goes back to --
-- it is no longer foyer's, and a terminal shown there later has no prompt of
-- its own. Registered once, for every window.
vim.api.nvim_create_autocmd('BufWinEnter', {
    group = vim.api.nvim_create_augroup('foyer_window_prompt', { clear = true }),
    callback = function(ev)
        local win = vim.api.nvim_get_current_win()
        if vim.w[win].foyer_prompt and not vim.b[ev.buf].foyer_prompt
            and vim.bo[ev.buf].buftype ~= 'terminal' then
            vim.w[win].foyer_prompt = nil
        end
    end,
})

local function init_term_buf(term_bufnr, win_id, prev_buf)
    -- Set for this buffer in this window only, so a borrowed window does not
    -- keep it once its own buffer is back.
    vim.wo[win_id][0].relativenumber = true
    map(term_bufnr, 'terminal', 'close', function() dismiss(win_id, prev_buf) end)

    setup_terminal_keymaps(term_bufnr)

    -- Back to the prompt this terminal was shown for, named rather than taken
    -- to be the alternate buffer, which a terminal reached any other way
    -- need not have as its prompt. Kept on the window, not in the mapping: a
    -- terminal is one buffer however many windows show it, and each of
    -- foyer's has its own prompt. In a window that is not foyer's, the key is
    -- Vim's again. The prompt's own BufEnter puts its title back.
    vim.w[win_id].foyer_prompt = prev_buf
    map(term_bufnr, 'terminal', 'prompt', function(_, lhs)
        return function()
            local prompt = vim.w.foyer_prompt
            if prompt and vim.api.nvim_buf_is_valid(prompt) then
                vim.api.nvim_set_current_buf(prompt)
            else
                vim.api.nvim_feedkeys(vim.v.count1 .. vim.keycode(lhs), 'n', false)
            end
        end
    end, { build = true })

    -- cd the terminal to the project root, wherever it has wandered off to.
    map(term_bufnr, 'terminal', 'cd_root', function()
        local root = project_root(vim.fn.getcwd())
        if root then
            vim.fn.chansend(vim.b[term_bufnr].terminal_job_id, "cd " .. vim.fn.shellescape(root) .. "\r")
        end
    end)

    -- The latest output in view, and what comes after it as it comes.
    follow(term_bufnr)
end

local function init_command_buf_shared(bufnr, win_id, lines, on_enter)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    map(bufnr, 'prompt', 'close_if_empty', function()
        if is_blank(buffer_text(bufnr)) then
            dismiss(win_id, bufnr)
        end
    end)

    map(bufnr, 'prompt', 'close', function() dismiss(win_id, bufnr) end)

    map(bufnr, 'prompt', 'send', on_enter)

    -- The terminal this prompt is for, in this window, where <C-o> comes back
    -- from: to look at what it has said before writing to it. Only that: the
    -- window's alternate buffer and jump list lead to the file the prompt was
    -- opened from, which has no place in here. A buffer with no terminal of
    -- its own -- edit_selection()'s -- ignores the key.
    map(bufnr, 'prompt', 'terminal', function()
        local term = vim.b[bufnr].foyer_term
        if not (term and vim.api.nvim_buf_is_valid(term)) then return end
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_buf(term)
        set_window_title(win, vim.b[bufnr].foyer_term_title or get_term_name(term))
        init_term_buf(term, win, bufnr)
    end)
end

-- History navigation for one command buffer, over the history of {term_buf}.
-- Re-attachable, and must be re-attached by anyone handing an existing buffer
-- to a new send: the list is read once, here, so a prompt that outlived its
-- send would otherwise go on walking the history as it stood when its window
-- opened.
local function attach_history(bufnr, term_buf)
    set_default_hl()

    -- A copy of this terminal's history, so filtering never mutates the stored
    -- list, with the draft appended as the last entry: navigation walks back to
    -- it, and typing updates it in place.
    local entries = history[get_term_name(term_buf)] or {}
    local working_entries = {}
    for _, entry in ipairs(entries) do
        table.insert(working_entries, entry)
    end
    table.insert(working_entries, {cmd = buffer_text(bufnr), time = os.time()})
    local filtered_entries = working_entries
    local idx = #filtered_entries - 1

    local function navigate_history(delta)
        local user_input = buffer_text(bufnr)
        if idx == #filtered_entries - 1 or filtered_entries[idx + 1].cmd ~= user_input then
            working_entries[#working_entries].cmd = user_input

            clear_foyer_matches()
            if user_input and user_input ~= "" then
                filtered_entries = {}
                for i = 1, #working_entries - 1 do
                    if working_entries[i].cmd:lower():find(user_input:lower(), 1, true) then
                        table.insert(filtered_entries, working_entries[i])
                    end
                end
                table.insert(filtered_entries, working_entries[#working_entries])

                vim.fn.matchadd('FoyerMatch', vim.fn.escape(user_input, '\\'))
            else
                filtered_entries = working_entries
            end
            idx = #filtered_entries - 1
        end

        if #filtered_entries == 0 then return end

        idx = ((idx - delta) % #filtered_entries + #filtered_entries) % #filtered_entries
        local cmd = filtered_entries[idx + 1] and filtered_entries[idx + 1].cmd or ""
        local new_lines = vim.split(cmd, '\n', {plain = true})
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
        vim.api.nvim_win_set_cursor(0, {#new_lines, #new_lines[#new_lines]})
    end

    -- Whether the buffer holds the entry the last step recalled, untouched:
    -- a walk under way, which a step goes on with wherever the cursor is.
    local function walking()
        return idx ~= #filtered_entries - 1 and filtered_entries[idx + 1] ~= nil
            and filtered_entries[idx + 1].cmd == buffer_text(bufnr)
    end

    local line_keys = { [vim.keycode('<Up>')] = true, [vim.keycode('<Down>')] = true }

    -- In Insert mode a key is still its own where history has no business:
    -- with a menu open -- a mention's, or ordinary completion -- it walks the
    -- menu, and <Up> or <Down> moves the cursor in a draft of many lines, as
    -- a shell's does, until it is on the first line, or the last, with no
    -- line further to go.
    local function walker(delta)
        return function(mode, lhs)
            return function()
                local own = false
                if mode == 'i' then
                    local row = vim.api.nvim_win_get_cursor(0)[1]
                    local edge = delta > 0 and 1 or vim.api.nvim_buf_line_count(bufnr)
                    own = vim.fn.pumvisible() == 1
                        or (line_keys[vim.keycode(lhs)] and row ~= edge and not walking())
                end
                if own then
                    vim.api.nvim_feedkeys(vim.keycode(lhs), 'n', false)
                else
                    navigate_history(delta)
                end
            end
        end
    end
    map(bufnr, 'prompt', 'history_prev', walker(1), { build = true })
    map(bufnr, 'prompt', 'history_next', walker(-1), { build = true })

    -- The terminal's own prompts, from `prompts`, in the order written, then
    -- the ones in history most worth recalling, most often and recently used
    -- first, each behind a one-key label: all of them, whatever the draft
    -- says, so the draft never moves a prompt to another key -- filtering is
    -- what <Up>, and `/` in the list, are for. The one picked goes in at the cursor, to build on; picked with
    -- Shift, it replaces the whole draft. The mode stays what it was, so an
    -- Insert-mode pick goes on typing.
    local function pick(mode)
        -- The user's own prompts for this terminal first, in their order, so
        -- each keeps its label whatever history does; then history, without
        -- what is already among them.
        local items, own = {}, {}
        local key = vim.api.nvim_buf_is_valid(term_buf) and vim.b[term_buf].foyer_key
        for _, text in ipairs(key and config.prompts[key] or {}) do
            if not own[text] then
                own[text] = true
                table.insert(items, { cmd = text, own = true })
            end
        end

        local now = os.time()
        local ranked = {}
        for i, entry in ipairs(history[get_term_name(term_buf)] or {}) do
            if not own[entry.cmd] then
                table.insert(ranked, { entry = entry, score = frecency(entry, now), order = i })
            end
        end
        -- Ties go to the later one: entries are oldest first.
        table.sort(ranked, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.order > b.order
        end)
        for _, r in ipairs(ranked) do table.insert(items, r.entry) end
        if #items == 0 then
            vim.notify('foyer: no history yet', vim.log.levels.INFO)
            return
        end

        local win_id = vim.api.nvim_get_current_win()
        local entry, replace = pick_prompt(items, win_id)
        if not entry or not vim.api.nvim_buf_is_valid(bufnr) then return end
        if not (vim.api.nvim_win_is_valid(win_id) and vim.api.nvim_win_get_buf(win_id) == bufnr) then
            return
        end
        vim.api.nvim_set_current_win(win_id)
        local new_lines = vim.split(entry.cmd, '\n', {plain = true})
        if replace then
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
            vim.api.nvim_win_set_cursor(win_id, {#new_lines, #new_lines[#new_lines]})
        else
            -- At the cursor, as a put would: after the character under it in
            -- Normal mode, as `p` does, before it in Insert mode, where typing
            -- goes on after the prompt. The cursor ends up past it either way.
            vim.api.nvim_put(new_lines, 'c', mode == 'n', true)
        end
    end

    -- With a menu open the key is the menu's, as the history keys are.
    map(bufnr, 'prompt', 'history_pick', function(mode, lhs)
        return function()
            if mode == 'i' and vim.fn.pumvisible() == 1 then
                vim.api.nvim_feedkeys(vim.keycode(lhs), 'n', false)
            else
                pick(mode == 'i' and 'i' or 'n')
            end
        end
    end, { build = true })
end

-- {opts.term} is the terminal the prompt is for: its history is the one
-- walked and the one the sent prompt joins. {opts.prompt_title} is what the
-- prompt's frame says once a send has gone, with nothing attached to it any
-- more.
local function init_command_buf(bufnr, win_id, lines, on_command_input, opts)
    opts = opts or {}
    init_command_buf_shared(bufnr, win_id, lines, function()
        local cmd = buffer_text(bufnr)
        log_command(cmd, opts.term)
        local new_buf = on_command_input(cmd)
        if new_buf then
            vim.api.nvim_set_current_buf(new_buf)
            -- The prompt has left this window; the frame should stop
            -- advertising it and name the terminal now sitting there, the
            -- way the caller named it if it did.
            set_window_title(win_id, opts.term_title or get_term_name(new_buf))
            init_term_buf(new_buf, win_id, bufnr)
            -- What was sent is gone, so the prompt <C-o> comes back to is
            -- ready for the next one: empty, and carrying no selection, which
            -- would otherwise ride along with a follow-up unseen. History has
            -- the text, and is read again so that <Up> finds it.
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
            vim.b[bufnr].foyer_selection = nil
            if opts.prompt_title then vim.b[bufnr].foyer_title = opts.prompt_title end
            attach_history(bufnr, opts.term)
        else
            dismiss(win_id, bufnr)
        end
    end)

    -- The frame belongs to the window, which a terminal shares with the
    -- prompt, so coming back to the prompt puts its own title back -- the
    -- one it has now, not the one it opened with.
    vim.api.nvim_create_autocmd('BufEnter', {
        buffer = bufnr,
        callback = function()
            local title = vim.b[bufnr].foyer_title
            if title then set_window_title(vim.api.nvim_get_current_win(), title) end
        end,
    })

    -- A buffer with something to say already -- a lifted command line, a seeded
    -- command, a prompt that is going to carry a selection -- means the writing
    -- has started. One with nothing to say stays in Normal mode, where <Up>
    -- walks history.
    if opts.start_insert then
        insert_at_end(bufnr, win_id)
    end

    attach_history(bufnr, opts.term)
end

local term_bufs = {}

local function resolve_command(term_key, root, launch_info)
    local val = config.commands[term_key]
    if type(val) == "function" then
        return val(root, launch_info)
    end
    return val
end

-- A resolved entry is a string, a `{ command, arguments }` pair, or either of
-- those carrying `cwd` and `scope` alongside.
local function entry_command(entry)
    if type(entry) ~= "table" then return entry end
    return entry[2] and entry[1] .. " " .. entry[2] or entry[1]
end

local function entry_name(entry)
    return type(entry) == "table" and entry[1] or entry
end

local function entry_cwd(entry, root)
    return type(entry) == "table" and entry.cwd or root
end

local function entry_is_global(entry)
    return type(entry) == "table" and entry.scope == "global"
end

-- Where the entry's prompt opens unless a call says otherwise: 'float', or
-- else a split.
local function entry_win_type(entry)
    return type(entry) == "table" and entry.win_type or nil
end

-- Where a terminal's identity lives. A global entry keeps one terminal for the
-- whole session, wherever you are; every other one is per project root.
local function entry_bucket(entry, root)
    if entry_is_global(entry) then return "" end
    return root
end

-- Which keys have a live terminal, each looked up in its own bucket.
local function running_terminals(root, launch_info)
    local running = {}
    for key in pairs(config.commands) do
        local bucket = entry_bucket(resolve_command(key, root, launch_info), root)
        local buf = term_bufs[bucket] and term_bufs[bucket][key]
        if buf then running[key] = buf end
    end
    return running
end

local function open_term(root, term_key, launch_info)
    local entry = resolve_command(term_key, root, launch_info)
    local bucket = entry_bucket(entry, root)

    vim.cmd('split')

    local pd = vim.fn.getcwd()

    vim.cmd("lcd " .. vim.fn.fnameescape(entry_cwd(entry, root)))

    vim.cmd("term " .. entry_command(entry))
    vim.cmd("lcd " .. vim.fn.fnameescape(pd))

    if term_bufs[bucket] == nil then
        term_bufs[bucket] = {}
    end
    term_bufs[bucket][term_key] = vim.api.nvim_get_current_buf()
    -- Ours, for jump() to leave out of its buffers: this one is a key away.
    vim.b[term_bufs[bucket][term_key]].foyer_terminal = true
    -- Its `commands` key, which the prompts of the user's own are listed by.
    vim.b[term_bufs[bucket][term_key]].foyer_key = term_key
    -- Attach now so is_idle() actually tracks output from the very first
    -- command instead of reporting a busy terminal as idle.
    setup_terminal_keymaps(term_bufs[bucket][term_key])
    starting[term_bufs[bucket][term_key]] = vim.uv.now()
    unconfirmed[term_bufs[bucket][term_key]] = true
    vim.cmd('close')
    -- TermOpen autocmds may queue a startinsert that only takes effect once we
    -- return to the main loop. The terminal is created in the background here,
    -- so cancel it instead of letting it leak into whatever buffer is current.
    vim.cmd('stopinsert')
    return term_bufs[bucket][term_key]
end

function M.send_terminal_command(term_key, opts)
    opts = opts or {}
    capture(opts)
    -- Where the user is, before any window of ours opens: the file an @
    -- mention offers first, at the line the cursor is on.
    local source = vim.api.nvim_get_current_buf()
    local source_line = vim.api.nvim_win_get_cursor(0)[1]
    local root = project_root(vim.env.HOME)
    local entry = resolve_command(term_key, root, opts.launch_info)
    local bucket = entry_bucket(entry, root)
    local target_buf = term_bufs[bucket] and term_bufs[bucket][term_key] or nil

    if target_buf and not vim.api.nvim_buf_is_valid(target_buf) then
        term_bufs[bucket][term_key] = nil
        target_buf = nil
    end
    if target_buf then touch(target_buf) end

    if not target_buf then
        if opts.auto_start then
            open_term(root, term_key, opts.launch_info)
            opts.auto_start = false
            -- Straight away: the send itself waits for the program to start.
            M.send_terminal_command(term_key, opts)
        else
            vim.notify("Terminal '" .. term_key .. "' not found", vim.log.levels.ERROR)
        end
        return
    end

    local command = opts.command
    local interactive = opts.interactive or opts.selection
    if command == nil or command == "" then
        interactive = true
    end
    if interactive then
        -- The program alone does not say which agent this is: the same one can
        -- run per project and as the global side chat. Name where it belongs
        -- -- the picker's `global` tag, or the project -- so the frame tells
        -- the two apart before anything is sent.
        local place = entry_is_global(entry) and 'global' or vim.fs.basename(root)
        local term = entry_name(entry) .. ' · ' .. place
        local bare_title = 'Ctrl-s to send command to 『' .. term .. ' 』'
        local title = bare_title
        -- The ref never appears in the buffer, so the frame is the only place
        -- the user can see what the send is going to carry.
        if opts.selection then title = title .. ' + ' .. opts.selection end
        -- A global agent is a conversation of its own rather than a helper to
        -- the code on screen, so its prompt takes the window you are in, as a
        -- page you turn to, instead of a float or a split beside your code.
        -- Any other's opens where the call asks, else where its entry does: a
        -- call knows best, <C-t> staying in the window it was pressed in.
        local win_type = 'current'
        if not entry_is_global(entry) then
            -- 'float' alone is a float; anything else, or nothing, a split.
            win_type = (opts.win_type or entry_win_type(entry)) == 'float' and 'float' or 'split'
        end
        -- @ mentions name files the way this agent resolves them: from the
        -- directory it was started in, or absolutely for one that belongs to
        -- no project.
        local function attach_mention(bufnr)
            if config.mention == false then return end
            mention.attach(bufnr, {
                root = not entry_is_global(entry) and vim.fs.normalize(entry_cwd(entry, root)) or nil,
                source = source,
                source_line = source_line,
            })
        end
        create_window(win_type, title, function(bufnr, win_id, reused)
            -- The terminal <C-o> shows, on the buffer.
            vim.b[bufnr].foyer_term = target_buf
            vim.b[bufnr].foyer_term_title = term
            -- A split's prompt outlives the send that opened it, so this send's
            -- ref, seed and history have to reach the buffer rather than the
            -- closure that set the window up.
            if reused then
                vim.b[bufnr].foyer_selection = selection_appendix(opts)
                vim.b[bufnr].foyer_title = title
                set_window_title(win_id, title)
                -- A draft in there is the user's and stays. An empty buffer has
                -- nothing to lose, so a seeded command still gets its chance
                -- rather than going missing without a word.
                if is_blank(buffer_text(bufnr)) and not is_blank(command or "") then
                    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(command, '\n', { plain = true }))
                end
                attach_history(bufnr, target_buf)
                attach_mention(bufnr)
                if opts.show_terminal then
                    -- The prompt is ready behind it; the terminal is what was
                    -- asked for.
                    vim.api.nvim_set_current_buf(target_buf)
                    set_window_title(win_id, term)
                    init_term_buf(target_buf, win_id, bufnr)
                end
                return
            end
            local function init_prompt(start_insert)
                local seed = vim.split(command or "", '\n', { plain = true })
                init_command_buf(bufnr, win_id, seed, function(cmd)
                    clear_foyer_matches()
                    cmd = with_selection(cmd, vim.b[bufnr].foyer_selection)
                    if not is_blank(cmd) then
                        send_command(target_buf, cmd, "\r")
                    end
                    return target_buf
                end, { start_insert = start_insert, term_title = term, term = target_buf, prompt_title = bare_title })
                attach_mention(bufnr)
            end
            -- Mid-output, or asked to show it, the terminal takes the window
            -- instead of a prompt.
            if opts.show_terminal or not M.is_idle(target_buf, 2000) then
                -- A ref with no prompt to ride on goes nowhere. Say so, and
                -- let the frame name what is actually in there.
                if opts.selection then
                    vim.notify('Terminal busy, ' .. opts.selection .. ' not sent', vim.log.levels.WARN)
                end
                -- The prompt is where the terminal's <C-o> goes, so it must
                -- work once the user gets there.
                -- It is set up in Normal mode: insert would land in the
                -- terminal that is about to take the window.
                init_prompt(false)
                -- The selection was dropped, so the frame must not offer it.
                vim.b[bufnr].foyer_title = bare_title
                vim.api.nvim_set_current_buf(target_buf)
                -- After the switch: the frame belongs to the buffer shown.
                set_window_title(win_id, term)
                init_term_buf(target_buf, win_id, bufnr)
                return
            end
            vim.b[bufnr].foyer_selection = selection_appendix(opts)
            vim.b[bufnr].foyer_title = title
            init_prompt(opts.selection ~= nil or not is_blank(command or ""))
        end, { term = target_buf })
    else
        if vim.b[target_buf] and vim.b[target_buf].terminal_job_id then
            send_command(target_buf, command, "\r")
        else
            vim.notify("Failed to send command to terminal", vim.log.levels.ERROR)
        end
    end
end

-- What a key read for the picker means: the terminal key it names, false for
-- a request to back out, nil for a key that names nothing. <C-c> can arrive as
-- an interrupt rather than a key, which is what {ok} false is.
local function picked_key(ok, char)
    if not ok or char == 27 or char == 3 then return false end
    if type(char) ~= 'number' then return nil end
    local key = vim.fn.nr2char(char)
    return config.commands[key] and key or nil
end

-- Wait up to {ms} for a key without drawing anything: true once one is
-- waiting, false on timeout, nil on <C-c>.
local function key_within(ms)
    local ok, status = vim.wait(ms, function() return vim.fn.getchar(1) ~= 0 end, 10)
    if ok then return true end
    if status == -2 then return nil end
    return false
end

-- Show the configured terminals in a popup and wait for the key of one, or nil
-- once the user backs out. A key that names no terminal is ignored rather than
-- taken as a cancel: the choices are on screen, so it is a slip of the finger.
--
-- The popup is lazy: a key typed within `picker_delay` is taken without one, so
-- a mapping run straight through to its terminal key does not flash a window
-- and a dimmed editor for a single frame.
local function pick_terminal(root, launch_info, running)
    local keys = vim.tbl_keys(config.commands)
    if #keys == 0 then
        vim.notify('foyer.nvim: no terminals configured in `commands`', vim.log.levels.WARN)
        return nil
    end

    local waiting = key_within(config.picker_delay)
    if waiting == nil then return nil end
    if waiting then
        local key = picked_key(pcall(vim.fn.getchar))
        -- A slip at this speed is still a slip: show the choices it missed.
        if key ~= nil then return key or nil end
    end

    -- One row per key: its name, then the tags worth knowing before picking.
    -- A global terminal is the same one in every project, and a running one is
    -- reused rather than spawned. The names are padded to one width so the tags
    -- line up in a column of their own.
    local rows = {}
    local name_width = 0
    for _, key in ipairs(keys) do
        local entry = resolve_command(key, root, launch_info)
        local row = {
            key = key,
            name = tostring(entry_name(entry)),
            global = entry_is_global(entry),
            running = running[key] ~= nil,
        }
        name_width = math.max(name_width, vim.fn.strdisplaywidth(row.name))
        table.insert(rows, row)
    end
    -- This project's terminals first, the global ones gathered below them:
    -- what belongs here leads, what follows you everywhere comes after. Each
    -- group stays in key order.
    table.sort(rows, function(a, b)
        if a.global ~= b.global then return b.global end
        return a.key < b.key
    end)

    local any_global = vim.iter(rows):any(function(row) return row.global end)
    local lines, tags = {}, {}
    for i, row in ipairs(rows) do
        local line = (' %s  %s'):format(row.key, row.name)
        if row.global or row.running then
            line = line .. (' '):rep(name_width - vim.fn.strdisplaywidth(row.name)) .. ' '
            if row.global then
                -- Byte offsets, for the highlight below.
                tags[i] = { #line, #line + #'global' }
                line = line .. 'global'
            elseif any_global then
                -- Hold the tag's place, so every ● sits in one column.
                line = line .. (' '):rep(#'global')
            end
            if row.running then line = line .. ' ●' end
        end
        lines[i] = line .. ' '
    end

    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    local footer = ' <Esc> to cancel '
    width = math.max(width, #footer)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace('foyer_pick')
    for i = 1, #lines do
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 1, { end_col = 2, hl_group = 'Special' })
        if tags[i] then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, tags[i][1], { end_col = tags[i][2], hl_group = 'Comment' })
        end
    end
    vim.bo[buf].modifiable = false

    -- Dim the editor behind the picker, so the choice is the one thing that
    -- reads.
    local close_backdrop = open_backdrop()

    local height = math.min(#lines, vim.o.lines - 4)
    local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        style = 'minimal',
        border = 'rounded',
        title = ' Terminal / Foyer ',
        title_pos = 'center',
        footer = footer,
        footer_pos = 'right',
        focusable = false,
        noautocmd = true,
        zindex = 50,
    })

    local picked
    repeat
        -- getchar() blocks before the screen catches up with the new float.
        vim.cmd('redraw')
        picked = picked_key(pcall(vim.fn.getchar))
    until picked ~= nil

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    close_backdrop()
    return picked or nil
end

function M.terminal_command(opts)
    opts = opts or {}
    capture(opts)

    local root = project_root(vim.env.HOME)
    -- Every bucket, not just this project's: a global terminal is offered here
    -- too, and a buffer the user wiped must not be reported running.
    for _, bufs in pairs(term_bufs) do
        for key, buf in pairs(bufs) do
            if not vim.api.nvim_buf_is_valid(buf) then
                bufs[key] = nil
            end
        end
    end

    local term_key = opts.key
    if term_key then
        if config.commands[term_key] == nil then
            vim.notify("foyer.nvim: no terminal configured for key '" .. term_key .. "'",
                vim.log.levels.ERROR)
            return
        end
    else
        term_key = pick_terminal(root, opts.launch_info, running_terminals(root, opts.launch_info))
        if not term_key then return end
    end

    local entry = resolve_command(term_key, root, opts.launch_info)
    local bucket = entry_bucket(entry, root)
    if term_bufs[bucket] == nil then
        term_bufs[bucket] = {}
    end
    local buf = term_bufs[bucket][term_key]
    if buf == nil then
        buf = open_term(root, term_key, opts.launch_info)
    end

    -- Step into the terminal rather than prompt for it, when asked to.
    if opts.switch then
        vim.api.nvim_set_current_buf(buf)
        return buf
    end

    M.send_terminal_command(term_key, opts)
end

-- Switch to this project's running terminal used last before the one in front
-- of the user: two of them toggle, as CTRL-^ does for buffers. Global ones are
-- left out, being no part of the project. In the split or the float foyer
-- keeps, the other terminal takes the window the way a launch does, with its
-- prompt behind <C-o>, draft and all -- only showing the terminal rather than
-- the prompt. In any other window the terminal is simply shown.
function M.switch_terminal()
    local current = vim.api.nvim_get_current_buf()
    local root = project_root(vim.env.HOME)
    -- What a function in `commands` is resolved with, as for any launch.
    local opts = {}
    capture(opts)
    local best_key, best_buf
    -- In key order, so terminals never used are taken in an order that holds.
    local keys = vim.tbl_keys(config.commands)
    table.sort(keys)
    for _, key in ipairs(keys) do
        local entry = resolve_command(key, root, opts.launch_info)
        local buf = not entry_is_global(entry) and term_bufs[root] and term_bufs[root][key]
        if buf and buf ~= current and vim.api.nvim_buf_is_valid(buf)
            and (not best_buf or (last_used[buf] or 0) > (last_used[best_buf] or 0)) then
            best_key, best_buf = key, buf
        end
    end
    if not best_buf then
        vim.notify('foyer: no other terminal running for this project', vim.log.levels.INFO)
        return
    end

    local kind = window.tracked_kind(vim.api.nvim_get_current_win())
    if kind then
        opts.win_type = kind
        opts.show_terminal = true
        M.send_terminal_command(best_key, opts)
    else
        vim.api.nvim_set_current_buf(best_buf)
    end
end

function M.edit_selection()
    local mode = vim.fn.mode()
    if mode == 'v' or mode == 'V' or mode == '\22' then  -- visual, visual-line, or visual-block mode
        vim.cmd('normal! "ay')
    else
        return
    end
    local filetype = vim.bo[0].filetype
    local width = vim.o.columns - 32
    local adata = vim.fn.getreg('a')
    -- A linewise yank ends in a newline, which would seed a blank last line.
    -- Only linewise: a charwise selection that happens to end at a line break
    -- really does include that empty line.
    if mode == 'V' then adata = adata:gsub('\n$', '') end
    local lines = vim.split(adata, '\n', { plain = true })
    local height = math.min(math.max(#lines, math.ceil(#adata / width) + 2), vim.o.lines - 4)
    create_window('float', 'Edit selection', function(bufnr, win_id)
        vim.bo[bufnr].filetype = filetype
        init_command_buf_shared(bufnr, win_id, lines, function()
            vim.cmd('normal! gg0' .. mode .. 'G$"ay')
            dismiss(win_id, bufnr)
            vim.cmd('normal! gv"ap')
        end)
    end, { float = { height = height, width = width } })
end


M.setup = options.setup
-- Required on first use: the picker makes its buffers when it is loaded.
function M.jump()
    return require('foyer.jump').open()
end

M.toggle_full_size = layout.toggle_full_size
M.tab_switch = layout.tab_switch

return M
