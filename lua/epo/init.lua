local api, vfn, uv, lsp = vim.api, vim.fn, vim.uv, vim.lsp
local protocol = require('vim.lsp.protocol')
local util = require('vim.lsp.util')
local ms = protocol.Methods
local group = api.nvim_create_augroup('Epo', { clear = true })
local ns = api.nvim_create_namespace('Epo')
local match_fuzzy = false
local signature = false
local debounce_time = 100
-- Ctrl-Y will trigger TextChangedI again
-- avoid completion redisplay add a status check
local disable = nil
local context = {}

local function context_init(bufnr, id)
  context[bufnr] = {
    incomplete = {},
    timer = nil,
    client_id = id,
  }
end

local function charidx_without_comp(bufnr, pos)
  if pos.character <= 0 then
    return pos.character
  end
  local text = api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1]
  if #text == 0 then
    return pos.character
  end
  local idx = vfn.byteidxcomp(text, pos.character)
  if idx ~= -1 then
    if idx == #text then
      return vfn.strcharlen(text)
    else
      return vfn.charidx(text, idx, false)
    end
  end
  return pos.character
end

local function make_valid_word(str_arg)
  local str = string.gsub(str_arg, '%$[0-9]+|%${%(\\%.%|[^}]+}', '')
  str = string.gsub(str, '\\(.)', '%1')
  local valid = string.match(str, "^[^\"'' (<{[%s\t\r\n]+")
  if valid == nil or valid == '' then
    return str
  end

  if string.match(valid, ':$') then
    return string.sub(valid, 1, -3)
  end

  return valid
end

local function lspkind(kind)
  local k = protocol.CompletionItemKind[kind] or 'Unknown'
  return k:lower():sub(1, 1)
end

local function show_info(bufnr)
  local info = vim.tbl_get(vim.v.event, 'completed_item', 'info')
  local data = vim.fn.complete_info()
  local selected = data.selected
  if not info or #info == 0 then
    local param =
      vim.tbl_get(vim.v.event.completed_item, 'user_data', 'nvim', 'lsp', 'completion_item')
    local client = lsp.get_clients({ id = context[bufnr].client_id })[1]
    client.request(ms.completionItem_resolve, param, function(_, result)
      if not result then
        return
      end
      local value = vim.tbl_get(result, 'documentation', 'value')
      local kind = vim.tbl_get(result, 'documentation', 'kind')
      if value then
        local wininfo = api.nvim_complete_set_info(selected, value)
        api.nvim_set_option_value('filetype', kind or '', { buf = wininfo.bufnr })
      end
    end, bufnr)
  end
end

local function complete_changed(bufnr)
  api.nvim_create_autocmd('CompleteChanged', {
    buffer = bufnr,
    group = group,
    callback = function(args)
      show_info(args.buf)
    end,
  })
end

local function signature_help(client, bufnr, lnum)
  local params = util.make_position_params()
  local fwin, fbuf
  client.request(ms.textDocument_signatureHelp, params, function(err, result, ctx)
    if err or not api.nvim_buf_is_valid(ctx.bufnr) then
      return
    end
    local triggers =
      vim.tbl_get(client.server_capabilities, 'signatureHelpProvider', 'triggerCharacters')
    local ft = vim.bo[ctx.bufnr].filetype
    local lines, hl = util.convert_signature_help_to_markdown_lines(result, ft, triggers)
    ---@diagnostic disable-next-line: param-type-mismatch
    if not lines or vim.tbl_isempty(lines) then
      return
    end
    -- just show parmas in signature help
    lines = { unpack(lines, 1, 3) }
    fbuf, fwin = util.open_floating_preview(lines, 'markdown', {
      close_events = {},
      border = 'rounded',
    })
    vim.bo[fbuf].syntax = 'on'

    local hi = 'LspSignatureActiveParameter'
    local line = vim.startswith(lines[1], '```') and 1 or 0
    if hl then
      api.nvim_buf_add_highlight(fbuf, ns, hi, line, unpack(hl))
    end

    local g = api.nvim_create_augroup('epo_with_signature_' .. ctx.bufnr, { clear = true })
    local data = result.signatures[1] or result.signature
    api.nvim_create_autocmd('ModeChanged', {
      buffer = ctx.bufnr,
      group = g,
      callback = function()
        ---@diagnostic disable-next-line: invisible
        if not data.parameters or not data.parameters or not vim.snippet._session then
          return
        end
        ---@diagnostic disable-next-line: invisible
        local index = vim.snippet._session.current_tabstop.index
        if index and data.parameters[index] and data.parameters[index].label then
          api.nvim_buf_clear_namespace(fbuf, ns, line, line + 1)
          api.nvim_buf_add_highlight(fbuf, ns, hi, line, unpack(data.parameters[index].label))
        end
      end,
    })

    api.nvim_create_autocmd({ 'CursorMovedI', 'CursorMoved' }, {
      buffer = ctx.bufnr,
      group = g,
      callback = function()
        local curline = api.nvim_win_get_cursor(0)[1]
        if curline ~= lnum and api.nvim_win_is_valid(fwin) then
          api.nvim_win_close(fwin, true)
          api.nvim_del_augroup_by_id(g)
        end
      end,
    })

    ---@diagnostic disable-next-line: invisible
    local count = vim.tbl_count(vim.snippet._session.tabstops)
    api.nvim_create_autocmd('CursorMovedI', {
      buffer = ctx.bufnr,
      group = g,
      callback = function()
        ---@diagnostic disable-next-line: invisible
        local curindex = vim.snippet._session.current_tabstop.index + 1
        if curindex == count then
          pcall(api.nvim_win_close, fwin, true)
          api.nvim_del_augroup_by_id(g)
        end
      end,
    })
  end, bufnr)
