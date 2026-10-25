local H = dofile('tests/helpers.lua')
local foyer = H.foyer({
    picker_delay = 200,
    commands = {
        b = H.quiet,
        a = H.quiet,
        G = vim.tbl_extend('force', H.quiet, { scope = 'global' }),
    },
})

-- What terminal_command() went on to drive, instead of driving it.
local driven
foyer.send_terminal_command = function(key) driven = key end

-- The picker popup, if one is open: its lines and highlight groups.
local function popup()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative ~= '' and cfg.title and cfg.title[1][1]:find('Terminal', 1, true) then
            local buf = vim.api.nvim_win_get_buf(w)
            local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
            return {
                lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
                groups = vim.tbl_map(function(m) return { m[2], m[4].hl_group } end, marks),
            }
        end
    end
end

-- Answer the picker's getchar() calls with {keys}, noting what was on screen
-- each time it asked. Once {keys} runs out, real typeahead answers.
local seen
local function answer(keys)
    seen = {}
    local getchar = vim.fn.getchar
    local i = 0
    vim.fn.getchar = function(peek)
        if peek then return getchar(peek) end
        i = i + 1
        local k = keys[i]
        if k == nil then return getchar() end
        table.insert(seen, popup() or false)
        return type(k) == 'string' and vim.fn.char2nr(k) or k
    end
    return function() vim.fn.getchar = getchar end
end

local function pick(keys, typed_ahead)
    driven = nil
    local restore = answer(keys)
    if typed_ahead then
        vim.api.nvim_feedkeys(typed_ahead, 'n', false)
    end
    foyer.terminal_command()
    restore()
    H.wait(100)
end

H.test('a key typed ahead is taken without drawing the popup', function()
    pick({}, 'a')
    H.eq('a', driven, 'driven')
    -- Read straight from typeahead, never with the popup up.
    H.eq({}, seen, 'stubbed getchar calls')
    H.eq(0, vim.fn.getchar(1), 'typeahead left over')
end)

H.test('<Esc> and <C-c> back out quietly', function()
    local notes = {}
    local notify = vim.notify
    vim.notify = function(m) table.insert(notes, m) end
    pick({ 27 }); H.eq(nil, driven, 'after <Esc>')
    pick({ 3 }); H.eq(nil, driven, 'after <C-c>')
    vim.notify = notify
    H.eq({}, notes, 'notifications')
end)

H.test('with no key in time, the popup lists the terminals', function()
    pick({ 'b' })
    H.eq('b', driven, 'driven')
    H.ok(seen[1], 'popup was up when the key was read')
end)

H.test('a key that names nothing keeps the popup open', function()
    pick({ 'z', 'a' })
    H.eq('a', driven, 'driven')
    H.eq(2, #seen, 'keys read')
    H.ok(seen[2], 'popup still up after the stray key')
end)

H.test('global terminals sit at the bottom, tagged', function()
    pick({ 27 })
    local p = seen[1]
    H.eq(3, #p.lines, 'rows')
    H.ok(p.lines[1]:match('^ a '), 'row 1 is a: ' .. p.lines[1])
    H.ok(p.lines[2]:match('^ b '), 'row 2 is b: ' .. p.lines[2])
    H.ok(p.lines[3]:match('^ G .*global'), 'row 3 is G, tagged: ' .. p.lines[3])
    local tagged = vim.iter(p.groups):any(function(g) return g[1] == 2 and g[2] == 'Comment' end)
    H.ok(tagged, 'tag highlighted: ' .. vim.inspect(p.groups))
end)

H.test('a running terminal is marked', function()
    foyer.send_terminal_command = function(key) driven = key end
    -- Spawn b for real: terminal_command opens a terminal it has not seen.
    pick({ 'b' })
    pick({ 27 })
    local row = vim.tbl_filter(function(l) return l:match('^ b ') end, seen[1].lines)[1]
    H.ok(row and row:find('●', 1, true), 'b marked running: ' .. tostring(row))
end)

H.test('a later setup() keeps what an earlier one set', function()
    foyer.setup({ picker_delay = 0 })
    -- picker_delay = 0 shows the popup at once, commands still all there.
    pick({ 27 })
    H.eq(3, #seen[1].lines, 'rows after a second setup()')
end)

H.finish()
