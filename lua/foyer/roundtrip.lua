-- A buffer an agent cannot edit where it is -- one with no file on disk, or a
-- file with unsaved changes, whose disk copy is not what the user sees -- goes
-- to the agent as a copy. What the agent writes to the copy comes back into
-- the buffer, which stays unsaved: saving is the user's call, and may run
-- formatters, watchers or builds they did not ask for.
local M = {}

-- How long a copy is watched after it was made or last brought back.
local IDLE_MS = 60 * 60 * 1000
-- Agents write a file in more than one go, or write and rename: wait for the
-- last of them.
local SETTLE_MS = 150

-- By buffer: { dir, path, base (the lines both sides last agreed on), tick
-- (the buffer's changedtick then), watcher, idle }.
local live = {}

-- {buf} as a message names it: by its file, or, with none, by how it starts,
-- which tells one draft from another where [No Name] would not.
local function shown_name(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= '' then return vim.fn.fnamemodify(name, ':~:.') end
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, 20, false)) do
        local text = vim.trim(line)
        if text ~= '' then
            if vim.fn.strchars(text) > 30 then text = vim.fn.strcharpart(text, 0, 30) .. '…' end
            return ('[No Name] "%s"'):format(text)
        end
    end
    return '[No Name]'
end

-- Whether {buf} is on screen in this tab page: the user sees it change.
local function in_view(buf)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == buf then return true end
    end
    return false
end

-- The extension of {filetype} where a file name with it says that filetype
-- back, `txt` otherwise.
local function extension(filetype)
    if filetype and filetype ~= '' and vim.filetype.match({ filename = 'x.' .. filetype }) == filetype then
        return filetype
    end
    return 'txt'
end

-- Stop watching {buf}'s copy; with {keep}, leave the copy where it is, for the
-- user to look at.
local function stop(buf, keep)
    local st = live[buf]
    if not st then return end
    live[buf] = nil
    st.watcher:stop()
    st.watcher:close()
    st.idle:stop()
    st.idle:close()
    pcall(vim.api.nvim_del_augroup_by_id, st.group)
    if not keep then vim.fn.delete(st.dir, 'rf') end
end

-- The agent's lines {new}, put into {buf} in place of {old}, change by change
-- rather than all of it: what did not change keeps its marks, folds and the
-- cursor. One undo step: a single u takes the agent's edit back.
local function apply(buf, old, new)
    local a, b = table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n'
    local hunks = (vim.text and vim.text.diff or vim.diff)(a, b, { result_type = 'indices' })
    for i = #hunks, 1, -1 do
        local sa, ca, sb, cb = unpack(hunks[i])
        local repl = vim.list_slice(new, sb, sb + cb - 1)
        if ca == 0 then
            vim.api.nvim_buf_set_lines(buf, sa, sa, false, repl)
        else
            vim.api.nvim_buf_set_lines(buf, sa - 1, sa - 1 + ca, false, repl)
        end
    end
end

-- The copy of {buf} has changed: bring the agent's edit back, unless the user
-- has edited the buffer since, when neither side wins and the copy is left
-- for them to compare.
local function sync(buf)
    local st = live[buf]
    if not st then return end
    if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
        return stop(buf)
    end
    local ok, lines = pcall(vim.fn.readfile, st.path)
    -- Between a write and a rename the file can be missing for a moment.
    if not ok or vim.fn.filereadable(st.path) == 0 then return end
    if vim.deep_equal(lines, st.base) then return end
    if vim.api.nvim_buf_get_changedtick(buf) ~= st.tick or not vim.bo[buf].modifiable then
        stop(buf, true)
        vim.notify(('foyer.nvim: %s changed here after it went to the agent, so its edit was not brought back. '
            .. 'It is in %s: :diffsplit %s'):format(shown_name(buf), st.path, vim.fn.fnameescape(st.path)),
            vim.log.levels.WARN)
        return
    end
    apply(buf, st.base, lines)
    st.base, st.tick = lines, vim.api.nvim_buf_get_changedtick(buf)
    st.idle:again()
    if not in_view(buf) then
        vim.notify(('foyer.nvim: %s updated by the agent'):format(shown_name(buf)), vim.log.levels.INFO)
    end
end

-- The path of a copy of all of {buf}, as it is now, watched for the agent's
-- edits to bring back. The same path for the same buffer, written afresh: a
-- follow-up about it goes on with the copy the agent knows. Named as the
-- buffer is, or `buffer.<ext>` for {filetype}, so the agent knows what it
-- holds. Nil if it cannot be written.
function M.copy(buf, filetype)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local st = live[buf]
    if not st then
        local dir = vim.fn.tempname()
        local made, rc = pcall(vim.fn.mkdir, dir, 'p')
        if not made or rc == 0 then return nil end
        local name = vim.fs.basename(vim.api.nvim_buf_get_name(buf))
        if name == '' then name = 'buffer.' .. extension(filetype) end
        st = { dir = dir, path = vim.fs.joinpath(dir, name) }
        st.watcher = vim.uv.new_fs_event()
        st.idle = vim.uv.new_timer()
        local pending = false
        st.watcher:start(dir, {}, function()
            if pending then return end
            pending = true
            vim.defer_fn(function()
                pending = false
                sync(buf)
            end, SETTLE_MS)
        end)
        st.idle:start(IDLE_MS, IDLE_MS, vim.schedule_wrap(function() stop(buf) end))
        st.group = vim.api.nvim_create_augroup('foyer_copy_' .. buf, { clear = true })
        vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
            group = st.group, buffer = buf, once = true,
            callback = function() stop(buf) end,
        })
        live[buf] = st
    end
    local ok, rc = pcall(vim.fn.writefile, lines, st.path)
    if not ok or rc ~= 0 then
        stop(buf)
        return nil
    end
    st.base, st.tick = lines, vim.api.nvim_buf_get_changedtick(buf)
    st.idle:again()
    return st.path
end

-- Bring the copies {text} names up to date with their buffers, when edited
-- since the copy was made: the prompt goes out with what the buffer is now,
-- and an edit made before sending is no conflict with what comes back.
function M.refresh(text)
    for buf, st in pairs(live) do
        if text:find(st.path, 1, true) and vim.api.nvim_buf_is_valid(buf)
            and vim.api.nvim_buf_get_changedtick(buf) ~= st.tick then
            M.copy(buf)
        end
    end
end

M.extension = extension
M.stop = stop

return M