end

local function complete_ondone(bufnr)
  api.nvim_create_autocmd('CompleteDone', {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function(args)
      local item = vim.v.completed_item
      if not item or vim.tbl_isempty(item) then
        return
      end
      if not disable then
        disable = true
      end
      local completion_item = vim.tbl_get(item, 'user_data', 'nvim', 'lsp', 'completion_item')
      if not completion_item then
        return
      end
      local client = lsp.get_clients({ id = context[args.buf].client_id })[1]
      if not client then
        return
      end
      local lnum, col = unpack(api.nvim_win_get_cursor(0))
      if completion_item.additionalTextEdits then
        lsp.util.apply_text_edits(completion_item.additionalTextEdits, bufnr, 'utf-8')
      end

      local is_snippet = completion_item.insertTextFormat == protocol.InsertTextFormat.Snippet
      local offset_snip
      --apply textEdit
      if completion_item.textEdit then
        if is_snippet then
          offset_snip = completion_item.textEdit.newText
        else
          local range = completion_item.textEdit.range
          range['end'].character = col
          lsp.util.apply_text_edits({ completion_item.textEdit }, bufnr, client.offset_encoding)
        end
      elseif completion_item.insertTextFormat == protocol.InsertTextFormat.Snippet then
        offset_snip = completion_item.insertText
      end

      if offset_snip then
        offset_snip = completion_item.insertText:sub(col - context[args.buf].startidx + 1)
        if #offset_snip > 0 then
          vim.snippet.expand(offset_snip)
        end
      end

      if signature then
        local clients =
          vim.lsp.get_clients({ bufnr = args.buf, method = ms.textDocument_signatureHelp })
        if not clients or #clients == 0 then
          return
        end
        local line = api.nvim_get_current_line()
        local char = line:sub(col + 1, col + 1)
        if
          vim.tbl_contains(
            clients[1].server_capabilities.signatureHelpProvider.triggerCharacters,
            char
          )
        then
          signature_help(clients[1], args.buf, lnum)
        end
      end
    end,
  })
end

