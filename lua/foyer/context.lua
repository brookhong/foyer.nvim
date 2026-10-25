-- What the user is looking at, and what is sent about it: the launch_info
-- captured for a send, the selection block an agent reads, and the context
-- files published for the terminals.
local options = require('foyer.config')
local config = options.options
local project_root = options.project_root

local M = {}

local context_dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'foyer')
local published = {}

local function in_visual()
    local mode = vim.fn.mode()
    return mode == 'v' or mode == 'V' or mode == '\22' -- char, line, block
end

-- {path} stated the way the project talks about it, or nil when it does not sit
-- under {root} -- then no such name exists and only the absolute one is true.
local function relative_to(root, path)
    local prefix = root:gsub('/$', '') .. '/'
    local head = path:sub(1, #prefix)
    -- A Windows path can differ in case without differing: the buffer name and
    -- vim.fs.root() disagree about the drive letter often enough to matter.
    if jit.os == 'Windows' then
        head, prefix = head:lower(), prefix:lower()
    end
    if head ~= prefix then return nil end
    return path:sub(#prefix + 1)
end

-- The file {buf} holds, named the way launch_info names it: `current_file`
-- relative to `project_root`, or absolute with no `project_root`. Nil for a
-- buffer with no file worth reporting.
local function file_info(buf)
    -- A terminal or scratch buffer has no file worth reporting: its name would
    -- be a term:// URI.
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype ~= '' or name == '' then return nil end
    -- The buffer name rather than expand('%:p'): that one leaves a symlinked
    -- path unresolved while vim.fs.root() resolves it, so the two would never
    -- match. normalize() then settles the separators, which disagree on
    -- Windows.
    local path = vim.fs.normalize(name)
    local root = project_root(nil, buf)
    root = root and vim.fs.normalize(root)
    local relative = root and relative_to(root, path)
    return {
        -- The pair travels together or not at all: a root the file cannot be
        -- named against is a root nobody can resolve the name with.
        project_root = relative and root or nil,
        current_file = relative or path,
    }
end

-- What the user is looking at, in the conventional launch_info shape.
local function launch_info()
    -- The empty table publishes nothing, so the last real context stays in
    -- place.
    local info = file_info(0)
    if not info then return {} end
    info.current_line = vim.fn.line('.')
    if in_visual() then
        -- line('v') is the anchor, which sits below the cursor in a selection
        -- dragged upward; a reversed range is no use to whoever reads it.
        local anchor, cursor = vim.fn.line('v'), vim.fn.line('.')
        info.start_line = math.min(anchor, cursor)
        info.end_line = math.max(anchor, cursor)
    end
    return info
end

-- Lines {first}..{last} of {buf}, ready for selection_block(): as the buffer
-- has them now, unsaved edits and all, since that is what the user is pointing
-- at, whatever the disk says. Nil for a buffer with no file.
local function buffer_selection(buf, first, last)
    local info = file_info(buf)
    if not info then return nil end
    info.start_line, info.end_line = first, last
    return {
        info = info,
        lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false),
        -- A buffer loaded without autocommands has no 'filetype' set: ask
        -- what it would be, rather than set it and start its plugins.
        filetype = vim.bo[buf].filetype ~= '' and vim.bo[buf].filetype
            or vim.filetype.match({ buf = buf }) or '',
        modified = vim.bo[buf].modified,
    }
end

-- The selected range in the project's own terms, `src/main.c:30-36`: short
-- enough for a window title, which is where the user reads it.
local function selection_ref(info)
    if not (info.current_file and info.start_line) then return nil end
    if info.end_line == info.start_line then
        return ('%s:%d'):format(info.current_file, info.start_line)
    end
    return ('%s:%d-%d'):format(info.current_file, info.start_line, info.end_line)
end

-- The selection as an agent is to read it: said in words, from a path that
-- resolves wherever the agent was started, with the lines themselves below.
--
-- A bare `path:30` reads as a location -- a compiler error, a grep hit -- and
-- an agent reads a window of lines around one, then has to guess which of them
-- was meant. And the numbers are the buffer's, while the agent reads the file
-- on disk: unsaved edits above the selection point it at other lines
-- altogether. The text settles both. Past `selection_max_lines` it is left
-- out, so a selection the size of a file is not pasted whole; the label alone
-- still says where to look.
local function selection_block(sel)
    local info = sel.info
    local file = info.current_file
    if info.project_root then file = vim.fs.joinpath(info.project_root, file) end
    local where = info.end_line == info.start_line
        and ('line %d'):format(info.start_line)
        or ('lines %d-%d'):format(info.start_line, info.end_line)
    local label = ('Selected in my editor: %s, %s'):format(file, where)
    -- Said outright, so an agent that does open the file is not misled by it.
    if sel.modified then label = label .. ' (unsaved; the file on disk differs)' end

    local max = config.selection_max_lines or 0
    if max <= 0 or #sel.lines > max then return label end
    local text = table.concat(sel.lines, '\n')
    -- A fence longer than any run of backticks in the text, so code that
    -- holds a fence of its own cannot close this one early.
    local fence = '```'
    while text:find(fence, 1, true) do fence = fence .. '`' end
    return ('%s\n%s%s\n%s\n%s'):format(label, fence, sel.filetype or '', text, fence)
end

local function escape_key(s)
    return (tostring(s):gsub('[^%w%-_]', function(c) return ('%%%02x'):format(c:byte()) end))
end

-- Keyed by the terminal's identity, so the same terminal reopened reuses its
-- file. The pid separates two Neovim instances.
local function context_path(key)
    return vim.fs.joinpath(context_dir, ('%d-%s.json'):format(vim.fn.getpid(), key))
end

-- The root is hashed rather than flattened: a deep path would otherwise make a
-- filename longer than the filesystem allows. A global terminal has no root to
-- hash, so its empty bucket gives it one file for the session.
local function term_context_path(root, term_key)
    return context_path(('t-%s-%s'):format(vim.fn.sha256(root):sub(1, 8), escape_key(term_key)))
end

-- Write a terminal's context. An empty info means "keep the context this
-- terminal already has". Publishing is a side channel, so it may not take the
-- send down: info is the caller's table and vim.json.encode can refuse it.
local function publish(path, info)
    info = info or launch_info()
    if type(info) ~= 'table' or vim.tbl_isempty(info) then return path end
    local ok, err = pcall(function()
        vim.fn.mkdir(context_dir, 'p')
        local json = vim.json.encode({
            captured_at = os.date('%Y-%m-%dT%H:%M:%S%z'),
            captured_unix = os.time(),
            launch_info = info,
        })
        assert(vim.fn.writefile({ json }, path) == 0, 'could not write ' .. path)
    end)
    if ok then
        published[path] = true
    else
        -- The traceback prefix is noise to whoever set launch_info.
        local reason = tostring(err):gsub('^.-:%d+: ', '')
        vim.notify('foyer.nvim: could not publish context: ' .. reason, vim.log.levels.WARN)
    end
    return path
end

-- Name the context file in the environment of a terminal about to be spawned.
-- A job reads its environment once, at startup, so only the spawning paths may
-- set this; cleared on the next tick so it cannot leak to unrelated jobs.
local function export_context(path)
    vim.env.FOYER_CONTEXT = path
    vim.schedule(function() vim.env.FOYER_CONTEXT = nil end)
end

vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('foyer_context', { clear = true }),
    callback = function()
        -- These describe a live editing session; leaving them behind would let
        -- an agent read a cursor position from a Neovim that no longer exists.
        for path in pairs(published) do
            os.remove(path)
        end
    end,
})

