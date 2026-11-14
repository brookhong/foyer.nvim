-- Marks on tab pages for what an agent there has said while the user was in
-- another: done, waiting for them, or failed. Kept by tab page and terminal,
-- shown as `vim.t.foyer_status` and tab_mark() for a tab line of the user's
-- own, or in foyer's, and cleared once the user enters the tab page.
local M = {}

-- Most urgent first: the one a tab page shows when it has more than one.
local ORDER = { 'error', 'blocked', 'done' }
local GLYPH = { done = '✓', blocked = '?', error = '✗' }

-- By tab page, then by terminal buffer: the state it reported.
local marks = {}
-- By terminal buffer: the tab page it was last used in, shown or prompted.
local last_tab = {}

local publish, redraw

-- Remember {term} was in use in the current tab page. In use, it has been
-- seen: its marks, wherever they are, are gone.
function M.remember(term)
    last_tab[term] = vim.api.nvim_get_current_tabpage()
    local cleared = false
    for tab, by_term in pairs(marks) do
        if by_term[term] then
            by_term[term] = nil
            publish(tab)
            cleared = true
        end
    end
    if cleared then redraw() end
end

-- The tab page {term} belongs to: one showing it, or a prompt for it, else
-- the one it was last used in; nil if that is the current one.
local function tab_of(term)
    local here = vim.api.nvim_get_current_tabpage()
    local found
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if buf == term or vim.b[buf].foyer_term == term then
                if tab == here then return nil end
                found = found or tab
            end
        end
    end
    found = found or last_tab[term]
    if found and vim.api.nvim_tabpage_is_valid(found) and found ~= here then return found end
end

-- The most urgent state marked on {tab}, or nil.
local function tab_state(tab)
    local by_term = marks[tab]
    if not by_term then return nil end
    for _, state in ipairs(ORDER) do
        for _, s in pairs(by_term) do
            if s == state then return state end
        end
    end
end

function publish(tab)
    if not vim.api.nvim_tabpage_is_valid(tab) then
        marks[tab] = nil
        return
    end
    local state = tab_state(tab)
    if state then
        vim.api.nvim_tabpage_set_var(tab, 'foyer_status', state)
    else
        marks[tab] = nil
        pcall(vim.api.nvim_tabpage_del_var, tab, 'foyer_status')
    end
end

function redraw()
    pcall(vim.cmd.redrawtabline)
end

-- {term} reported {state}: marked on its tab page if it is one worth a mark,
-- its mark anywhere else gone either way.
function M.set(term, state)
    for tab, by_term in pairs(marks) do
        if by_term[term] then
            by_term[term] = nil
            publish(tab)
        end
    end
    local tab = GLYPH[state] and tab_of(term)
    if tab then
        marks[tab] = marks[tab] or {}
        marks[tab][term] = state
        publish(tab)
    end
    redraw()
end

-- {term} is gone, and with it what it said.
function M.forget(term)
    M.set(term, nil)
    last_tab[term] = nil
end

-- The mark of tab page {tabnr}, as numbered in a tab line: '✓', '?', '✗', or
-- '' for none.
function M.tab_mark(tabnr)
    local tab = vim.api.nvim_list_tabpages()[tabnr]
    local state = tab and tab_state(tab)
    return state and GLYPH[state] or ''
end

-- A tab line like Neovim's own, with the marks: each tab page's window count
-- and `+` for a modified buffer, then the current window's file, and an X to
-- close with when there is more than one.
function M.render()
    local out = {}
    local tabs = vim.api.nvim_list_tabpages()
    local current = vim.api.nvim_get_current_tabpage()
    for i, tab in ipairs(tabs) do
        local hl = tab == current and '%#TabLineSel#' or '%#TabLine#'
        local count, modified = 0, false
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if vim.api.nvim_win_get_config(win).relative == '' then
                count = count + 1
                if vim.bo[vim.api.nvim_win_get_buf(win)].modified then modified = true end
            end
        end
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab)))
        name = name == '' and '[No Name]' or vim.fn.pathshorten(vim.fn.fnamemodify(name, ':~:.'))
        local label = ''
        local mark = M.tab_mark(i)
        if mark ~= '' then label = mark .. ' ' end
        if count > 1 or modified then
            label = label .. (count > 1 and tostring(count) or '') .. (modified and '+' or '') .. ' '
        end
        label = label .. name
        table.insert(out, ('%%%dT%s %s '):format(i, hl, (label:gsub('%%', '%%%%'))))
    end
    table.insert(out, '%#TabLineFill#%T')
    if #tabs > 1 then table.insert(out, '%=%#TabLine#%999XX') end
    return table.concat(out)
end

local TABLINE = "%!v:lua.require'foyer.tabline'.render()"

-- Use foyer's tab line if {on} and the user has none of their own; give it
-- up if not.
function M.apply(on)
    if on and vim.o.tabline == '' then
        vim.o.tabline = TABLINE
    elseif not on and vim.o.tabline == TABLINE then
        vim.o.tabline = ''
    end
end

local group = vim.api.nvim_create_augroup('foyer_tabline', { clear = true })
-- Entered, its marks have been seen.
vim.api.nvim_create_autocmd('TabEnter', {
    group = group,
    callback = function()
        local tab = vim.api.nvim_get_current_tabpage()
        if marks[tab] then
            marks[tab] = nil
            publish(tab)
            redraw()
        end
    end,
})
vim.api.nvim_create_autocmd('TabClosed', {
    group = group,
    callback = function()
        for tab in pairs(marks) do
            if not vim.api.nvim_tabpage_is_valid(tab) then marks[tab] = nil end
        end
    end,
})

return M
