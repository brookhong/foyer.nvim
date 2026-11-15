-- The user's settings, shared by every module. setup() merges into this one
-- table, so a module may hold on to it from the moment it is required.
local M = {}

-- The keys foyer maps in its own buffers, per action. Each action is a key or
-- a list of keys, put in the modes it has by default here, or a table of keys
-- by mode -- `{ n = '<CR>', i = '<C-s>' }` -- naming the modes itself. false
-- maps nothing.
local default_keys = {
    -- In a terminal's prompt; send, close and close_if_empty in
    -- edit_selection()'s window too.
    prompt = {
        send = { n = '<CR>', i = '<C-s>' },
        close = { n = '<C-c>' },
        close_if_empty = { n = '<Esc>' },
        terminal = { n = '<C-o>' },
        -- In Insert mode <C-p> and <C-n> are completion's; <Up> and <Down>
        -- walk history from the first line and the last.
        history_prev = { n = { '<Up>', '<C-p>' }, i = '<Up>' },
        history_next = { n = { '<Down>', '<C-n>' }, i = '<Down>' },
        history_pick = { n = '<C-f>', i = '<C-f>' },
    },
    -- In a terminal foyer started.
    terminal = {
        switch = { n = '<C-t>' },
        prompt = { n = '<C-o>' },
        close = { n = { '<CR>', '<C-c>', '<Esc>' } },
        cd_root = { n = '<C-r>' },
    },
}

local config = {
    commands = {}, root_markers = nil, bracketed_paste = true,
    picker_delay = 500, selection_max_lines = 40, mention = true, notify = true, tabline = false,
    quit_guard = true, normal_on_submit = true,
    -- foyer.jump(): the keys its hint labels are made of, the 'winblend' of
    -- the backdrop dimming the editor behind it (false: none), and what a key
    -- that is no label opens (nil: Telescope's oldfiles, or vim.ui.select).
    jump = { characters = 'asdfgqwertzxcvb', backdrop = 60, fallback = nil },
    keys = vim.deepcopy(default_keys),
    -- Prompts of the user's own, by `commands` key, listed first in that
    -- terminal's <C-f> picker, in the order given.
    prompts = {},
}

-- Directory markers locating the project root that scopes terminals.
-- {buf} is the buffer to look from, the current one by default.
local function project_root(fallback, buf)
    local markers = config.root_markers or vim.g.root_markers or { '.git' }
    return vim.fs.root(buf or 0, markers) or fallback
end

-- The keys {group}.{action} maps, by mode: `{ n = { '<CR>' }, i = { ... } }`,
-- empty for none.
local function keys(group, action)
    local spec = config.keys[group] and config.keys[group][action]
    local default = default_keys[group][action]
    local function list(v)
        if not v then return {} end
        return type(v) == 'table' and v or { v }
    end
    local out = {}
    if not spec then return out end
    if type(spec) == 'string' or vim.islist(spec) then
        -- Keys alone go in the modes the action has by default.
        for mode in pairs(default) do out[mode] = list(spec) end
    else
        for mode, v in pairs(spec) do out[mode] = list(v) end
    end
    return out
end

-- Map {group}.{action} in buffer {buf}. {rhs} is the function every key
-- runs, or, with {opts.build}, a function given the mode and the key that
-- returns the one that key runs there -- for an action that hands its own key
-- back, to a completion menu, say.
local function map(buf, group, action, rhs, opts)
    opts = opts or {}
    for mode, lhss in pairs(keys(group, action)) do
        for _, lhs in ipairs(lhss) do
            local fn = opts.build and rhs(mode, lhs) or rhs
            vim.keymap.set(mode, lhs, fn, { silent = true, buffer = buf, desc = opts.desc })
        end
    end
end

-- Whether {spec} is a key action's value: a key, a list of keys, a table of
-- either by mode, or false.
local function valid_spec(spec)
    local function keys_or_none(v)
        if v == false or type(v) == 'string' then return true end
        if type(v) ~= 'table' or not vim.islist(v) then return false end
        for _, k in ipairs(v) do
            if type(k) ~= 'string' then return false end
        end
        return true
    end
    if keys_or_none(spec) then return true end
    if type(spec) ~= 'table' then return false end
    for mode, v in pairs(spec) do
        if type(mode) ~= 'string' or not keys_or_none(v) then return false end
    end
    return true
end

local function setup(opts)
    opts = vim.deepcopy(opts or {})
    local user_keys = opts.keys or {}
    local user_prompts = opts.prompts
    opts.keys, opts.prompts = nil, nil

    -- Merged into the table itself rather than replacing it, so whatever holds
    -- a reference to `config` sees what the user set, whenever it looked.
    local merged = vim.tbl_deep_extend('force', config, opts)
    for k, v in pairs(merged) do
        config[k] = v
    end
    -- An action at a time, not merged deeply: a list of keys given replaces
    -- the default's rather than overwriting it entry by entry. What makes no
    -- sense is said so and left out, here rather than when a buffer maps it.
    local function warn(what) vim.notify('foyer.nvim: ' .. what, vim.log.levels.WARN) end
    if type(user_keys) ~= 'table' then
        warn('keys must be a table of groups, prompt and terminal')
        user_keys = {}
    end
    for group, actions in pairs(user_keys) do
        if not default_keys[group] then
            warn(('no key group keys.%s: there are prompt and terminal'):format(group))
        elseif type(actions) ~= 'table' then
            warn(('keys.%s must be a table of actions'):format(group))
        else
            for action, spec in pairs(actions) do
                if default_keys[group][action] == nil then
                    warn(('no key action keys.%s.%s'):format(group, action))
                elseif not valid_spec(spec) then
                    warn(('keys.%s.%s must be a key, a list of keys, a table of them by mode, or false')
                        :format(group, action))
                else
                    config.keys[group][action] = spec
                end
            end
        end
    end

    -- A terminal's at a time, for the same reason: a list given replaces the
    -- one before rather than being merged into it entry by entry.
    if user_prompts ~= nil then
        if type(user_prompts) ~= 'table' or vim.islist(user_prompts) and #user_prompts > 0 then
            warn('prompts must be a table of lists of prompts, by `commands` key')
        else
            for key, list in pairs(user_prompts) do
                local ok = type(list) == 'table' and vim.islist(list)
                for _, text in ipairs(ok and list or {}) do
                    if type(text) ~= 'string' or not text:find('%S') then ok = false end
                end
                if not ok then
                    warn(('prompts.%s must be a list of prompts, each a string with something in it')
                        :format(tostring(key)))
                else
                    if config.commands[key] == nil then
                        warn(('prompts.%s: no terminal in `commands` has that key'):format(tostring(key)))
                    end
                    config.prompts[key] = list
                end
            end
        end
    end
end

M.options = config
M.project_root = project_root
M.keys = keys
M.map = map
M.setup = setup

return M
