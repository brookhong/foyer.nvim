-- @ mentions in an agent prompt: `@` at the start of a word lists the open
-- files and the recent ones from 'shada', ten at a time and searched by name as
-- you type, each at the line it is most likely being talked about, and picking
-- one puts it in the prompt -- <CR> as `@path:line`, <C-l> as the selection block
-- an agent gets for a visual selection, lines and all.
--
-- The list is Neovim's completion menu, but filled and filtered here: the
-- entries' `word` is whatever was typed after the `@`, so choosing one with the
-- usual keys never rewrites the prompt, and what goes in is decided only when
-- <CR> or <C-l> accepts it.
local context = require('foyer.context')

local M = {}

-- Per prompt buffer, while a mention is being typed: where its `@` is, and the
-- files the menu is showing.
local active = {}

-- Buffers loaded by peek() for a menu, with whether peek() made them, until
-- release() puts them back. One table for every mention rather than one each:
-- a mention started while another's buffers are still to be released finds
-- them loaded and uses them, so they may only go once no mention is open.
local peeked = {}

-- The line a file is offered at: for the file the prompt was opened from, the
-- line the cursor was on; for any other, its last change, else the last cursor
-- position, else the top.
local function offered_line(buf, mention)
    if buf == mention.source and mention.source_line then return mention.source_line end
    local count = vim.api.nvim_buf_line_count(buf)
    for _, mark in ipairs({ '.', '"' }) do
        local line = vim.api.nvim_buf_get_mark(buf, mark)[1]
        if line > 0 and line <= count then return line end
    end
    return 1
end

-- The lines <C-l> sends: the file's last visual selection when it holds the
-- offered line, so a range picked out earlier comes back whole; else that line.
local function offered_range(buf, line)
    local first = vim.api.nvim_buf_get_mark(buf, '<')[1]
    local last = vim.api.nvim_buf_get_mark(buf, '>')[1]
    last = math.min(last, vim.api.nvim_buf_line_count(buf))
    if first > 0 and first <= line and line <= last then return first, last end
    return line, line
end

-- The most files the menu lists at once.
local LIMIT = 10
-- A file this large is not loaded just to be offered.
local MAX_BYTES = 1024 * 1024

-- Load {buf} for the menu without telling anyone: no BufRead, no FileType, so
-- no language server or filetype plugin starts for a file only glanced at in a
-- menu. Its marks still come back from 'shada'. Noted in `peeked`, so that
-- release() can put it back.
local function peek(buf, created)
    if vim.api.nvim_buf_is_loaded(buf) then return true end
    if not pcall(vim.cmd, ('noautocmd call bufload(%d)'):format(buf)) then return false end
    peeked[buf] = created
    return true
end

-- Whether {buf} holds text rather than bytes: a NUL in its first lines says an
-- image or an archive, nothing to show as a line or send as code.
local function is_text(buf)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, 50, false)) do
        -- A NUL comes back as itself, or as the newline a buffer keeps it as.
        if line:find('[%z\n]') then return false end
    end
    return true
end

-- Undo peek(), once the menu is done with the files: a buffer made only to be
-- peeked at is wiped, one that was there already is unloaded again. Left
-- loaded, it would be taken as already read by the next :edit, which would
-- then show the file with no filetype. Only once no mention is open anywhere:
-- until then, one of them may be using any of these.
local function release()
    if next(active) ~= nil then return end
    for buf, created in pairs(peeked) do
        peeked[buf] = nil
        if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
            pcall(vim.cmd, ('noautocmd %s %d'):format(created and 'bwipeout!' or 'bunload!', buf))
        end
    end
end

-- Every file a mention may name, in the order it is offered: the open ones,
-- the file the prompt was opened from first and the rest by when they were
-- last used; then the ones 'shada' remembers (v:oldfiles), most recent first.
-- Only paths and names, nothing loaded: a file is looked into by resolve(),
-- and only once it is one of the few the menu shows.
local function sources(mention)
    local open, seen = {}, {}

    -- Named the way the agent can resolve it: from its project root for a
    -- project agent, absolute for one that has none.
    local function named(path)
        return mention.root and context.relative_to(mention.root, path) or path
    end

    for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
        local buf = info.bufnr
        local file = not vim.b[buf].foyer_prompt and context.file_info(buf)
        if file then
            local path = file.project_root and vim.fs.joinpath(file.project_root, file.current_file) or file.current_file
            if not seen[path] then
                seen[path] = true
                table.insert(open, {
                    path = path,
                    name = named(path),
                    buf = buf,
                    rank = buf == mention.source and math.huge or info.lastused,
                })
            end
        end
    end
    table.sort(open, function(a, b) return a.rank > b.rank end)

    for _, path in ipairs(vim.v.oldfiles) do
        path = vim.fs.normalize(path)
        if not seen[path] then
            seen[path] = true
            table.insert(open, { path = path, name = named(path) })
        end
    end
    return open
