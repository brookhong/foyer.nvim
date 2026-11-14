local H = dofile('tests/helpers.lua')

-- An agent per project and a global one, launched from a file in the first
-- tab page. Each test starts with one tab page showing LICENSE alone.
local child = H.child(([[
    local foyer = require('foyer')
    local quiet = { %q, %q }
    foyer.setup({ commands = {
        q = quiet,
        w = vim.deepcopy(quiet),
        f = vim.tbl_extend('force', quiet, { win_type = 'float' }),
        g = vim.tbl_extend('force', quiet, { scope = 'global' }),
    } })
    foyer.is_idle = function() return true end
    vim.cmd('edit LICENSE')
    _G.file = vim.api.nvim_get_current_buf()
    function _G.state()
        local buf = vim.api.nvim_get_current_buf()
        return {
            tab = vim.fn.tabpagenr(),
            win = vim.api.nvim_get_current_win(),
            buf = buf,
            terminal = vim.bo[buf].buftype == 'terminal',
            prompt = vim.b[buf].foyer_prompt == true,
            wins = #vim.api.nvim_tabpage_list_wins(0),
            tabs = vim.fn.tabpagenr('$'),
        }
    end
    -- The buffers shown in tab page {n}'s windows.
    function _G.tab_bufs(n)
        return vim.tbl_map(vim.api.nvim_win_get_buf,
            vim.api.nvim_tabpage_list_wins(vim.api.nvim_list_tabpages()[n]))
    end
    function _G.fresh()
        vim.cmd('stopinsert | silent! tabonly!')
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(win).relative ~= '' then vim.api.nvim_win_close(win, true) end
        end
        vim.cmd('silent! only!')
        vim.api.nvim_set_current_buf(_G.file)
    end
]]):format(H.quiet[1], H.quiet[2]))
vim.wait(300)

local function state() return child.lua('return _G.state()') end
local function tab_bufs(n) return child.lua('return _G.tab_bufs(...)', n) end

-- Launch {key} from where the child is, and wait for its prompt.
local function launch(key, win_type)
    child.lua('require("foyer").terminal_command({ key = ..., win_type = select(2, ...) }); vim.cmd("stopinsert")',
        key, win_type)
    vim.wait(500)
end

-- Send what the prompt holds, from Normal mode.
local function send()
    child.type('<CR>', 500)
end

H.test('launched in a second tab page, the agent\'s window moves there', function()
    child.lua('_G.fresh()')
    launch('q')
    local prompt = state().buf
    send()
    local one = state()
    H.ok(one.terminal, 'the terminal took the split in tab page 1')
    H.eq(2, one.wins, 'beside the file')

    child.lua('vim.cmd("tabnew LICENSE")')
    launch('q')
    local two = state()
    H.eq(2, two.tab, 'in tab page 2')
    H.eq(prompt, two.buf, 'the prompt from tab page 1')
    H.eq(2, two.wins, 'in a split beside the file')
    H.eq({ child.lua('return _G.file') }, tab_bufs(1), 'tab page 1 has its file alone')

    -- The user's steps: send, put the terminal away here, and back in tab
    -- page 1 the agent is launched again.
    send()
    H.ok(state().terminal, 'the terminal in tab page 2')
    child.type('<CR>', 300)
    H.eq(1, state().wins, 'put away in tab page 2')
    child.lua('vim.cmd("tabprevious")')
    launch('q')
    send()
    local back = state()
    H.eq(1, back.tab, 'in tab page 1')
    H.ok(back.terminal, 'the terminal in tab page 1')
    child.type('<CR>', 300)
    H.eq(1, state().wins, 'put away in tab page 1')
end)

H.test('a draft moves with its prompt', function()
    child.lua('_G.fresh()')
    launch('q')
    child.lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { "half written" })')
    local prompt = state().buf
    child.lua('vim.cmd("tabnew LICENSE")')
    launch('q')
    H.eq(prompt, state().buf, 'the same prompt')
    H.eq({ 'half written' }, child.lines(), 'its draft')
    child.type('<C-c>', 300)
    H.eq(1, state().wins, 'its keys put away the window it is in now')
    H.eq({ child.lua('return _G.file') }, tab_bufs(1), 'tab page 1 untouched')
end)

