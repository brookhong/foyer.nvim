local H = dofile('tests/helpers.lua')
local foyer = H.foyer({
    selection_max_lines = 3,
    commands = {
        q = H.quiet,
        G = vim.tbl_extend('force', H.quiet, { cwd = vim.env.HOME, scope = 'global' }),
    },
})
foyer.is_idle = function() return true end

-- A scratch copy of a file in the repo, so a spec can edit it without saving.
vim.cmd('edit README.md')
local file = vim.api.nvim_get_current_buf()
local path = vim.fs.joinpath(H.root, 'README.md')

-- Select with {keys}, prompt {key}, type a question and send it. What went
-- out, and what the window title promised.
local function ask(keys, key, opts)
    H.reset(file)
    H.press(function()
        foyer.terminal_command(vim.tbl_extend('force', { key = key or 'q' }, opts or {}))
    end, keys)
    local title = H.state().title
    H.send('what is this?')
    local sent = (H.last_text() or ''):gsub('\27%[20[01]~', ''):gsub('\r$', '')
    return sent, title
end

local function lines(from, to)
    return table.concat(vim.api.nvim_buf_get_lines(file, from - 1, to, false), '\n')
end

H.test('one line goes labelled, with its text', function()
    local sent, title = ask('2GV')
    H.eq(('what is this?\n\nSelected in my editor: %s, line 2\n```markdown\n%s\n```'):format(path, lines(2, 2)),
        sent, 'sent')
    H.ok(title:find('+ README.md:2', 1, true), 'title keeps the short form: ' .. title)
end)

H.test('a range says lines, and the path is absolute for a global agent too', function()
    local sent = ask('1GVj', 'G')
    H.ok(sent:find(('Selected in my editor: %s, lines 1-2\n'):format(path), 1, true), sent)
end)

H.test('past selection_max_lines only the label goes', function()
    local sent = ask('1GV3j')
    H.eq(('what is this?\n\nSelected in my editor: %s, lines 1-4'):format(path), sent, 'sent')
end)

H.test('unsaved edits are said, and the buffer\'s text is what goes', function()
    vim.api.nvim_buf_set_lines(file, 0, 0, false, { 'a line only the buffer has' })
    local sent = ask('1GV')
    H.ok(sent:find(', line 1 (unsaved; the file on disk differs)\n', 1, true), sent)
    H.ok(sent:find('a line only the buffer has', 1, true), 'the buffer\'s line: ' .. sent)
end)

H.test('text holding a fence gets a longer one', function()
    vim.api.nvim_buf_set_lines(file, 0, 1, false, { 'code with ``` in it' })
    local sent = ask('1GV')
    H.ok(sent:find('\n````markdown\ncode with ``` in it\n````$'), sent)
end)

H.test('a selection the caller gives is sent as given', function()
    local sent, title = ask('', 'q', { selection = 'see the README', launch_info = {} })
    H.eq('what is this?\n\nsee the README', sent, 'sent')
    H.ok(title:find('+ see the README', 1, true), 'title: ' .. title)
end)

H.test('history keeps the prompt without the selection', function()
    H.reset(file)
    H.press(function() foyer.terminal_command({ key = 'q' }) end)
    vim.cmd('stopinsert')
    H.feed('<Up>')
    H.eq({ 'what is this?' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'recalled')
end)

-- A buffer never written: no file to name, so the lines are all there is.
local function ask_unnamed(keys, text)
    H.reset()
    vim.cmd('enew')
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = 'lua'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
    H.press(function() foyer.terminal_command({ key = 'q' }) end, keys)
    local title = H.state().title
    H.send('what is this?')
    local sent = (H.last_text() or ''):gsub('\27%[20[01]~', ''):gsub('\r$', '')
    vim.cmd('stopinsert')
    return sent, title
end

H.test('a selection in a buffer never written goes with its lines', function()
    local sent, title = ask_unnamed('1GVj', { 'local x = 1', 'return x' })
    H.eq('what is this?\n\nSelected in my editor: lines 1-2 of a buffer with no file\n'
        .. '```lua\nlocal x = 1\nreturn x\n```', sent, 'sent')
    H.ok(title:find('+ [No Name]:1-2', 1, true), 'the frame says where from: ' .. title)
end)

H.test('past selection_max_lines, a buffer never written goes as a file the label names', function()
    local sent = ask_unnamed('1GV3j', { 'a', 'b', 'c', 'd' })
    local label, path = sent:match('^what is this%?\n\n(Selected in my editor: lines 1%-4 of a buffer with no file),'
        .. ' copied whole to (%S+%.lua)$')
    H.ok(label, 'the label, naming the copy, and no lines inline: ' .. sent)
    H.eq({ 'a', 'b', 'c', 'd' }, vim.fn.readfile(path), 'the copy holds the lines')
    H.ok(vim.startswith(path, vim.fs.dirname(vim.fn.tempname())), 'under tempname(): ' .. path)
end)

H.test('a copy takes .txt for a filetype with no extension of its own', function()
    H.reset()
    vim.cmd('enew')
    vim.bo.filetype = 'python'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '1', '2', '3', '4' })
    H.press(function() foyer.terminal_command({ key = 'q' }) end, '1GV3j')
    H.send('what is this?')
    vim.cmd('stopinsert')
    H.ok(H.last_text():match('copied whole to %S+%.txt\27%[201~\r$'), H.last_text())
end)

H.test('with selection_max_lines = 0, a buffer never written always goes as a file', function()
    foyer.setup({ selection_max_lines = 0 })
    local sent = ask_unnamed('1GV', { 'only' })
    foyer.setup({ selection_max_lines = 3 })
    local path = sent:match('copied whole to (%S+)$')
    H.ok(path, sent)
    H.eq({ 'only' }, vim.fn.readfile(path), 'the copy')
end)

H.test('if the copy cannot be written, the lines go inline', function()
    local tempname = vim.fn.tempname
    vim.fn.tempname = function() return '/nonexistent/dir/x' end
    local sent = ask_unnamed('1GV3j', { 'a', 'b', 'c', 'd' })
    vim.fn.tempname = tempname
    H.eq('what is this?\n\nSelected in my editor: lines 1-4 of a buffer with no file\n'
        .. '```lua\na\nb\nc\nd\n```', sent, 'inline')
end)

H.test('a selection in a scratch buffer still goes nowhere', function()
    H.reset()
    vim.cmd('enew')
    vim.bo.buftype = 'nofile'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'scratch' })
    H.press(function() foyer.terminal_command({ key = 'q' }) end, '1GV')
    H.ok(not H.state().title:find('+', 1, true), 'nothing advertised: ' .. H.state().title)
    H.send('what is this?')
    H.eq('what is this?\r', H.last_text(), 'the prompt alone')
    vim.cmd('stopinsert')
end)

H.finish()
