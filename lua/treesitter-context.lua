local api = vim.api
local ts_utils = require'nvim-treesitter.ts_utils'
local ts = require'vim.treesitter'
local Highlighter = vim.treesitter.highlighter
-- local ts_query = require('nvim-treesitter.query')
local parsers = require'nvim-treesitter.parsers'
local utils = require'treesitter-context.utils'
local slice = utils.slice
local word_pattern = utils.word_pattern

local defaultConfig = {
  enable = true,
  throttle = false,
  pin = true,
  max_lines = 0, -- no limit
}

local config = {}

-- Constants

-- Tells us at which node type to stop when highlighting a multi-line
-- node. If not specified, the highlighting stops after the first line.
local last_types = {
  [word_pattern('function')] = {
    c = 'function_declarator',
    cpp = 'function_declarator',
    lua = 'parameters',
    javascript = 'formal_parameters',
    typescript = 'formal_parameters',
  },
}

-- There are language-specific
local DEFAULT_TYPE_PATTERNS = {
  -- These catch most generic groups, eg "function_declaration" or "function_block"
  default = {
    'class',
    'function',
    'method',
    'for',
    'while',
    'if',
    'switch',
    'case',
  },
  rust = {
    'impl_item',
  },
  vhdl = {
    'process_statement',
    'architecture_body',
    'entity_declaration',
  },
}
local INDENT_PATTERN = '^%s+'

-- Script variables

local didSetup = false
local enabled = nil
local winid = nil
local bufnr = api.nvim_create_buf(false, true)
local ns = api.nvim_create_namespace('nvim-treesitter-context')
local context_nodes = {}
local context_types = {}
local previous_nodes = nil


-- Helper functions
local log_message = function(value)
  api.nvim_command('echom ' .. vim.fn.json_encode(value))
end

local get_target_node = function()
  local tree = parsers.get_parser():parse()[1]
  return tree:root()
end

local is_valid = function(node, filetype)
  local node_type = node:type()
  for _, rgx in ipairs(config.patterns.default) do
    if node_type:find(rgx) then
      return true, rgx
    end
  end
  local filetype_patterns = config.patterns[filetype]
  if filetype_patterns ~= nil then
    for _, rgx in ipairs(filetype_patterns) do
      if node_type:find(rgx) then
        return true, rgx
      end
    end
  end
  return false
end

local get_type_pattern = function(node, type_patterns)
  local node_type = node:type()
  for _, rgx in ipairs(type_patterns) do
    if node_type:find(rgx) then
      return rgx
    end
  end
  return nil
end

local function find_node(node, type)
  local children = ts_utils.get_named_children(node)
  for _, child in ipairs(children) do
    if child:type() == type then
      return child
    end
  end
  for _, child in ipairs(children) do
    local deep_child = find_node(child, type)
    if deep_child ~= nil then
      return deep_child
    end
  end
  return nil
end

