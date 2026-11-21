local H = dofile('tests/helpers.lua')
local foyer = H.foyer({ selection_max_lines = 3, commands = { q = H.quiet } })
foyer.is_idle = function() return true end

-- Select with {keys} in {buf}, prompt q, send, and return the copy the label
-- names, or nil.
local function send_from(buf, keys)
    H.reset(buf)
    H.press(function() foyer.prompt({ key = 'q' }) end, keys)
    H.send('fix this')
    vim.cmd('stopinsert')
    local sent = (H.last_text() or ''):gsub('\27%[20[01]~', ''):gsub('\r$', '')
    return sent:match(' in (%S+); edit that copy to change it'), sent
end

-- A buffer of {lines} with no file.
local function scratch(lines)
    H.reset()
    vim.cmd('enew')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
end

-- The agent's edit: {lines} written to {path}, in place or, with {rename},
-- to a file beside it renamed over it, as many editors and agents write.
local function agent_writes(path, lines, rename)
    -- A nil path would write a file named v:null into the repository.
    assert(path, 'no copy named, nothing for the agent to write')
    if rename then
        vim.fn.writefile(lines, path .. '.tmp')
        vim.uv.fs_rename(path .. '.tmp', path)
    else
        vim.fn.writefile(lines, path)
    end
    H.wait(600)
end

local function text(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end

-- What vim.notify was told while {fn} ran.
local function told(fn)
    local said, notify = {}, vim.notify
    vim.notify = function(msg, level) table.insert(said, { msg = msg, level = level }) end
    local ok, err = pcall(fn)
    vim.notify = notify
    if not ok then error(err, 0) end
    return said
end

H.test('a buffer with no file: what the agent writes to the copy comes back, one u away', function()
    local buf = scratch({ 'one', 'teh two', 'three' })
    local copy = send_from(buf, '2GV')
    H.ok(copy, 'a copy named')
    H.eq(text(buf), vim.fn.readfile(copy), 'the copy holds the whole buffer')
    local said = told(function() agent_writes(copy, { 'one', 'the two', 'three' }) end)
    H.eq({ 'one', 'the two', 'three' }, text(buf), 'brought back')
    H.eq({}, said, 'nothing said: it is in view')
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('normal! u')
    H.eq({ 'one', 'teh two', 'three' }, text(buf), 'one u takes it back')
end)

H.test('a file with unsaved changes: the copy comes back into the buffer, and the file is left alone', function()
    local path = vim.fn.tempname() .. '.txt'
    vim.fn.writefile({ 'a', 'b', 'c' }, path)
    H.reset()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'b, unsaved' })
    local copy, sent = send_from(buf, '2GV')
    H.ok(sent:find('(unsaved: my buffer as it is now is in ', 1, true), sent)
    H.ok(copy and copy ~= path, 'a copy, not the file: ' .. tostring(copy))
    agent_writes(copy, { 'a', 'B, fixed', 'c' }, true)
    H.eq({ 'a', 'B, fixed', 'c' }, text(buf), 'brought back, written as a rename')
    H.ok(vim.bo[buf].modified, 'and still unsaved')
    H.eq({ 'a', 'b', 'c' }, vim.fn.readfile(path), 'the file on disk untouched')
    vim.cmd('bwipeout!')
end)

H.test('a file with no unsaved changes gets no copy: the agent edits it', function()
    local path = vim.fn.tempname() .. '.txt'
    vim.fn.writefile({ 'a', 'b' }, path)
    H.reset()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local copy, sent = send_from(vim.api.nvim_get_current_buf(), '1GV')
    H.eq(nil, copy, 'no copy: ' .. sent)
    vim.cmd('bwipeout!')
end)

