-- What the user is looking at, and what is sent about it: the launch_info
-- captured for a send, which the `commands` resolver is given, and the
-- selection block an agent reads.
local options = require('foyer.config')
local config = options.options
local project_root = options.project_root

local M = {}

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

-- The lines of the Visual selection, first to last. line('v') is the anchor,
-- which sits below the cursor in a selection dragged upward; a reversed range
-- is no use to whoever reads it.
local function visual_lines()
    local anchor, cursor = vim.fn.line('v'), vim.fn.line('.')
    return math.min(anchor, cursor), math.max(anchor, cursor)
end

-- What the user is looking at, in the conventional launch_info shape.
-- Empty for a buffer with no file: a terminal, a scratch buffer, one never
-- written.
local function launch_info()
    local info = file_info(0)
    if not info then return {} end
    info.current_line = vim.fn.line('.')
    if in_visual() then
        info.start_line, info.end_line = visual_lines()
    end
    return info
end

-- A buffer that would be a file once written: no name yet, and nothing that
-- makes it something else -- a terminal, a scratch or help buffer.
local function is_unnamed(buf)
    return vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf) == ''
end

-- Lines {first}..{last} of {buf}, ready for selection_block(): as the buffer
-- has them now, unsaved edits and all, since that is what the user is pointing
-- at, whatever the disk says. A buffer never written has no file to name, but
-- its lines are all the more worth sending: there is nowhere else to read
-- them. Nil for a terminal, a scratch buffer and the like.
local function buffer_selection(buf, first, last)
    local info = file_info(buf)
    if not info then
        if not is_unnamed(buf) then return nil end
        info = {}
    end
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

-- The selected range in the project's own terms, `src/main.c:30-36`, or
-- `[No Name]:30-36` for a buffer never written: short enough for a window
-- title, which is where the user reads it.
local function selection_ref(info)
    if not info.start_line then return nil end
    local file = info.current_file or '[No Name]'
    if info.end_line == info.start_line then
        return ('%s:%d'):format(file, info.start_line)
    end
    return ('%s:%d-%d'):format(file, info.start_line, info.end_line)
end

-- {lines} in a file of their own, for an agent to read: under tempname(), so
-- only this user can read it and Neovim removes it on exit, which is late
-- enough for an agent to come back to it. Named with the extension of
-- {filetype} where that extension says it back, `.txt` otherwise. Nil if it
-- cannot be written.
local function copy_lines(lines, filetype)
    local ext = 'txt'
    if filetype and filetype ~= ''
        and vim.filetype.match({ filename = 'x.' .. filetype }) == filetype then
        ext = filetype
    end
    local path = vim.fn.tempname() .. '.' .. ext
    local ok, rc = pcall(vim.fn.writefile, lines, path)
    if not ok or rc ~= 0 then return nil end
    return path
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
--
-- A buffer never written has no file to name: the label says so, so the
-- agent does not go looking for one. Past `selection_max_lines` a label alone
-- would point it at nothing, so the lines are copied to a file of their own,
-- which the label names: a long paste is what some agents' input boxes take
-- worst. Should the copy fail, they go inline after all.
local function selection_block(sel)
    local info = sel.info
    local where = info.end_line == info.start_line
        and ('line %d'):format(info.start_line)
        or ('lines %d-%d'):format(info.start_line, info.end_line)
    local label
    if info.current_file then
        local file = info.current_file
        if info.project_root then file = vim.fs.joinpath(info.project_root, file) end
        label = ('Selected in my editor: %s, %s'):format(file, where)
        -- Said outright, so an agent that does open the file is not misled by
        -- it.
        if sel.modified then label = label .. ' (unsaved; the file on disk differs)' end
    else
        label = ('Selected in my editor: %s of a buffer with no file'):format(where)
    end

    local max = config.selection_max_lines or 0
    if max <= 0 or #sel.lines > max then
        if info.current_file then return label end
        local copy = copy_lines(sel.lines, sel.filetype)
        if copy then return ('%s, copied whole to %s'):format(label, copy) end
    end
    local text = table.concat(sel.lines, '\n')
    -- A fence longer than any run of backticks in the text, so code that
    -- holds a fence of its own cannot close this one early.
    local fence = '```'
    while text:find(fence, 1, true) do fence = fence .. '`' end
    return ('%s\n%s%s\n%s\n%s'):format(label, fence, sel.filetype or '', text, fence)
end

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
            -- From the buffer rather than launch_info, which is empty for one
            -- never written: that has no file to name, yet its lines are all
            -- the more worth sending.
            local sel = buffer_selection(0, visual_lines())
            if sel then
                opts.selection = selection_ref(sel.info)
                captured_selection[opts] = sel
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
M.selection_appendix = selection_appendix
M.capture = capture

return M
