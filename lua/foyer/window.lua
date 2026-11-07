-- The windows foyer shows its prompts and terminals in: opening one (a float,
-- a sidebar kept per terminal, or the user's own window borrowed), naming it,
-- and putting it away again without leaving anything of foyer's behind.
local M = {}

-- Remove the history filter's highlight from {win_id}, and only that: the
-- window may be the user's own, with matches of its own in it.
local function clear_foyer_matches(win_id)
    win_id = win_id or vim.api.nvim_get_current_win()
    for _, m in ipairs(vim.fn.getmatches(win_id)) do
        if m.group == 'FoyerMatch' then
            vim.fn.matchdelete(m.id, win_id)
        end
    end
end

-- Put away a window this plugin opened, then drop {bufnr} if given. A float
-- or a sidebar is the plugin's own and simply closes; a window the plugin only
-- borrowed -- the user's, with a prompt put in it -- is handed back the buffer
-- it was showing, since closing it would take the user's layout with it.
local function dismiss(win_id, bufnr)
    if vim.api.nvim_win_is_valid(win_id) then
        local back = vim.w[win_id].foyer_return_buf
        if back == nil then
            -- Nothing to hand back. Close it if it is ours to close; a window
            -- of the user's is left alone -- the terminal's mappings outlive
            -- the borrowing, and may be pressed after the user got there some
            -- other way.
            if vim.w[win_id].foyer_own then
                vim.api.nvim_win_close(win_id, true)
            end
        else
            vim.w[win_id].foyer_return_buf = nil
            clear_foyer_matches(win_id)
            if vim.api.nvim_buf_is_valid(back) and back ~= bufnr then
                vim.api.nvim_win_set_buf(win_id, back)
            else
                vim.api.nvim_win_call(win_id, function() vim.cmd('enew') end)
            end
        end
    end
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        -- Wiping a buffer closes the windows showing it, and a window left
        -- showing it here is the user's: give it something else first.
        for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
            vim.api.nvim_win_call(win, function()
                local alt = vim.fn.bufnr('#')
                if alt > 0 and alt ~= bufnr and vim.api.nvim_buf_is_valid(alt) then
                    vim.api.nvim_win_set_buf(win, alt)
                else
                    vim.cmd('enew')
                end
            end)
        end
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
end

-- The frame names what the window is showing: a float wears it on its border,
-- a split in its winbar. A float's title has to be set with its position --
-- nvim_win_get_config() reports no position while there is no title.
local function set_window_title(win_id, title)
    local cfg = vim.api.nvim_win_get_config(win_id)
    if cfg.relative ~= '' then
        cfg.title = ' ' .. title .. ' '
        cfg.title_pos = 'center'
        vim.api.nvim_win_set_config(win_id, cfg)
    else
        -- For the buffer in it, not the window: a borrowed window gets its
        -- own buffer back without the frame of what was shown in it.
        vim.wo[win_id][0].winbar = ' ' .. title .. ' '
    end
end

-- Pick up where the user left off: the end of the last line, with startinsert!
-- supplying the column.
local function insert_at_end(bufnr, win_id)
    vim.api.nvim_win_set_cursor(win_id, { vim.api.nvim_buf_line_count(bufnr), 0 })
    vim.cmd('startinsert!')
end

local active_cmd_wins = {}

-- What kind of window a {type} opens: anything but a sidebar or the current
-- window is a float.
local function window_kind(type)
    if type == 'sidebar' or type == 'current' then return type end
    return 'float'
end

-- The prompt {win_id} belongs to: the one shown, or the one its terminal's
-- <C-o> goes back to.
local function window_prompt(win_id)
    local shown = vim.api.nvim_win_get_buf(win_id)
    if vim.b[shown].foyer_prompt then return shown end
    return vim.w[win_id].foyer_prompt
end

-- The terminal {win_id} is for, read from what it shows rather than kept on
-- the window, which a prompt borrowing it -- a global terminal's -- would
-- leave out of date: a prompt's own terminal, or the terminal itself.
local function window_term(win_id)
    local shown = vim.api.nvim_win_get_buf(win_id)
    if vim.b[shown].foyer_prompt then return vim.b[shown].foyer_term end
    if vim.bo[shown].buftype == 'terminal' then return shown end
end

-- Prompts set aside in a window when another terminal took it, by window and
-- then by terminal buffer: the draft in one is the user's, and comes back
-- when its terminal is launched in that window again.
local parked = {}

local function park_prompt(win_id, prompt)
    if not (prompt and vim.api.nvim_buf_is_valid(prompt)) then return end
    local term = vim.b[prompt].foyer_term
    if not term then return end
    parked[win_id] = parked[win_id] or {}
    parked[win_id][term] = prompt
end

-- The prompt parked in {win_id} for {term}, taken out of the parking: only
-- one still there and shown nowhere else.
local function unpark_prompt(win_id, term)
    local prompt = parked[win_id] and parked[win_id][term]
    if not prompt then return nil end
    parked[win_id][term] = nil
    if vim.api.nvim_buf_is_valid(prompt) and #vim.fn.win_findbuf(prompt) == 0 then
        return prompt
    end
end

-- The window has gone, and with it the place its parked prompts come back to.
-- Wipe the ones no other window shows.
local function drop_parked(win_id)
    for _, prompt in pairs(parked[win_id] or {}) do
        if vim.api.nvim_buf_is_valid(prompt) and #vim.fn.win_findbuf(prompt) == 0 then
            vim.api.nvim_buf_delete(prompt, { force = true })
        end
    end
    parked[win_id] = nil
end

-- A scratch buffer that inherits the source buffer's indent settings, so text
-- edited here keeps the shape it had over there.
local function new_cmd_buf()
    local src = vim.api.nvim_get_current_buf()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].modifiable = true
    vim.b[bufnr].foyer_prompt = true
    for _, opt in ipairs({ 'expandtab', 'tabstop', 'shiftwidth', 'softtabstop' }) do
        vim.bo[bufnr][opt] = vim.bo[src][opt]
    end
    return bufnr