local get_text_for_node = function(node)
  local start_row, start_col = node:start()
  local end_row, end_col     = node:end_()

  local lines =
    (vim.version().major == 0 and vim.version().minor < 7)
      and ts_utils.get_node_text(node, 0)
      or vim.split(ts.get_node_text(node, 0), '\n')

  if start_col ~= 0 then
    lines[1] = api.nvim_buf_get_lines(0, start_row, start_row + 1, false)[1]
  end
  start_col = 0

  local type = get_type_pattern(node, config.patterns.default) or node:type()
  local filetype = api.nvim_buf_get_option(0, 'filetype')
  local last_type = (last_types[type] or {})[filetype]
  local last_position = nil

  if last_type ~= nil then
    local child = find_node(node, last_type)

    if child ~= nil then
      last_position = {child:end_()}

      end_row = last_position[1]
      end_col = last_position[2]
      local last_index = end_row - start_row
      lines = slice(lines, 1, last_index + 1)
      lines[#lines] = slice(lines[#lines], 1, end_col)
    end
  end

  if last_position == nil then
    lines = slice(lines, 1, 1)
    end_row = start_row
    end_col = #lines[1]
  end

  local range = {start_row, start_col, end_row, end_col}

  return lines, range
end

-- Merge lines, removing the indentation after 1st line
local merge_lines = function(lines)
  local text = ''
  for i, line in ipairs(lines) do
    if i == 1 then
      text = text .. line
    else
      text = text .. line:gsub(INDENT_PATTERN, '')
    end
    text = text .. ' '
  end
  return text
end

-- Get indentation for lines except first
local get_indents = function(lines)
  local indents = vim.tbl_map(function(line)
    local indent = line:match(INDENT_PATTERN)
    return indent and #indent or 0
  end, lines)
  -- Dont skip first line indentation
  indents[1] = 0
  return indents
end

local get_gutter_width = function()
  return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff;
end

local nvim_augroup = function(group_name, definitions)
  api.nvim_command('augroup ' .. group_name)
  api.nvim_command('autocmd!')
  for _, def in ipairs(definitions) do
    local command = table.concat({'autocmd', unpack(def)}, ' ')
    if api.nvim_call_function('exists', {'##' .. def[1]}) ~= 0 then
      api.nvim_command(command)
    end
  end
  api.nvim_command('augroup END')
end

local cursor_moved_vertical
do
  local line
  cursor_moved_vertical = function()
    local newline =  vim.api.nvim_win_get_cursor(0)[1]
    if newline ~= line then
      line = newline
      return true
    end
    return false
  end
end

local function display_window(width, height, row, col)
  if winid == nil or not api.nvim_win_is_valid(winid) then
    winid = api.nvim_open_win(bufnr, false, {
      relative = 'win',
      width = width,
      height = height,
      row = row,
      col = col,
      focusable = false,
      style = 'minimal',
      noautocmd = true,
      border = 'none',
    })
    api.nvim_win_set_var(winid, 'treesitter_context', true)
  else
    api.nvim_win_set_config(winid, {
      win = api.nvim_get_current_win(),
      relative = 'win',
      width = width,
      height = height,
      row = row,
      col = col,
    })
  end
  api.nvim_win_set_option(winid, 'wrap', false)
  api.nvim_win_set_option(winid, 'winhl', 'NormalFloat:TreesitterContext')
end

-- Exports

local M = {
  config = config,
}

function M.do_au_cursor_moved_vertical()
  if cursor_moved_vertical() then
    vim.cmd [[doautocmd <nomodeline> User CursorMovedVertical]]
  end
end

function M.get_context(opts)
  if not parsers.has_parser() then return nil end
  local options = opts or {}

  local cursor_node = ts_utils.get_node_at_cursor()
  if not cursor_node then return nil end

  local matches = {}
  local expr = cursor_node

  local filetype = api.nvim_buf_get_option(0, 'filetype')
  while expr do
    local is_match, type = is_valid(expr, filetype)
    if is_match then
      table.insert(matches, 1, {expr, type})
    end
    expr = expr:parent()
  end

  if #matches == 0 then
    return nil
  end

  return matches
end

function M.get_parent_matches()
  if not parsers.has_parser() then return nil end

  -- FIXME: use TS queries when possible
  -- local matches = ts_query.get_capture_matches(0, '@scope.node', 'locals')

  local current = ts_utils.get_node_at_cursor()
  if not current then return end

  local parent_matches = {}
  local filetype = api.nvim_buf_get_option(0, 'filetype')
  local lines = 0
  local old_row = -1
  local last_row = -1
  local current_line = api.nvim_call_function('line', { '.' }) - 1
  local first_visible_line = api.nvim_call_function('line', { 'w0' }) - 1
  local capacity = current_line - first_visible_line
  local scroll = 0
  local is_full = false
  local n_visible = 0

  while current ~= nil do
    if lines >= capacity and not config.pin then
      is_full = true
      break
    end

    local position = {current:start()}
    local row = position[1]

    if is_valid(current, filetype)
      and row > 0
      and row ~= last_row then

      if row < current_line and row ~= old_row then
        if row >= first_visible_line then
          n_visible = n_visible + 1
        end
        table.insert(parent_matches, current)
      end

      if row < first_visible_line then
        lines = lines + 1
        last_row = position[1]
      end
      if config.max_lines > 0 and lines >= config.max_lines then
        is_full = true
        break
      end
      old_row = row
    end
    current = current:parent()
  end

  first_visible_line = first_visible_line + lines

  for i = n_visible, 1, -1 do
    local position = {parent_matches[i]:start()}
    local row = position[1]

    if row >= first_visible_line then
      break
    end

    if is_full then
      table.remove(parent_matches)
    else
      lines = lines + 1
      first_visible_line = first_visible_line + 1
      is_full = config.max_lines > 0 and lines >= config.max_lines
      if not config.pin then
        is_full = is_full or lines >= capacity
      end
    end
    n_visible = n_visible - 1
  end

  for i = 1, n_visible do
    table.remove(parent_matches, 1)
  end

  if config.pin then
    scroll = lines - capacity
  end

  return parent_matches, scroll
end

local function cannot_open(bufnr, winid)
  return vim.bo[bufnr].filetype == ''
    or vim.bo[bufnr].buftype ~= ''
    or vim.wo[winid].previewwindow
end

function M.update_context()
  local winid = api.nvim_get_current_win()
  local bufnr = api.nvim_win_get_buf(winid)

  if cannot_open(bufnr, winid) then
    M.close()
    return
  end

  local context, scroll = M.get_parent_matches()

  context_nodes = {}
  context_types = {}

  if context then

    for i = #context, 1, -1 do
      local node = context[i]
      local type = get_type_pattern(node, config.patterns.default) or node:type()

      table.insert(context_nodes, node)
      table.insert(context_types, type)
    end
  end

  if #context_nodes ~= 0 then
    M.open(scroll)
  else
    M.close()
  end
end

do
  local running = false

  function M.throttled_update_context()
    if running then return end
    running = true
    vim.defer_fn(function()
      local status, err = pcall(M.update_context)

      if not status then
        print('Failed to get context: ' .. err)
      end

      running = false
    end, 100)
  end
end

function M.close()
  previous_nodes = nil

  if winid ~= nil and api.nvim_win_is_valid(winid) then
    -- Can't close other windows when the command-line window is open
    if api.nvim_call_function('getcmdwintype', {}) ~= '' then
      return
    end

    api.nvim_win_close(winid, true)
  end
  winid = nil
end

function M.open(scroll)
  if #context_nodes == 0 then return end
  if context_nodes == previous_nodes then return end

  previous_nodes = context_nodes

  local saved_bufnr = api.nvim_get_current_buf()

  local gutter_width = get_gutter_width()
  local win_width  = math.max(1, api.nvim_win_get_width(0) - gutter_width)
  local win_height = math.max(1, #context_nodes)

  display_window(win_width, win_height, 0, gutter_width)

  if scroll and scroll > 0 then
    vim.cmd('execute "normal! ' .. scroll .. '\\<C-y>"')
  end

  -- Set text

  local context_ranges = {}
  local context_lines = {}
  local context_text = {}
  local context_indents = {}

  for i in ipairs(context_nodes) do
    local lines, range = get_text_for_node(context_nodes[i])
    local text = merge_lines(lines)
    local indents = get_indents(lines)
    table.insert(context_lines, lines)
    table.insert(context_ranges, range)
    table.insert(context_text, text)
    table.insert(context_indents, indents)
  end

  api.nvim_buf_set_lines(bufnr, 0, -1, false, context_text)

  -- api.nvim_command('echom ' .. vim.fn.json_encode({
  --   type = target_node:type(),
  --   text = ts_utils.get_node_text(target_node),
  -- }))

  -- Highlight

  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local buf_highlighter = Highlighter.active[saved_bufnr] or nil
  local buf_queries = nil
  local buf_query = nil

  if buf_highlighter then
    buf_queries = buf_highlighter._queries
    buf_query = buf_queries[vim.bo.filetype]
    if buf_query == nil then
      return
    end
  else
    local current_ft = api.nvim_buf_get_option(0, 'filetype')
    local buffer_ft  = api.nvim_buf_get_option(bufnr, 'filetype')
    if current_ft ~= buffer_ft then
      api.nvim_buf_set_option(bufnr, 'filetype', current_ft)
    end
    return
  end

  for i in ipairs(context_nodes) do
    local current_node = context_nodes[i]
    local range = context_ranges[i]
    local indents = context_indents[i]
    local lines = context_lines[i]

    local start_row = range[1]
    local start_col = range[2]
    local end_row   = range[3]
    local end_col   = range[4]

    local target_node = get_target_node()

    local start_row_absolute = current_node:start()

    local captures =
      buf_query:query()
        :iter_captures(target_node, saved_bufnr, start_row, current_node:end_(), nil)

    local last_line = nil
    local last_offset = nil

    for capture, node in captures do
      local hl = vim.fn.has('nvim-0.10') == 1
                   and buf_query:get_hl_from_capture(capture)
                   or buf_query.hl_cache[capture]
      local atom_start_row, atom_start_col,
            atom_end_row,   atom_end_col = node:range()

      if atom_end_row > end_row or
        (atom_end_row == end_row and atom_end_col > end_col) then
        break
      end

      if atom_start_row >= start_row_absolute then

        local intended_start_row = atom_start_row - start_row_absolute
        local intended_end_row   = atom_end_row   - start_row_absolute
        local intended_start_col = atom_start_col
        local intended_end_col   = atom_end_col

        local offset
        if intended_start_row == last_line then
          offset = last_offset
        else
          -- Add 1 for each space added between lines when
          -- we replace "\n" with " "
          offset = intended_start_row
          -- Add the length of each precending lines
          for j = 1, intended_start_row do
            offset = offset + #lines[j] - indents[j]
          end
          -- Remove the indentation negative offset for current line
          offset = offset - (indents[intended_start_row + 1])
        end

        local hl_start_row = i - 1
        local hl_end_row   = i - 1
        local hl_start_col = atom_start_col + offset
        local hl_end_col   = atom_end_col + offset

        api.nvim_buf_set_extmark(bufnr, ns,
          hl_start_row, hl_start_col,
          { end_line = hl_end_row, end_col = hl_end_col,
            hl_group = hl })
      end
    end
  end
end

function M.enable()
  local throttle = config.throttle and 'throttled_' or ''
  nvim_augroup('treesitter_context_update', {
    {'WinScrolled', '*',                   'silent lua require("treesitter-context").' .. throttle .. 'update_context()'},
    {'BufEnter',    '*',                   'silent lua require("treesitter-context").' .. throttle .. 'update_context()'},
    {'WinEnter',    '*',                   'silent lua require("treesitter-context").' .. throttle .. 'update_context()'},
    {'User',        'CursorMovedVertical', 'silent lua require("treesitter-context").' .. throttle .. 'update_context()'},
    {'CursorMoved', '*',                   'silent lua require("treesitter-context").do_au_cursor_moved_vertical()'},
    {'WinLeave',    '*',                   'silent lua require("treesitter-context").close()'},
    {'VimResized',  '*',                   'silent lua require("treesitter-context").open()'},
    {'User',        'SessionSavePre',      'silent lua require("treesitter-context").close()'},
    {'User',        'SessionSavePost',     'silent lua require("treesitter-context").open()'},
  })

  M.throttled_update_context()
  enabled = true
end

function M.disable()
  nvim_augroup('treesitter_context_update', {})

  M.close()
  enabled = false
end

function M.toggleEnabled()
    if enabled then
        M.disable()
    else
        M.enable()
    end
end

function M.onVimEnter()
  if didSetup then return end
  -- Setup with default options if user didn't call setup()
  M.setup()
end

-- Setup

function M.setup(options)
  didSetup = true

  local userOptions = options or {}

  config = vim.tbl_deep_extend("force", {}, defaultConfig, userOptions)
  config.patterns =
    vim.tbl_deep_extend("force", {}, DEFAULT_TYPE_PATTERNS, userOptions.patterns or {})

  for filetype, patterns in pairs(config.patterns) do
    config.patterns[filetype] = vim.tbl_map(word_pattern, patterns)
  end

  if config.enable then
    M.enable()
  else
    M.disable()
  end
end

api.nvim_command('command! TSContextEnable  lua require("treesitter-context").enable()')
api.nvim_command('command! TSContextDisable lua require("treesitter-context").disable()')
api.nvim_command('command! TSContextToggle  lua require("treesitter-context").toggleEnabled()')

api.nvim_command('highlight default link TreesitterContext NormalFloat')

nvim_augroup('treesitter_context', {
  {'VimEnter', '*', 'lua require("treesitter-context").onVimEnter()'},
})

return M
