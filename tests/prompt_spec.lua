local H = dofile('tests/helpers.lua')
local foyer = H.foyer({ commands = {
    q = H.quiet, n = H.noisy, w = H.quiet,
    g = vim.tbl_extend('force', H.quiet, { scope = 'global' }),
} })

-- Showing a terminal in a window of another size reflows it, which counts as
-- output, so even the quiet one reads as busy for two seconds after each send.
-- Only the noisy terminal is asked for real.
local is_idle = foyer.is_idle
foyer.is_idle = function(buf, ms)
    if vim.api.nvim_buf_get_name(buf):find('while', 1, true) then return is_idle(buf, ms) end
    return true
end

vim.cmd('edit README.md')
local file = vim.api.nvim_get_current_buf()

local function prompt(opts)
    H.press(function() foyer.prompt(vim.tbl_extend('force', { key = 'q' }, opts or {})) end)
end

H.test('the prompt opens in a split by default, titled with the terminal', function()
    H.reset(file)
    prompt()
    local s = H.state()
    H.ok(s.prompt and not s.float, 'a prompt in a split')
    H.eq(2, s.wins, 'beside the file')
    H.ok(s.title:find('sh · foyer.nvim', 1, true), 'title: ' .. s.title)
end)

H.test('a sent line reaches the terminal as it is, with Enter', function()
    H.reset(file)
    prompt()
    H.send('echo hello')
    -- The first send to a terminal holds its Enter until the text has shown.
    H.eq('echo hello\r', table.concat(H.sent()), 'the line and Enter, nothing before it')
    H.ok(H.state().terminal, 'the window now shows the terminal')
end)

H.test('a multi-line prompt goes as one bracketed paste', function()
    H.reset(file)
    prompt()
    H.send({ 'first', 'second' })
    H.eq('\27[200~first\nsecond\27[201~\r', H.last_text(), 'sent')
end)

H.test('a blank prompt sends nothing', function()
    H.reset(file)
    prompt()
    H.send({ '  ', '' }, true)
    H.eq(nil, H.last_text(), 'sent')
end)

H.test('<Up> recalls history, filtered by the draft', function()
    H.reset(file)
    prompt(); H.send('alpha one')
    H.reset(file)
    prompt(); H.send('beta two')
    H.reset(file)
    prompt()
    -- Not <Esc>: on an empty draft that closes the prompt.
    vim.cmd('stopinsert')
    H.feed('<Up>')
    H.eq({ 'beta two' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'latest first')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'alp' })
    H.feed('<Up>')
    H.eq({ 'alpha one' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'filtered')
end)

local jump = require('foyer.jump')
local read_key = jump.read_key
local shown, shown_at
-- Answer the prompt picker with {key}, noting what its popup showed; nil
-- puts the real key reader back.
local function answer(key)
    shown, shown_at = nil, nil
    if key == nil then jump.read_key = read_key; return end
    jump.read_key = function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            local cfg = vim.api.nvim_win_get_config(w)
            if cfg.title and cfg.title[1][1]:find('Frequent', 1, true) then
                shown = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
                shown_at = {
                    pos = vim.api.nvim_win_get_position(w),
                    width = vim.api.nvim_win_get_width(w),
                    height = vim.api.nvim_win_get_height(w),
                }
            end
        end
        return key
    end
end