H.test('a selection goes from the tab page it was made in', function()
    child.lua('_G.fresh()')
    launch('q')
    child.lua('vim.cmd("tabnew README.md")')
    child.type('ggVj', 100)
    child.lua('require("foyer").terminal_command({ key = "q" }); vim.cmd("stopinsert")')
    vim.wait(500)
    local s = child.lua('return { title = vim.b.foyer_title, selection = vim.b.foyer_selection }')
    H.ok(s.title and s.title:find('README.md:1-2', 1, true), 'the title names it: ' .. tostring(s.title))
    H.ok(s.selection and s.selection:find('README.md', 1, true), 'it rides along')
end)

H.test('the last window of its tab page is left there, empty', function()
    child.lua('_G.fresh()')
    launch('q')
    send()
    child.lua('vim.cmd("only")')
    child.lua('vim.cmd("tabnew LICENSE")')
    launch('q')
    H.eq(2, state().tabs, 'both tab pages still there')
    H.ok(state().prompt, 'the prompt in tab page 2')
    local left = tab_bufs(1)
    H.eq(1, #left, 'one window in tab page 1')
    H.ok(child.lua('return vim.bo[...].buftype == "" and vim.api.nvim_buf_get_name(...) == ""', left[1]),
        'showing an empty buffer')
end)

H.test('a global agent\'s prompt gives the borrowed window its file back', function()
    child.lua('_G.fresh()')
    launch('g')
    H.ok(state().prompt, 'the prompt took the window')
    child.lua('vim.cmd("tabnew README.md")')
    launch('g')
    H.ok(state().prompt, 'the prompt in tab page 2')
    H.eq(1, state().wins, 'in the window there')
    H.eq({ child.lua('return _G.file') }, tab_bufs(1), 'tab page 1 has its file back')
end)

-- The terminal is one buffer, and its keys were set for the window it was
-- last shown in by foyer: pressed anywhere else, they acted on that one.
H.test('in a window of the user\'s, a terminal\'s <CR> is Vim\'s', function()
    child.lua('_G.fresh()')
    launch('q')
    send()
    local term = state().buf
    child.lua('vim.cmd("tab sbuffer " .. ...)', term)
    child.type('<CR>', 300)
    local s = state()
    H.eq(2, s.tab, 'still in tab page 2')
    H.eq(term, s.buf, 'still showing the terminal')
    H.eq(2, #tab_bufs(1), 'tab page 1\'s window left alone')
end)

H.test('a float moves as a split does', function()
    child.lua('_G.fresh()')
    launch('f')
    local prompt = state().buf
    H.eq(2, state().wins, 'the float beside the file')
    child.lua('vim.cmd("tabnew LICENSE")')
    launch('f')
    local s = state()
    H.eq(prompt, s.buf, 'the same prompt')
    H.ok(child.lua('return vim.api.nvim_win_get_config(0).relative ~= ""'), 'in a float')
    H.eq({ child.lua('return _G.file') }, tab_bufs(1), 'tab page 1 has its file alone')
end)

H.test('<C-t> to a terminal shown in another tab page moves it here', function()
    child.lua('_G.fresh()')
    launch('q')
    send()
    local q = state().buf
    child.lua('vim.cmd("tabnew LICENSE")')
    launch('w')
    send()
    local win = state().win
    child.type('<C-t>', 500)
    local s = state()
    H.eq(win, s.win, 'the same window')
    H.eq(q, s.buf, 'showing q')
    H.eq({ child.lua('return _G.file') }, tab_bufs(1), 'tab page 1 has its file alone')
end)

H.test('the drafts parked in a window move with it', function()
    child.lua('_G.fresh()')
    launch('q')
    child.lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { "for q" })')
    -- w takes the split, and q's draft is parked in it.
    launch('w')
    child.lua('vim.cmd("tabnew LICENSE")')
    launch('w')
    H.eq(2, state().tab, 'w moved to tab page 2')
    vim.wait(300)
    launch('q')
    H.eq({ 'for q' }, child.lines(), 'q\'s draft, back in the window it moved to')
end)

-- The same terminal in a split and a float of one tab page, each with its
-- own prompt: its keys were set for the window shown in last.
H.test('a terminal in a split and a float: <CR> puts away the window it is pressed in', function()
    child.lua('_G.fresh()')
    launch('q', 'split')
    send()
    local split = state().win
    child.lua('vim.cmd("wincmd p")')
    launch('q', 'float')
    send()
    local float = state().win
    H.ok(state().terminal, 'the terminal in the float')
    child.lua('vim.api.nvim_set_current_win(...)', split)
    child.type('<CR>', 300)
    H.ok(not child.lua('return vim.api.nvim_win_is_valid(...)', split), 'the split put away')
    H.ok(child.lua('return vim.api.nvim_win_is_valid(...)', float), 'the float left alone')
end)

child.stop()
H.finish()