end

-- Look into {entry} so the menu can show it: the line it is offered at and that
-- line's text, from a buffer loaded for the purpose if need be. False for a
-- file that cannot be offered -- gone, unreadable, too large, not text. Done
-- once per entry and mention.
local function resolve(entry, mention)
    if entry.ok ~= nil then return entry.ok end
    entry.ok = false
    local size = vim.fn.getfsize(entry.path)
    local created = false
    if not entry.buf then
        if vim.fn.filereadable(entry.path) ~= 1 then return false end
        created = vim.fn.bufexists(entry.path) == 0
        entry.buf = vim.fn.bufadd(entry.path)
    end
    local buf = entry.buf
    if not vim.api.nvim_buf_is_loaded(buf)
        and (size < 0 or size > MAX_BYTES or not peek(buf, created)) then
        if created then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
        return false
    end
    if not is_text(buf) then return false end
    entry.line = offered_line(buf, mention)
    entry.text = vim.trim(vim.api.nvim_buf_get_lines(buf, entry.line - 1, entry.line, false)[1] or '')
    entry.ok = true
    return true
end

-- The mention being typed in {bufnr}, if the cursor is at the end of one: an
-- `@` at the start of a word, with no space after it yet. The files it may
-- name are gathered here, once per mention.
local function mention_at(bufnr)
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local before = vim.api.nvim_get_current_line():sub(1, col)
    local at = before:match('()@%S*$')
    -- Only at the start of a word: `user@host` and `@@` stay as typed.
    if not at or (at > 1 and not before:sub(at - 1, at - 1):find('%s')) then return nil end
    local mention = vim.b[bufnr].foyer_mention or {}
    local files = sources(mention)
    if #files == 0 then return nil end
    return { row = row, col = at - 1, files = files, mention = mention }
end

-- The first LIMIT files whose name holds what has been typed after the `@`,
-- searched for among all of them, so a file not in sight with an empty query
-- is still found by name.
local function matching(state)
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local query = vim.api.nvim_get_current_line():sub(state.col + 2, col):lower()
    local found = {}
    for _, entry in ipairs(state.files) do
        if #found >= LIMIT then break end
        if entry.name:lower():find(query, 1, true) and resolve(entry, state.mention) then
            table.insert(found, entry)
        end
    end
    return found
end

-- Show the files matching what has been typed after the `@`, or stop when the
-- cursor has left the mention: moved off its line, back over the `@`, or past
-- a space.
local function refresh(bufnr)
    local state = active[bufnr]
    if not state or vim.api.nvim_get_current_buf() ~= bufnr or not vim.fn.mode():find('^i') then return end
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local typed = line:sub(state.col + 2, col)
    if row ~= state.row or col <= state.col or line:sub(state.col + 1, state.col + 1) ~= '@'
        or typed:find('%s') then
        M.stop(bufnr)
        return
    end

    -- Moving through the menu fires the same events as typing does; only new
    -- text is a reason to fill it again, which would put the highlight back
    -- on the first entry.
    if typed == state.typed and vim.fn.pumvisible() == 1 then return end
    state.typed = typed
    state.matches = matching(state)
    local items = vim.tbl_map(function(f)
        return {
            word = '@' .. typed,
            abbr = ('%s:%d'):format(f.name, f.line),
            menu = f.text:sub(1, 60),
            dup = 1,
            empty = 1,
        }
    end, state.matches)
    vim.fn.complete(state.col + 1, items)
end

-- What picking {file} puts in: `@path:line` for <CR>, or for <C-l> the lines
-- of the selection block. Read while the menu still holds the file: one it
-- only peeked at is released when the menu closes.
local function payload(file, as_block)
    if not as_block then return ('@%s:%d'):format(file.name, file.line) end
    local first, last = offered_range(file.buf, file.line)
    local sel = context.buffer_selection(file.buf, first, last)
    return vim.split(context.selection_block(sel), '\n', { plain = true })
end