H.test('<C-f> labels history, most used first; a label inserts, Shift replaces', function()
    for _, cmd in ipairs({ 'review staged', 'commit staged', 'review staged', 'one-off' }) do
        H.reset(file)
        prompt(); H.send(cmd)
    end
    H.reset(file)
    prompt()
    vim.cmd('stopinsert')
    answer('a')
    H.feed('<C-f>')
    H.ok(shown[1]:match('^ a  review staged +2\u{00d7} $'), 'the most used first: ' .. shown[1])
    H.ok(shown[2]:match('^ s  one%-off'), 'then the latest: ' .. shown[2])
    H.ok(shown[3]:match('^ d  commit staged'), 'd: ' .. shown[3])
    H.eq({ 'review staged' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'into the empty draft')
    H.ok(H.state().prompt, 'not sent')

    local all = shown
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'ab' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    answer('d')
    H.feed('<C-f>')
    H.eq(all, shown, 'the same list, whatever the draft')
    H.eq({ 'acommit stagedb' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'after the cursor, as p puts')

    H.sent_clear()
    answer('D')
    H.feed('<C-f>')
    H.eq({ 'commit staged' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'Shift replaces it all')
    H.ok(H.state().prompt, 'and sends nothing')
    H.eq(nil, H.last_text(), 'nothing sent')
    answer(nil)
end)

H.test('<C-f> in Insert mode inserts and goes on typing', function()
    H.reset(file)
    prompt()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'please ' })
    vim.cmd('stopinsert')
    answer('a')
    H.feed('A<C-f>!<Esc>')
    H.eq({ 'please review staged!' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'at the cursor, typing on after it')
    answer('S')
    H.feed('A<C-f>?<Esc>')
    H.eq({ 'one-off?' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'Shift replaces it all, typing on after it')
    answer(nil)
end)

-- Answer the prompt picker with each of {keys} in turn, noting what its popup
-- showed -- lines, title, footer, place and size -- before each.
local seen
local function answers(keys)
    seen = {}
    local i = 0
    jump.read_key = function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            local cfg = vim.api.nvim_win_get_config(w)
            -- The picker's title is the filter while there is one.
            if cfg.zindex == 60 and cfg.title then
                local buf = vim.api.nvim_win_get_buf(w)
                local hl = {}
                for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
                    -- The first row's, to compare with what was typed.
                    if m[4].hl_group == 'FoyerMatch' and m[2] == 0 then
                        local line = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1]
                        table.insert(hl, line:sub(m[3] + 1, m[4].end_col))
                    end
                end
                table.insert(seen, {
                    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
                    title = cfg.title[1][1],
                    footer = cfg.footer[1][1],
                    hl = table.concat(hl),
                    box = { vim.api.nvim_win_get_position(w), cfg.width, cfg.height },
                })
            end
        end
        i = i + 1
        if i > #keys then return '\3' end
        return keys[i]
    end
end

H.test('/ in the picker filters history by words, over all of it', function()
    -- More prompts than labels, so the one wanted is off the list at first.
    local labels = #require('foyer.config').options.jump.characters
    for k = 1, labels + 2 do
        H.reset(file)
        prompt(); H.send('filler ' .. k)
    end
    H.reset(file)
    prompt(); H.send('review the staged changes')
    H.reset(file)
    prompt(); H.send('Stage the review notes')
    -- The oldest filler, sent once, is the least worth recalling.
    H.reset(file)
    prompt()
    vim.cmd('stopinsert')
    answers({ '/', 'f', 'i', 'l', 'l', 'e', 'r', ' ', '1', '\r', 'a' })
    H.feed('<C-f>')
    local first = seen[1]
    H.ok(first.footer:find('/: filter', 1, true), 'the key offered: ' .. first.footer)
    H.eq(labels, #vim.tbl_filter(function(l) return l:match('^ %S  ') end, first.lines), 'one per label')
    H.ok(not vim.iter(first.lines):any(function(l) return l:match('filler 1 ') end), 'filler 1 off the list')
    H.eq(' /\u{2581} ', seen[2].title, 'the filter typed in the top border')
    local filtered = seen[10]
    H.eq(' /filler 1\u{2581} ', filtered.title, 'as typed')
    for _, l in ipairs(filtered.lines) do
        if l:match('^ %S  ') then H.ok(l:find('filler 1', 1, true), 'only "filler" and "1": ' .. l) end
    end
    H.ok(vim.iter(filtered.lines):any(function(l) return l:match('filler 1 ') end), 'filler 1 on it now')
    H.eq('filler1', filtered.hl, 'the words highlighted in the first row')
    for k = 2, #seen do H.eq(first.box, seen[k].box, 'the popup stays put, key ' .. k) end
    H.ok(seen[11].title:find('/filler 1 ', 1, true), 'picking among them: ' .. seen[11].title)
    local picked = vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]
    H.ok(picked:match('^filler 1%d?$'), 'a label picks from the filtered list: ' .. picked)
    answer(nil)
end)

H.test('the words match in any order, ignoring case; nothing fuzzy', function()
    H.reset(file)
    prompt()
    vim.cmd('stopinsert')
    answers({ '/', 'r', 'e', 'v', 'i', 'e', 'w', ' ', 's', 't', 'a', 'g', 'e', '\27', '/', 'r', 'v', 's', 't', 'g' })
    H.feed('<C-f>')
    local found = vim.tbl_filter(function(l) return l:match('^ %S  ') end, seen[14].lines)
    local text = table.concat(found, '\n')
    H.ok(text:find('Stage the review notes', 1, true), 'in any order, ignoring case: ' .. text)
    H.ok(text:find('review the staged changes', 1, true), 'in order: ' .. text)
    H.ok(not text:find('commit staged', 1, true), 'not with one word alone: ' .. text)
    H.ok(found[1]:find('review staged', 1, true), 'still the most used first: ' .. found[1])
    H.ok(vim.iter(seen[20].lines):any(function(l) return l:find('no match', 1, true) end), '"rvstg" matches nothing')
    answer(nil)
end)

H.test('in the filter, <C-w> takes back a word, <C-u> the lot', function()
    H.reset(file)
    prompt()
    vim.cmd('stopinsert')
    answers({ '/', 'r', 'e', 'v', ' ', 's', 't', ' ', '\23', '\23', 'x', ' ', 'y', '\21', '\27', '\27' })
    H.feed('<C-f>')
    H.eq(' /rev st \u{2581} ', seen[9].title, 'typed')
    H.eq(' /rev \u{2581} ', seen[10].title, '<C-w>: the word and the space after it')
    H.eq(' /\u{2581} ', seen[11].title, '<C-w> again: the word before')
    H.eq(' /x y\u{2581} ', seen[14].title, 'typed again')
    H.eq(' /\u{2581} ', seen[15].title, '<C-u>: the lot')
    answer(nil)
end)

H.test('in the filter, <BS> edits, <Esc> clears, and <Esc> again closes', function()
    H.reset(file)
    prompt()
    vim.cmd('stopinsert')
    answers({ '/', 'z', 'q', 'x', '\8', '\8', '\8', 'r', 'e', 'v', '\27', '\27' })
    H.feed('<C-f>')
    H.ok(vim.iter(seen[5].lines):any(function(l) return l:find('no match', 1, true) end), 'nothing for zqx')
    H.eq(' /\u{2581} ', seen[8].title, 'empty again, still typing')
    H.ok(seen[11].lines[1]:find('review', 1, true), '"rev" finds review: ' .. seen[11].lines[1])
    H.eq(' Frequent prompts / Foyer ', seen[12].title, '<Esc> cleared it')
    H.ok(seen[12].footer:find('/: filter', 1, true), 'and the footer says so: ' .. seen[12].footer)
    H.eq(12, #seen, 'the second <Esc> closed the popup')
    H.eq({ '' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'nothing put in')
    answer(nil)
end)

-- Each prompts test starts from none, whatever one before it left behind.
local function no_prompts() require('foyer.config').options.prompts = {} end

H.test('a terminal\'s own prompts come first, starred, in their order', function()
    no_prompts()
    foyer.setup({ prompts = {
        q = { 'explain this error', 'review staged', 'write tests\nfor this' },
        n = { 'only for the noisy one' },
    } })
    H.reset(file)
    prompt()
    vim.cmd('stopinsert')
    -- Filter, back to picking, clear the filter, then s on the full list.
    answers({ '/', 'r', 'e', 'v', '\r', '\27', 's' })
    H.feed('<C-f>')
    local rows = vim.tbl_filter(function(l) return l:match('^ %S  ') end, seen[1].lines)
    H.ok(rows[1]:match('^ a  explain this error +\u{2605} $'), 'first, starred: ' .. rows[1])
    H.ok(rows[2]:match('^ s  review staged +\u{2605} $'), 'in the order given, starred though sent: ' .. rows[2])
    H.ok(rows[3]:match('^ d  write tests'), 'a prompt of many lines: ' .. rows[3])
    H.ok(not rows[4]:find('\u{2605}', 1, true), 'then history: ' .. rows[4])
    local all = table.concat(seen[1].lines, '\n')
    H.eq(1, select(2, all:gsub('review staged', '')), 'once, not again from history')
    H.ok(not all:find('noisy', 1, true), 'not another terminal\'s')
    H.ok(seen[5].lines[1]:find('review staged', 1, true), 'the filter finds them too: ' .. seen[5].lines[1])
    H.eq({ 'review staged' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'a label puts one in')
    H.ok(H.state().prompt, 'and sends nothing')
    answer(nil)
    no_prompts()
end)

H.test('own prompts with no history yet still open the picker', function()
    no_prompts()
    -- A terminal never sent to: w, in a fresh buffer.
    foyer.setup({ commands = { w = H.quiet }, prompts = { w = { 'hello there' } } })
    H.reset(file)
    H.press(function() foyer.prompt({ key = 'w' }) end)
    vim.cmd('stopinsert')
    answers({ 'a' })
    H.feed('<C-f>')
    H.eq({ 'hello there' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'picked from the list')
    answer(nil)
    no_prompts()
end)

H.test('prompts that make no sense are said so', function()
    no_prompts()
    local config = require('foyer.config').options
    local notify, said = vim.notify, {}
    vim.notify = function(msg) table.insert(said, msg) end
    foyer.setup({ prompts = { 'no key' } })
    foyer.setup({ prompts = { q = 'not a list' } })
    foyer.setup({ prompts = { q = { 'fine', 5 } } })
    foyer.setup({ prompts = { q = { '  ' } } })
    foyer.setup({ prompts = { zz = { 'for nothing' } } })
    vim.notify = notify
    H.ok(said[1] and said[1]:find('by `commands` key', 1, true), said[1])
    for k = 2, 4 do H.ok(said[k] and said[k]:find('prompts.q must be', 1, true), tostring(said[k])) end
    H.ok(said[5] and said[5]:find('prompts.zz: no terminal', 1, true), tostring(said[5]))
    H.eq(nil, config.prompts.q, 'none of q\'s taken')
    no_prompts()
end)

-- Open the picker from a draft of {lines}, the cursor at the end of it.
local function pick_at_end(win_type, lines)
    H.reset(file)
    prompt({ win_type = win_type })
    local prompt_win = vim.api.nvim_get_current_win()
    vim.cmd('stopinsert')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.cmd('normal! G$')
    local at = vim.fn.screenpos(prompt_win, vim.fn.line('.'), vim.fn.col('.'))
    answer('\27')
    H.feed('<C-f>')
    local seen = shown_at
    answer(nil)
    shown_at = seen
    H.ok(shown_at, 'the picker opened')
    return at
end

for _, win_type in ipairs({ 'float', 'split' }) do
    H.test(win_type .. ': the picker pops up just below the cursor', function()
        local at = pick_at_end(win_type, { 'first', 'review' })
        -- 0-based position of the border; screenpos() is 1-based.
        H.eq(at.row, shown_at.pos[1], 'its border on the row under the cursor')
        if at.col - 1 + shown_at.width + 2 <= vim.o.columns then
            H.eq(at.col - 1, shown_at.pos[2], 'from the cursor\'s column')
        else
            H.eq(vim.o.columns - shown_at.width - 2, shown_at.pos[2], 'pushed back on screen')
        end
    end)
end

H.test('with no room below the cursor, the picker opens above it', function()
    local lines = {}
    for i = 1, vim.o.lines - 4 do lines[i] = 'line ' .. i end
    local at = pick_at_end('split', lines)
    H.eq(at.row - 1 - (shown_at.height + 2), shown_at.pos[1], 'its border ends on the row above the cursor')
end)

H.test('a long prompt wraps under its label; a longer one ends in …', function()
    local long = ('word '):rep(30):gsub(' $', '')
    local huge = 'first line\n\n' .. ('more '):rep(200)
    for _, cmd in ipairs({ huge, long }) do
        H.reset(file)
        prompt(); H.send(vim.split(cmd, '\n'))
    end
    H.reset(file)
    prompt()
    vim.cmd('stopinsert')
    answer('\27')
    H.feed('<C-f>')
    -- The rows of the prompt whose label row starts with {text}: that row and
    -- the indented ones under it.
    local function rows_of(text)
        for i, line in ipairs(shown) do
            if line:match('^ %S  ') and line:sub(5, 4 + #text) == text then
                local rows = { line }
                while shown[i + #rows] and shown[i + #rows]:match('^    ') do
                    table.insert(rows, shown[i + #rows])
                end
                return rows
            end
        end
        error('not shown: ' .. text .. '\n' .. table.concat(shown, '\n'))
    end

    local rows = rows_of('word word')
    H.ok(#rows > 1, 'wrapped onto more rows')
    local words = 0
    for _, line in ipairs(rows) do words = words + select(2, line:gsub('word', '')) end
    H.eq(30, words, 'every word shown, none cut')

    rows = rows_of('first line')
    H.eq(4, #rows, 'four rows at most, none of them blank')
    H.ok(rows[2]:match('^    more'), 'then the next line, past the blank one')
    H.ok(rows[4]:match('…$'), 'ending in …: ' .. rows[4])
    answer(nil)
end)

H.test('an error in the picker still brings the cursor back and the popup down', function()
    H.reset(file)
    prompt()
    vim.cmd('stopinsert')
    local guicursor = vim.o.guicursor
    local wins = #vim.api.nvim_list_wins()
    -- No key at all where one is looked up, so the picker fails past the key
    -- read, which takes an error there for <C-c>. Called rather than typed:
    -- an error out of a typed mapping is only a message.
    require('foyer.jump').read_key = function() return {} end
    local ok, err = pcall(vim.fn.maparg('<C-f>', 'n', false, true).callback)
    answer(nil)
    H.ok(not ok, 'the error is not swallowed')
    H.ok(tostring(err):find('find', 1, true), 'it is the one raised: ' .. tostring(err))
    H.eq(guicursor, vim.o.guicursor, 'the cursor is back')
    H.eq(wins, #vim.api.nvim_list_wins(), 'no popup left behind')
end)

H.test('keys.prompt.history_pick = false leaves the key alone', function()
    foyer.setup({ keys = { prompt = { history_pick = false } } })
    H.reset(file)
    prompt()
    H.eq('', vim.fn.maparg('<C-f>', 'n'), 'no normal-mode key')
    H.eq('', vim.fn.maparg('<C-f>', 'i'), 'no insert-mode key')
    foyer.setup({ keys = { prompt = { history_pick = { n = '<C-f>', i = '<C-f>' } } } })
end)

H.test('<C-c> closes the float and drops the draft', function()
    H.reset(file)
    prompt()
    local buf = H.state().buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a draft' })
    vim.cmd('stopinsert')
    H.feed('<Esc>')
    H.eq(buf, H.state().buf, '<Esc> keeps a draft')
    H.feed('<C-c>')
    H.eq(file, H.state().buf, 'back in the file')
    H.ok(not vim.api.nvim_buf_is_valid(buf), 'draft buffer gone')
end)

H.test('a busy terminal shows itself; <C-o> reaches a working prompt', function()
    H.reset(file)
    -- Spawn it and let it come up and start printing.
    foyer.prompt({ key = 'n', command = ':' })
    H.wait(1500)
    H.reset(file)
    H.press(function() foyer.prompt({ key = 'n' }) end)
    H.ok(H.state().terminal, 'busy: the terminal is shown')
    vim.cmd('stopinsert')
    H.feed('<C-o>')
    H.ok(H.state().prompt, '<C-o> lands in the prompt')
    H.send('hi')
    H.eq('hi\r', H.last_text(), '<CR> from there sends')
end)

H.test('a terminal\'s own win_type places its prompt, unless the call names one', function()
    foyer.setup({ commands = { s = vim.tbl_extend('force', H.quiet, { win_type = 'float' }) } })
    H.reset(file)
    H.press(function() foyer.prompt({ key = 's' }) end)
    H.ok(H.state().prompt and H.state().float, 'a prompt in a float')
    vim.cmd('stopinsert')
    H.reset(file)
    H.press(function() foyer.prompt({ key = 's', win_type = 'split' }) end)
    local s = H.state()
    H.ok(s.prompt and not s.float, 'the call\'s split wins')
    vim.cmd('stopinsert')
    H.reset(file)
    prompt()
    H.ok(not H.state().float, 'a terminal with none: a split')
end)

H.test('a split is reused rather than stacked', function()
    H.reset(file)
    prompt({ win_type = 'split' })
    local first = H.state()
    H.eq(2, first.wins, 'one split beside the file')
    vim.cmd('wincmd p')
    prompt({ win_type = 'split' })
    H.eq(2, H.state().wins, 'still one split')
    H.eq(first.win, H.state().win, 'the same window')
end)

for _, win_type in ipairs({ 'float', 'split' }) do
    H.test(win_type .. ': launching another terminal replaces the window rather than stacking', function()
        H.reset(file)
        prompt({ win_type = win_type })
        local first = H.state()
        vim.cmd('stopinsert | wincmd p')
        prompt({ key = 'w', win_type = win_type })
        local s = H.state()
        H.eq(first.wins, s.wins, 'no window stacked')
        H.eq(first.win, s.win, 'the same window')
        H.ok(s.prompt and s.buf ~= first.buf, 'a fresh prompt')
        H.ok(s.title:find('Ctrl-s to send command', 1, true), 'its frame: ' .. s.title)
    end)

    H.test(win_type .. ': the previous terminal\'s draft comes back with it', function()
        H.reset(file)
        prompt({ win_type = win_type })
        local first = H.state()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'half written' })
        vim.cmd('stopinsert | wincmd p')
        prompt({ key = 'w', win_type = win_type })
        local second = H.state()
        H.ok(second.buf ~= first.buf, 'the other terminal\'s prompt')
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'other draft' })
        vim.cmd('stopinsert | wincmd p')
        prompt({ win_type = win_type })
        local s = H.state()
        H.eq(first.win, s.win, 'the same window')
        H.eq(first.buf, s.buf, 'the first prompt, back')
        H.eq({ 'half written' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'its draft kept')
        H.ok(s.title:find('Ctrl-s to send command', 1, true), 'its frame: ' .. s.title)
        H.sent_clear()
        H.send({ 'half written' })
        H.eq('half written\r', table.concat(H.sent()), 'sent')
        H.eq(vim.b[first.buf].foyer_term, H.state().buf, 'to its own terminal')
        vim.cmd('stopinsert | wincmd p')
        prompt({ key = 'w', win_type = win_type })
        H.eq(second.buf, H.state().buf, 'and the other one\'s, back too')
        H.eq({ 'other draft' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'with its draft')
    end)

    H.test(win_type .. ': a draft left behind <C-o> comes back when its terminal is launched again', function()
        H.reset(file)
        prompt({ win_type = win_type })
        local first = H.state()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'half written' })
        vim.cmd('stopinsert')
        H.feed('<C-o>')
        H.ok(H.state().terminal, 'the terminal is shown')
        vim.cmd('stopinsert | wincmd p')
        prompt({ win_type = win_type })
        local s = H.state()
        H.eq(first.win, s.win, 'the same window')
        H.eq(first.buf, s.buf, 'the same prompt')
        H.eq({ 'half written' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'its draft kept')
    end)

    H.test(win_type .. ': prompts set aside go with their window', function()
        H.reset(file)
        prompt({ win_type = win_type })
        local first = H.state()
        vim.cmd('stopinsert | wincmd p')
        prompt({ key = 'w', win_type = win_type })
        vim.cmd('stopinsert')
        H.ok(vim.api.nvim_buf_is_valid(first.buf), 'set aside, not wiped')
        vim.api.nvim_win_close(first.win, true)
        H.wait(50)
        H.ok(not vim.api.nvim_buf_is_valid(first.buf), 'wiped with the window')
    end)

    H.test(win_type .. ': a terminal left by a send is replaced by another terminal\'s prompt', function()
        H.reset(file)
        prompt({ win_type = win_type })
        H.send('hello')
        local first = H.state()
        H.ok(first.terminal, 'the terminal took the window')
        vim.cmd('stopinsert | wincmd p')
        prompt({ key = 'w', win_type = win_type })
        local s = H.state()
        H.eq(first.win, s.win, 'the same window')
        H.eq(first.wins, s.wins, 'no window stacked')
        H.ok(s.prompt, 'the new terminal\'s prompt')
        H.sent_clear()
        H.send('hi there')
        H.eq('hi there\r', table.concat(H.sent()), 'sent')
        H.ok(H.state().terminal and H.state().buf ~= first.buf, 'the new terminal took the window')
    end)
end

H.test('a global prompt borrowing the split is not taken for the split\'s terminal', function()
    H.reset(file)
    prompt({ win_type = 'split' })
    local q_prompt = H.state().buf
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'for q' })
    vim.cmd('stopinsert')
    -- From inside the split: the global prompt borrows it.
    prompt({ key = 'g' })
    local g_prompt = H.state().buf
    H.ok(g_prompt ~= q_prompt, 'the global terminal\'s own prompt')
    vim.cmd('stopinsert | wincmd p')
    prompt({ win_type = 'split' })
    H.eq(q_prompt, H.state().buf, 'the split terminal\'s prompt, back')
    H.eq({ 'for q' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'with its draft')
    H.send('for q')
    H.eq(vim.b[q_prompt].foyer_term, H.state().buf, 'sent to the split\'s terminal')
    H.ok(vim.api.nvim_buf_is_valid(g_prompt), 'the global prompt set aside, not wiped')
end)

H.test('a split taken over for a file is left to it, and its successor kept', function()
    H.reset(file)
    local function split() H.press(function() foyer.prompt({ key = 'q', win_type = 'split' }) end) end
    split()
    local taken = H.state().win
    vim.cmd('stopinsert | edit LICENSE')
    vim.cmd('wincmd p')
    split()
    local successor = H.state().win
    H.ok(successor ~= taken, 'a new split rather than the user\'s window')
    H.ok(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(taken)):find('LICENSE$'), 'LICENSE left where it was')
    vim.cmd('stopinsert')
    vim.api.nvim_win_close(taken, true)
    vim.cmd('wincmd p')
    split()
    H.eq(successor, H.state().win, 'the successor is still the split')
    H.eq(2, H.state().wins, 'no third window')
end)

for _, win_type in ipairs({ 'float', 'split' }) do
    H.test(win_type .. ': after a send, <C-o> finds the prompt empty and the selection gone', function()
        H.reset(file)
        -- A selection, so there is something that must not ride along again.
        H.press(function() foyer.prompt({ key = 'q', win_type = win_type }) end, '3GV')
        local prompt_buf = H.state().buf
        H.ok(H.state().title:find('+ README.md:3', 1, true), 'the selection advertised: ' .. H.state().title)
        H.send('first question')
        H.ok(H.last_text():find('Selected in my editor', 1, true), 'the first send carries it')

        vim.cmd('stopinsert')
        H.feed('<C-o>')
        local s = H.state()
        H.eq(prompt_buf, s.buf, 'back in the same prompt')
        H.eq({ '' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'empty')
        H.ok(not s.title:find('README.md:3', 1, true), 'the frame no longer offers it: ' .. s.title)
        H.ok(s.title:find('Ctrl-s to send command', 1, true), 'the prompt\'s own frame: ' .. s.title)

        H.feed('<Up>')
        H.eq({ 'first question' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), '<Up> recalls what was sent')

        H.send('a follow-up')
        H.eq('a follow-up\r', H.last_text(), 'sent alone')
    end)
end

for _, win_type in ipairs({ 'float', 'split' }) do
    H.test(win_type .. ': before a send, <C-o> shows the terminal and comes back to the draft', function()
        H.reset(file)
        prompt({ win_type = win_type })
        local prompt_buf, win = H.state().buf, H.state().win
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'half written' })
        vim.cmd('stopinsert')
        H.feed('<C-o>')
        local s = H.state()
        H.ok(s.terminal, 'the terminal, not the file the prompt was opened from: '
            .. vim.api.nvim_buf_get_name(s.buf))
        H.eq(win, s.win, 'in the same window')
        H.ok(s.title:find('sh · foyer.nvim', 1, true), 'the frame names it: ' .. s.title)
        vim.cmd('stopinsert')
        H.feed('<C-o>')
        H.eq(prompt_buf, H.state().buf, 'back in the prompt')
        H.eq({ 'half written' }, vim.api.nvim_buf_get_lines(0, 0, -1, false), 'the draft kept')
        H.ok(H.state().title:find('Ctrl-s to send command', 1, true), 'its own frame: ' .. H.state().title)
    end)
end

-- A real main loop: the terminal's scroll to the bottom is a startinsert from
-- a timer, which only takes effect there.
H.test('<C-o> twice in a row leaves the prompt in Normal mode, where it was', function()
    local child = H.child([[
        local foyer = require('foyer')
        foyer.setup({ commands = { q = { 'sh', '-c "echo up; cat >/dev/null"' } } })
        foyer.is_idle = function() return true end
        vim.cmd('edit README.md')
        foyer.prompt({ key = 'q' })
    ]])
    -- Not <Esc>: on an empty draft that closes the prompt. Time for the
    -- terminal to come up instead.
    vim.wait(500)
    child.lua([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'half written' })
        vim.api.nvim_win_set_cursor(0, { 1, 5 })
        _G.prompt_buf = vim.api.nvim_get_current_buf()
        _G.inserted = false
        vim.api.nvim_create_autocmd('InsertEnter', {
            buffer = _G.prompt_buf,
            callback = function() _G.inserted = true end,
        })
    ]])
    -- Faster than the terminal's scroll to the bottom, which is deferred.
    child.type('<C-o>', 50)
    child.type('<C-o>', 800)
    local s = child.lua([[
        return {
            prompt = vim.api.nvim_get_current_buf() == _G.prompt_buf,
            inserted = _G.inserted,
            mode = vim.api.nvim_get_mode().mode,
            cursor = vim.api.nvim_win_get_cursor(0),
        }
    ]])
    child.stop()
    H.ok(s.prompt, 'back in the prompt')
    H.ok(not s.inserted, 'the terminal\'s scroll stayed out of the prompt')
    H.eq('n', s.mode, 'Normal mode')
    H.eq({ 1, 5 }, s.cursor, 'the cursor where it was')
end)

H.test('a terminal in two windows: <C-o> in each goes to that window\'s prompt', function()
    H.reset(file)
    prompt({ win_type = 'split' })
    local split_prompt, split = H.state().buf, H.state().win
    H.send('from the split')
    local term = H.state().buf
    H.ok(H.state().terminal, 'the terminal took the split')
    vim.cmd('stopinsert | wincmd p')
    prompt({ win_type = 'float' })
    local float_prompt, float = H.state().buf, H.state().win
    H.ok(float_prompt ~= split_prompt, 'a prompt of its own')
    H.send('from the float')
    H.eq(term, H.state().buf, 'the same terminal in the float')
    vim.cmd('stopinsert')
    vim.api.nvim_win_close(float, true)
    vim.api.nvim_set_current_win(split)
    H.feed('<C-o>')
    H.eq(split_prompt, H.state().buf, 'the split\'s prompt, not the float\'s')
end)

H.test('in a window of its own, a terminal\'s <C-o> is Vim\'s', function()
    H.reset(file)
    prompt()
    H.send('hello')
    local term = H.state().buf
    vim.cmd('stopinsert')
    H.reset(file)
    -- The file, then the terminal, in an ordinary window: <C-o> walks back.
    vim.cmd('normal! 5G')
    vim.cmd('buffer ' .. term)
    H.feed('<C-o>')
    H.eq(file, H.state().buf, 'back through the jump list')
    H.ok(not H.state().prompt, 'not into a prompt')
end)

H.test('history is saved even when the cache directory does not exist yet', function()
    H.reset(file)
    local cache = vim.fn.stdpath('cache')
    vim.fn.delete(cache, 'rf')
    prompt(); H.send('remember me')
    local saved = vim.fn.filereadable(cache .. '/foyer.json') == 1
        and table.concat(vim.fn.readfile(cache .. '/foyer.json'), '\n') or ''
    H.ok(saved:find('remember me', 1, true), 'written to ' .. cache .. '/foyer.json: ' .. saved)
end)

H.finish()
