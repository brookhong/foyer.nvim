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

H.finish()