-- Put {text}, from payload(), in place of the mention being typed.
local function accept(bufnr, state, text)
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
    local before, after = line:sub(1, state.col), line:sub(col + 1)

    if type(text) == 'string' then
        -- A space after it, so the next word does not run into the path.
        if not after:find('^%s') then text = text .. ' ' end
        vim.api.nvim_buf_set_text(bufnr, row - 1, state.col, row - 1, col, { text })
        vim.api.nvim_win_set_cursor(0, { row, state.col + #text })
        return
    end

    local block = text
    -- A fence only opens at the start of a line, so the block gets lines of its
    -- own: what came before the `@` stays on the line above it, what came after
    -- goes to the line below, where the cursor is left to carry on.
    local lines = {}
    if before:find('%S') then table.insert(lines, (before:gsub('%s+$', ''))) end
    vim.list_extend(lines, block)
    table.insert(lines, (after:gsub('^%s+', '')))
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, lines)
    vim.api.nvim_win_set_cursor(0, { row + #lines - 1, 0 })
end

-- The key that accepts, as an <expr> mapping. The accepting itself waits for
-- the menu to close, since the menu would otherwise put back the text it last
-- saw.
local function accept_key(bufnr, key, as_block)
    return function()
        local state = active[bufnr]
        if not state then return key end
        -- The entry highlighted in the menu, when the menu shows what is
        -- typed; otherwise the best match for it.
        local menu = vim.fn.pumvisible() == 1 and state.matches
        local matches = menu or matching(state)
        if #matches == 0 then return key end
        local selected = menu and vim.fn.complete_info({ 'selected' }).selected or -1
        local text = payload(matches[(selected >= 0 and selected or 0) + 1], as_block)
        M.stop(bufnr)
        vim.schedule(function() accept(bufnr, state, text) end)
        return vim.fn.pumvisible() == 1 and '<C-e>' or ''
    end
end

-- <CR> and <C-l> are taken only while a mention is open, and given back the
-- moment it closes: the rest of the time <CR> is the newline of a multi-line
-- prompt, and a mapping on it could not tell the two apart -- it runs before
-- the keys typed ahead of it are in the line.
local function take_keys(bufnr)
    vim.keymap.set('i', '<CR>', accept_key(bufnr, '<CR>', false), { buffer = bufnr, expr = true })
    vim.keymap.set('i', '<C-l>', accept_key(bufnr, '<C-l>', true), { buffer = bufnr, expr = true })
end

function M.stop(bufnr)
    local state = active[bufnr]
    if not state then return end
    active[bufnr] = nil
    for _, key in ipairs({ '<CR>', '<C-l>' }) do
        pcall(vim.keymap.del, 'i', key, { buffer = bufnr })
    end
    -- Scheduled: stop() can run inside a mapping, where no buffer may go.
    vim.schedule(release)
end

-- Turn mentions on in prompt buffer {bufnr}. {mention} says who the prompt is
-- for and where it was opened from: `root` the directory the agent names files
-- from (nil for one that serves no project), `source` and `source_line` the
-- buffer and line the user was in. Safe to call again for a reused prompt, to
-- point it at the new send.
function M.attach(bufnr, mention)
    vim.b[bufnr].foyer_mention = mention
    if vim.b[bufnr].foyer_mention_attached then return end
    vim.b[bufnr].foyer_mention_attached = true

    -- One entry stays a menu rather than being taken on the spot, where the
    -- option lets a buffer say so (0.11 and later).
    local ok, info = pcall(vim.api.nvim_get_option_info2, 'completeopt', {})
    if ok and info.scope == 'buf' then vim.bo[bufnr].completeopt = 'menuone,noinsert' end

    vim.keymap.set('i', '@', function()
        -- Everything is read once the `@` is in: a mapping can run before
        -- characters typed ahead of it have been inserted, so the cursor
        -- here may not yet be where the `@` will land.
        vim.schedule(function()
            if vim.api.nvim_get_current_buf() ~= bufnr or not vim.fn.mode():find('^i') then return end
            M.stop(bufnr)
            active[bufnr] = mention_at(bufnr)
            if not active[bufnr] then return end
            take_keys(bufnr)
            refresh(bufnr)
        end)
        return '@'
    end, { buffer = bufnr, expr = true, desc = 'Mention an open file' })

    local group = vim.api.nvim_create_augroup('foyer_mention_' .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChangedP' }, {
        group = group,
        buffer = bufnr,
        callback = function()
            if active[bufnr] then vim.schedule(function() refresh(bufnr) end) end
        end,
    })
    -- BufLeave too: a click into another window keeps Insert mode, so the
    -- InsertLeave here would never come, and with the mention left open no
    -- peeked buffer could ever be released.
    vim.api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave', 'BufWipeout' }, {
        group = group,
        buffer = bufnr,
        callback = function() M.stop(bufnr) end,
    })
end

return M
