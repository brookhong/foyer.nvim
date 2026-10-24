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
-- {opts.term} is the terminal the window is for, which a sidebar is kept per;
-- {opts.float} overrides the config a float is opened with.
local function create_window(type, title, on_ready, opts)
    opts = opts or {}
    local term = opts.term
    -- A sidebar is a persistent split, so reopening it would stack another one;
    -- a float is transient and may simply be opened again.
    local reuse = type == "sidebar" and term and active_cmd_wins[term] or nil
    if reuse and not vim.api.nvim_win_is_valid(reuse) then reuse = nil end

    if reuse and vim.bo[vim.api.nvim_win_get_buf(reuse)].buftype ~= 'terminal' then
        vim.api.nvim_set_current_win(reuse)
        if on_ready then
            on_ready(vim.api.nvim_win_get_buf(reuse), reuse, true)
        end
        return
    end

    local bufnr = new_cmd_buf()
    local win_id

    if reuse then
        -- The last send left the terminal in this window, and a prompt is what
        -- was asked for, so put a fresh one in front of it.
        win_id = reuse
        vim.api.nvim_set_current_win(win_id)
        vim.api.nvim_win_set_buf(win_id, bufnr)
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

    -- Only a sidebar is tracked: it is the one that gets reused, and a float
    -- left open must not be mistaken for it.
    if not reuse and type == "sidebar" and term ~= nil then
        active_cmd_wins[term] = win_id
        vim.api.nvim_create_autocmd('WinClosed', {
            pattern = tostring(win_id),
            once = true,
            callback = function() active_cmd_wins[term] = nil end,
        })
    end
end

M.clear_foyer_matches = clear_foyer_matches
M.dismiss = dismiss
M.set_window_title = set_window_title
M.insert_at_end = insert_at_end
M.create_window = create_window

return M