H.test('only what changed is replaced: marks on the rest stay', function()
    local buf = scratch({ 'keep 1', 'fix', 'keep 3', 'keep 4' })
    local ns = vim.api.nvim_create_namespace('roundtrip_test')
    local mark = vim.api.nvim_buf_set_extmark(buf, ns, 3, 2, {})
    local copy = send_from(buf, '2GV')
    agent_writes(copy, { 'keep 1', 'fixed', 'and a new line', 'keep 3', 'keep 4' })
    H.eq({ 'keep 1', 'fixed', 'and a new line', 'keep 3', 'keep 4' }, text(buf), 'brought back')
    H.eq({ 4, 2 }, vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {}), 'the mark moved with its line')
end)

H.test('edited here meanwhile: the buffer is left as it is, and the copy named for :diffsplit', function()
    local buf = scratch({ 'one', 'two' })
    local copy = send_from(buf, '1GV')
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'two, mine' })
    local said = told(function() agent_writes(copy, { 'ONE', 'two' }) end)
    H.eq({ 'one', 'two, mine' }, text(buf), 'mine kept')
    H.ok(said[1] and said[1].level == vim.log.levels.WARN and said[1].msg:find(copy, 1, true),
        'warned, naming the copy: ' .. vim.inspect(said))
    H.eq({ 'ONE', 'two' }, vim.fn.readfile(copy), 'the agent\'s version still there')
end)

H.test('several edits in turn all come back, and a follow-up goes on with the same copy', function()
    local buf = scratch({ 'a', 'b' })
    local copy = send_from(buf, '1GV')
    agent_writes(copy, { 'A', 'b' })
    agent_writes(copy, { 'A', 'B' })
    H.eq({ 'A', 'B' }, text(buf), 'both')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'A', 'B', 'c' })
    local again = send_from(buf, '3GV')
    H.eq(copy, again, 'the same path')
    H.eq({ 'A', 'B', 'c' }, vim.fn.readfile(again), 'written afresh, the buffer as it is now')
    agent_writes(again, { 'A', 'B', 'C' })
    H.eq({ 'A', 'B', 'C' }, text(buf), 'brought back from the new base')
end)

H.test('out of view, the buffer is named in the notice: with no file, by how it starts', function()
    local buf = scratch({ '', '  Dear team, the release slips to Friday because of the migration' })
    local copy = send_from(buf, '2GV')
    H.reset()
    vim.cmd('enew')
    local said = told(function() agent_writes(copy, { '', 'Dear team, the release slips to Friday.' }) end)
    H.eq('Dear team, the release slips to Friday.', text(buf)[2], 'brought back')
    H.eq('foyer.nvim: [No Name] "Dear team, the release slips t…" updated by the agent', said[1] and said[1].msg,
        vim.inspect(said))
end)

H.test('edited before sending: the copy is made afresh, and what comes back is no conflict', function()
    local buf = scratch({ 'one', 'two' })
    H.reset(buf)
    H.press(function() foyer.prompt({ key = 'q' }) end, '1GV')
    -- Back to the buffer to fix something there, the prompt still open.
    vim.cmd('stopinsert')
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'two, fixed first' })
    H.send('fix this')
    vim.cmd('stopinsert')
    local copy = (H.last_text() or ''):match(' in (%S+); edit that copy')
    H.eq({ 'one', 'two, fixed first' }, vim.fn.readfile(copy), 'the buffer as it was sent')
    local said = told(function() agent_writes(copy, { 'ONE', 'two, fixed first' }) end)
    H.eq({ 'ONE', 'two, fixed first' }, text(buf), 'brought back')
    H.ok(not vim.iter(said):any(function(s) return s.level == vim.log.levels.WARN end), vim.inspect(said))
end)

H.test('a buffer wiped takes its copy with it', function()
    local buf = scratch({ 'x' })
    local copy = send_from(buf, '1GV')
    H.eq(1, vim.fn.filereadable(copy), 'there')
    vim.api.nvim_buf_delete(buf, { force = true })
    H.eq(0, vim.fn.filereadable(copy), 'gone')
end)

H.finish()