-- The opts whose selection capture() wrote, rather than the caller: only
-- those may be renamed for the terminal they end up going to.
local captured_selection = setmetatable({}, { __mode = 'k' })

-- {text} with every selection block taken out: the label line, and the fence
-- below it when there is one. For history, which keeps what the user wrote
-- rather than code that will not be true next time. Blank lines a block
-- leaves behind are folded, and the ends trimmed.
local function strip_selections(text)
    local out, fence = {}, nil
    local lines = vim.split(text, '\n', { plain = true })
    local i = 1
    while i <= #lines do
        local line = lines[i]
        if fence then
            if line == fence then fence = nil end
        elseif line:find('^Selected in my editor: ') then
            fence = (lines[i + 1] or ''):match('^(```+)')
            if fence then i = i + 1 end
        elseif not (line == '' and out[#out] == '') then
            table.insert(out, line)
        end
        i = i + 1
    end
    return vim.trim(table.concat(out, '\n'))
end

-- What a send appends below the prompt: the captured selection with its text,
-- or a `selection` the caller gave, which is theirs and goes as given.
local function selection_appendix(opts)
    local sel = captured_selection[opts]
    if sel then return selection_block(sel) end
    return opts.selection
end

local function capture(opts)
    if opts.launch_info ~= nil then return end
    opts.launch_info = launch_info()
    if not in_visual() then return end
    -- A ref is only useful on a prompt that is going to open; a send that asked
    -- for no window has nowhere to put it.
    if opts.interactive or opts.command == nil or opts.command == '' then
        if opts.selection == nil then
            opts.selection = selection_ref(opts.launch_info)
            if opts.selection then
                local info = opts.launch_info
                captured_selection[opts] = buffer_selection(0, info.start_line, info.end_line)
            end
        end
        -- The window opened next is no place to still be in Visual mode.
        vim.cmd('normal! \27')
    end
end

M.launch_info = launch_info
M.relative_to = relative_to
M.file_info = file_info
M.strip_selections = strip_selections
M.buffer_selection = buffer_selection
M.selection_ref = selection_ref
M.selection_block = selection_block
M.term_context_path = term_context_path
M.publish = publish
M.export_context = export_context
M.selection_appendix = selection_appendix
M.capture = capture

return M