end

-- {on_ready} is called with reused = true when the window already held a
-- command buffer, so a caller can re-point that draft at what this send
-- carries instead of silently handing back the state of the send before it.
--
-- {opts.term} is the terminal the window is for. A sidebar or a float of
-- foyer's already open in this tab page is reused rather than stacked: for the
-- same terminal, a prompt in it is handed back as it is; for another one, the
-- old prompt is parked, draft and all, and the window given to the new
-- terminal's own prompt -- the one parked there for it before, or a fresh one.
-- {opts.float} overrides the config a float is opened with.
local function create_window(type, title, on_ready, opts)
    opts = opts or {}
    local term = opts.term
    local kind = window_kind(type)
    local tracked = term ~= nil and kind ~= 'current'
    local reuse = tracked and active_cmd_wins[kind] or nil
    if reuse and not vim.api.nvim_win_is_valid(reuse) then reuse = nil end
    -- Only in this tab page: one elsewhere is left where it is.
    if reuse and vim.api.nvim_win_get_tabpage(reuse) ~= vim.api.nvim_get_current_tabpage() then
        reuse = nil
    end
    -- Still foyer's only while it shows a prompt or a terminal of ours. A
    -- file the user opened in it, or kept it for with :only, makes it theirs:
    -- treating that file as the prompt would hang a prompt's mappings on it.
    if reuse then
        local shown = vim.api.nvim_win_get_buf(reuse)
        if not (vim.b[shown].foyer_prompt or vim.bo[shown].buftype == 'terminal') then
            active_cmd_wins[kind] = nil
            reuse = nil
        end
    end

    local same = reuse and window_term(reuse) == term

    -- The prompt to hand back as it is, draft and all, if there is one.
    local back
    if same then
        local shown = vim.api.nvim_win_get_buf(reuse)
        if vim.bo[shown].buftype ~= 'terminal' then
            back = shown
        else
            -- The terminal, left by a send or looked at with <C-o>: its
            -- prompt is behind it, empty after a send, a draft before one.
            local prompt = vim.w[reuse].foyer_prompt
            if prompt and vim.api.nvim_buf_is_valid(prompt) and vim.b[prompt].foyer_term == term
                and #vim.fn.win_findbuf(prompt) == 0 then
                back = prompt
            end
        end
    elseif reuse then
        -- Another terminal's window: park its prompt, and bring back this
        -- terminal's, if one was parked here.
        park_prompt(reuse, window_prompt(reuse))
        -- A global terminal's prompt borrowed this window from under the
        -- prompt it showed, and saved that to hand back. The window is ours,
        -- and nothing in it is the user's to hand back: park that one too.
        local saved = vim.w[reuse].foyer_return_buf
        if saved and vim.w[reuse].foyer_own then
            vim.w[reuse].foyer_return_buf = nil
            if vim.api.nvim_buf_is_valid(saved) and vim.b[saved].foyer_prompt then
                park_prompt(reuse, saved)
            end
        end
        back = unpark_prompt(reuse, term)
    end

    if back then
        vim.api.nvim_set_current_win(reuse)
        if vim.api.nvim_win_get_buf(reuse) ~= back then
            vim.api.nvim_win_set_buf(reuse, back)
        end
        vim.w[reuse].foyer_prompt = nil
        if on_ready then on_ready(back, reuse, true) end
        return
    end

    local bufnr = new_cmd_buf()
    local win_id

    if reuse then
        -- A terminal left in this window by the last send, or another
        -- terminal's prompt or terminal: put a fresh prompt in front of it.
        win_id = reuse
        vim.api.nvim_set_current_win(win_id)
        vim.api.nvim_win_set_buf(win_id, bufnr)
        -- The old prompt is parked or gone; <C-o> here is the new one's.
        vim.w[win_id].foyer_prompt = nil
    elseif type == "sidebar" then
        win_id = vim.api.nvim_open_win(bufnr, true, {
            split = 'right',
        })
    elseif type == "current" then
        -- Borrow the window in front of the user. What it showed is what it
        -- goes back to -- unless that is a prompt or a terminal of ours, left
        -- there by the last send, when the buffer from before that still is.
        win_id = vim.api.nvim_get_current_win()
        local shown = vim.api.nvim_win_get_buf(win_id)
        local ours = vim.b[shown].foyer_prompt or vim.bo[shown].buftype == 'terminal'
        if not ours or vim.w[win_id].foyer_return_buf == nil then
            vim.w[win_id].foyer_return_buf = shown
        end
        vim.api.nvim_win_set_buf(win_id, bufnr)
    else
        local width = vim.o.columns - 32
        local col = math.floor((vim.o.columns - width) / 2)
        local row = 1

        local float = vim.tbl_deep_extend('force', {
            relative = 'editor',
            width = width,
            height = 10,
            col = col,
            row = row,
            border = 'rounded',
            footer = { { " Press <Ctrl-c> or <Esc> to close this window ", "FloatFooter" } },
            footer_pos = "right",
        }, opts.float or {})

        win_id = vim.api.nvim_open_win(bufnr, true, float)
    end

    -- Ours to close, unless it was borrowed: dismiss() closes only these.
    if type ~= "current" and not reuse then vim.w[win_id].foyer_own = true end
    set_window_title(win_id, title)
    vim.wo[win_id][0].relativenumber = true
    vim.wo[win_id][0].cursorline = true

    if on_ready then
        on_ready(bufnr, win_id)
    end

    -- Only a sidebar and a float for a terminal are tracked: they are the ones
    -- that get reused. edit_selection()'s float is for no terminal, and left
    -- alone.
    if not reuse and tracked then
        active_cmd_wins[kind] = win_id
        vim.api.nvim_create_autocmd('WinClosed', {
            pattern = tostring(win_id),
            once = true,
            -- Only while it is still tracked: one the user took over has
            -- been replaced, and closing it must not forget its successor.
            callback = function()
                if active_cmd_wins[kind] == win_id then active_cmd_wins[kind] = nil end
                -- Not while the window is being closed: wiping a buffer it
                -- still shows would try to close it again.
                vim.schedule(function() drop_parked(win_id) end)
            end,
        })
    end
end

M.clear_foyer_matches = clear_foyer_matches
M.dismiss = dismiss
M.set_window_title = set_window_title
M.insert_at_end = insert_at_end
M.create_window = create_window

return M