local function completion_handler(_, result, ctx)
  local client = lsp.get_clients({ id = ctx.client_id })
  if not result or not client or not api.nvim_buf_is_valid(ctx.bufnr) then
    return
  end
  local entrys = {}

  local compitems
  if vim.tbl_islist(result) then
    compitems = result
  else
    compitems = result.items
    context[ctx.bufnr].incomplete[ctx.client_id] = result.isIncomplete or false
  end

  local col = vfn.charcol('.')
  local line = api.nvim_get_current_line()
  local before_text = col == 1 and '' or line:sub(1, col - 1)

  -- Get the start position of the current keyword
  local ok, retval = pcall(vfn.matchstrpos, before_text, '\\k*$')
  if not ok or not #retval == 0 then
    return
  end
  local prefix, start_idx = unpack(retval)
  context[ctx.bufnr].startidx = start_idx
  local startcol = start_idx + 1
  prefix = prefix:lower()

  for _, item in ipairs(compitems) do
    local entry = {
      abbr = item.label,
      kind = lspkind(item.kind),
      icase = 1,
      dup = 1,
      empty = 1,
      user_data = {
        nvim = {
          lsp = {
            completion_item = item,
          },
        },
      },
    }

    local textEdit = vim.tbl_get(item, 'textEdit')
    if textEdit then
      local start_col = #prefix ~= 0 and vfn.charidx(before_text, start_idx) + 1 or col
      local range = {}
      if textEdit.range then
        range = textEdit.range
      elseif textEdit.insert then
        range = textEdit.insert
      end
      local te_startcol = charidx_without_comp(ctx.bufnr, range.start)
      if te_startcol ~= start_col then
        local offset = start_col - te_startcol - 1
        entry.word = textEdit.newText:sub(offset)
      else
        entry.word = textEdit.newText
      end
    elseif vim.tbl_get(item, 'insertText') then
      entry.word = item.insertText
    else
      entry.word = item.label
    end

    local register = true
    if lsp.protocol.InsertTextFormat[item.insertTextFormat] == 'Snippet' then
      entry.word = make_valid_word(entry.word)
      -- entry.word = util.parse_snippet(entry.word)
    elseif not context[ctx.bufnr].incomplete then
      if #prefix ~= 0 then
        local filter = item.filterText or entry.word
        if
          filter and (match_fuzzy and #vfn.matchfuzzy({ filter }, prefix) == 0)
          or (not vim.startswith(filter:lower(), prefix) or not vim.startswith(filter, prefix))
        then
          register = false
        end
      end
    end

    if register then
      if item.detail and #item.detail > 0 then
        entry.menu = vim.split(item.detail, '\n', { trimempty = true })[1]
      end

      if item.documentation and #item.documentation > 0 then
        entry.info = item.info
      end

      entry.score = item.sortText or item.label
      entrys[#entrys + 1] = entry
    end
  end

  table.sort(entrys, function(a, b)
    return a.score < b.score
  end)

  local mode = api.nvim_get_mode()['mode']
  if mode == 'i' or mode == 'ic' then
    vfn.complete(startcol, entrys)
    complete_ondone(ctx.bufnr)
    if vim.tbl_contains(vim.opt.completeopt:get(), 'popup') then
      complete_changed(ctx.bufnr)
    end
  end
end

local function completion_request(client, bufnr, trigger_kind, trigger_char)
  local params = util.make_position_params(api.nvim_get_current_win(), client.offset_encoding)
  params.context = {
    triggerKind = trigger_kind,
    triggerCharacter = trigger_char,
  }
  client.request(ms.textDocument_completion, params, completion_handler, bufnr)
end

local function debounce(client, bufnr, triggerKind, triggerChar)
  if not context[bufnr] then
    return
  end
  if context[bufnr].timer and context[bufnr].timer:is_active() then
    context[bufnr].timer:close()
    context[bufnr].timer:stop()
    context[bufnr].timer = nil
  end
  context[bufnr].timer = uv.new_timer()
  context[bufnr].timer:start(debounce_time, 0, function()
    vim.schedule(function()
      completion_request(client, bufnr, triggerKind, triggerChar)
    end)
  end)
end

local function auto_complete(client, bufnr)
  api.nvim_create_autocmd('TextChangedI', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      if disable then
        disable = false
        return
      end
      local col = vfn.charcol('.')
      local line = api.nvim_get_current_line()
      if col == 0 or #line == 0 then
        return
      end
      local triggerKind = lsp.protocol.CompletionTriggerKind.Invoked
      local triggerChar = ''
      local char = line:sub(col - 1, col - 1)
      local ok, val = pcall(api.nvim_eval, ([['%s' !~ '\k']]):format(char))
      if not ok then
        return
      end

      if val ~= 0 then
        local triggerCharacters = client.server_capabilities.completionProvider.triggerCharacters
          or {}
        if not vim.tbl_contains(triggerCharacters, char) then
          return
        end
        triggerKind = lsp.protocol.CompletionTriggerKind.TriggerCharacter
        triggerChar = char
      end
      if not context[args.buf] then
        context_init(args.buf, client.id)
      end
      debounce(client, args.buf, triggerKind, triggerChar)
    end,
  })
  local build = vim.version().build
  if build:match('^g') or build:match('dirty') then
    -- api.nvim_set_option_value('completeopt', 'menu,noinsert,popup', { scope = 'global' })
  end
end

local function register_cap()
  return {
    textDocument = {
      completion = {
        completionItem = {
          snippetSupport = vim.snippet and true or false,
          resolveSupport = {
            properties = { 'edit', 'documentation', 'detail', 'additionalTextEdits' },
          },
        },
        completionList = {
          itemDefaults = {
            'editRange',
            'insertTextFormat',
            'insertTextMode',
            'data',
          },
        },
      },
    },
  }
end

local function setup(opt)
  match_fuzzy = opt.fuzzy or false
  debounce_time = opt.debounce_time or 50
  signature = opt.signature or false

  if not vim.snippet then
    vim.notify('neovim version a bit old', vim.log.levels.WARN)
  end

  -- Usually I just use one client for completion so just one
  api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      local clients = lsp.get_clients({
        bufnr = args.buf,
        method = ms.textDocument_completion,
        id = args.data.client_id,
      })
      if #clients == 0 then
        return
      end
      local created = api.nvim_get_autocmds({
        event = { 'TextChangedI' },
        group = group,
        buffer = args.buf,
      })
      if #created ~= 0 then
        return
      end
      auto_complete(clients[1], args.buf)
    end,
  })
end

return {
  setup = setup,
  register_cap = register_cap,
}
