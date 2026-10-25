-- The user's settings, shared by every module. setup() merges into this one
-- table, so a module may hold on to it from the moment it is required.
local M = {}

local config = {
    commands = {}, root_markers = nil, bracketed_paste = true, send_prefix = {},
    picker_delay = 500, selection_max_lines = 40, mention = true,
}

-- Directory markers locating the project root that scopes terminals.
-- {buf} is the buffer to look from, the current one by default.
local function project_root(fallback, buf)
    local markers = config.root_markers or vim.g.root_markers or { '.git' }
    return vim.fs.root(buf or 0, markers) or fallback
end

local function setup(opts)
    -- Merged into the table itself rather than replacing it, so whatever holds
    -- a reference to `config` sees what the user set, whenever it looked.
    local merged = vim.tbl_deep_extend('force', config, opts or {})
    for k, v in pairs(merged) do
        config[k] = v
    end
end

M.options = config
M.project_root = project_root
M.setup = setup

return M
