local api, vfn, uv, lsp = vim.api, vim.fn, vim.uv, vim.lsp
local protocol = require('vim.lsp.protocol')
local util = require('vim.lsp.util')
local ms = protocol.Methods
local group = api.nvim_create_augroup('Epo', { clear = true })
local ns = api.nvim_create_namespace('Epo')
local au = api.nvim_create_autocmd
local match_fuzzy = false
local signature = false
local debounce_time = 150
local signature_border, kind_format

local timer -- [[uv_timer_t]]
local info_timer --[[uv_timer_t]]

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

--- @param t uv.uv_timer_t
local function timer_remove(t)
  if t and t:is_active() and not t:is_closing() then
    t:stop()
    t:close()
    ---@diagnostic disable-next-line: cast-local-type
    t = nil
  end
end

--- @param fn function
local function timer_create(time, fn)
  local t = uv.new_timer()
  if not t then
    return
  end
  t:start(time, 0, vim.schedule_wrap(fn))
  return t
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
  local spos = valid:find('%$')
  if spos then
    return string.sub(valid, 1, spos - 1)
  end
  return valid
end

local function lspkind(kind)
  local k = protocol.CompletionItemKind[kind] or 'Unknown'
  return kind_format(k)
end

local function close_popup_win(winid)
  if winid and api.nvim_win_is_valid(winid) then
    api.nvim_win_close(winid, true)
  end
end

local function popup_markdown_set(wininfo)
  if vim.tbl_isempty(wininfo) then
    return
  end
  local ok, _ = pcall(api.nvim_win_is_valid, wininfo.winid)
  if not ok then
    return
  end
  ok, _ = pcall(api.nvim_buf_is_valid, wininfo.bufnr)
  if not ok then
    return
  end
  vim.wo[wininfo.winid].conceallevel = 2
  vim.wo[wininfo.winid].concealcursor = 'niv'
  vim.treesitter.start(wininfo.bufnr, 'markdown')
  if #api.nvim_win_get_config(0).relative > 0 then
    local config = api.nvim_win_get_config(wininfo.winid)
    config.zindex = 999
    api.nvim_win_set_config(wininfo.winid, config)
  end
end

local function show_info(bufnr, curitem, selected)
  local param = vim.tbl_get(curitem, 'user_data', 'nvim', 'lsp', 'completion_item')
  -- Preview the emmet abbreviations
  if param and param.detail == 'Emmet Abbreviation' then
    local data = vim.fn.complete_info()
    local wininfo = {
      winid = data.preview_winid,
      bufnr = data.preview_bufnr,
    }
    popup_markdown_set(wininfo)
    return
  end
  -- snippet preview in info
  if curitem.kind == 's' then
    local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
    local ok, text = pcall(lsp._snippet_grammar.parse, param.insertText)
    if not ok then
      return
    end
    local info = ('```' .. lang .. '\n%s' .. '\n```'):format(text)
    local wininfo = api.nvim__complete_set(selected, { info = info })
    popup_markdown_set(wininfo)
    return
  end
  local clients = lsp.get_clients({ id = context[bufnr].client_id })
  if #clients == 0 then
    return
  end
  local client = clients[1]
  client.request(ms.completionItem_resolve, param, function(_, result)
    local data = vim.fn.complete_info()
    if
      not result
      or not data.items
      or (data.items[data.selected + 1] and data.items[data.selected + 1].word ~= curitem.word)
    then
      close_popup_win(data.preview_winid)
      return
    end
    local value = vim.tbl_get(result, 'documentation', 'value')
    if not value or #value == 0 then
      close_popup_win(data.preview_winid)
      return
    end
    local wininfo = api.nvim__complete_set(selected, { info = value })
    popup_markdown_set(wininfo)
  end, bufnr)
end

---check event has registered
---@param e string event
---@parma bufnr integer buffer id
---@return boolean when true is created, otherwise is false.
local function event_has_created(e, bufnr)
  return #api.nvim_get_autocmds({ group = group, buffer = bufnr, event = e }) > 0
end

---delete an event in group.
---@param e string event
---@param bufnr integer buffer id
local function event_delete(e, bufnr)
  local result = api.nvim_get_autocmds({ group = group, buffer = bufnr, event = e })
  for _, item in ipairs(result) do
    api.nvim_del_autocmd(item.id)
  end
end

local function complete_changed(bufnr)
  api.nvim_create_autocmd('CompleteChanged', {
    buffer = bufnr,
    group = group,
    callback = function(args)
      timer_remove(info_timer)
      local citem = vim.v.event.completed_item
      if not citem then
        return
      end
      local data = vim.fn.complete_info()
      info_timer = timer_create(100, function()
        show_info(args.buf, citem, data.selected)
      end)
    end,
  })
end

local function signature_help(client, bufnr, lnum)
  local params = util.make_position_params()
  client.request(ms.textDocument_signatureHelp, params, function(err, result, ctx)
    if err or not result or not api.nvim_buf_is_valid(ctx.bufnr) then
      return
    end
    local triggers =
      vim.tbl_get(client.server_capabilities, 'signatureHelpProvider', 'triggerCharacters')
    local lines, hl =
      util.convert_signature_help_to_markdown_lines(result, vim.bo[ctx.bufnr].filetype, triggers)
    if not lines or vim.tbl_isempty(lines) then
      return
    end
    -- just show parmas in signature help
    lines = { unpack(lines, 1, 3) }
    local fbuf, fwin = util.open_floating_preview(lines, 'markdown', {
      close_events = {},
      border = signature_border,
    })
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
        if not data.parameters or not data.parameters or not vim.snippet._session then
          return
        end
        local index = vim.tbl_get(vim.snippet, '_session', 'current_tabstop', 'index') or 0
        if index and data.parameters[index] and data.parameters[index].label then
          api.nvim_buf_clear_namespace(fbuf, ns, line, line + 1)
          if type(data.parameters[index].label) ~= 'table' then
            return
          end
          api.nvim_buf_add_highlight(fbuf, ns, hi, line, unpack(data.parameters[index].label))
        end
      end,
    })
    local count = vim.tbl_count(vim.snippet._session.tabstops) or 0
    api.nvim_create_autocmd({ 'CursorMovedI', 'CursorMoved' }, {
      buffer = ctx.bufnr,
      group = g,
      callback = function(args)
        local curline = api.nvim_win_get_cursor(0)[1]
        local tabstop_idx = vim.tbl_get(vim.snippet, '_session', 'current_tabstop', 'index') or 0
        if
          (curline ~= lnum and api.nvim_win_is_valid(fwin))
          or (args.event == 'CursorMovedI' and tabstop_idx == count)
        then
          api.nvim_win_close(fwin, true)
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
      local cp_item = vim.tbl_get(item, 'user_data', 'nvim', 'lsp', 'completion_item')
      if not cp_item then
        return
      end
      --usually the first is main client for me.
      local client = lsp.get_clients({ id = context[args.buf].client_id })[1]
      if not client then
        return
      end
      local startidx = context[args.buf].startidx
      local lnum, col = unpack(api.nvim_win_get_cursor(0))
      local curline = api.nvim_get_current_line()

      local is_snippet = item.kind == 's'
        or cp_item.insertTextFormat == protocol.InsertTextFormat.Snippet
      local offset_snip
      --apply textEdit
      if cp_item.textEdit then
        if is_snippet and cp_item.textEdit.newText:find('%$') then
          offset_snip = cp_item.textEdit.newText
        else
          local newText = cp_item.textEdit.newText
          local range = cp_item.textEdit.range
          -- work around with pair
          -- situation1: local t = {} t[#|]<--
          -- situation2: #include "header item|""<--
          local nextchar = curline:sub(col + 1, col + 1)
          local prevchar = curline:sub(range.start.character, range.start.character)
          local extra = 0
          -- asume they are paired
          if
            (prevchar == '[' and nextchar == ']' and newText:find(']'))
            or (nextchar == '"' and newText:find('"'))
          then
            extra = 1
          end
          api.nvim_buf_set_text(
            bufnr,
            lnum - 1,
            startidx,
            lnum - 1,
            startidx + #item.word + extra,
            { '' }
          )
          range['end'].character = api.nvim_win_get_cursor(0)[2]
          util.apply_text_edits({ cp_item.textEdit }, bufnr, client.offset_encoding)
          api.nvim_win_set_cursor(
            0,
            { lnum, range['end'].character + #newText + extra - (startidx - range.start.character) }
          )
        end
      elseif cp_item.insertTextFormat == protocol.InsertTextFormat.Snippet then
        offset_snip = cp_item.insertText
      end

      if cp_item.additionalTextEdits then
        util.apply_text_edits(cp_item.additionalTextEdits, bufnr, client.offset_encoding)
      end

      if vim.bo[args.buf].filetype == 'rust' and vim.tbl_get(cp_item, 'data', 'imports') then
        for _, import in ipairs(cp_item.data.imports) do
          if import.full_import_path then
            local full = ('use %s;'):format(import.full_import_path)
            api.nvim_buf_set_lines(args.buf, 0, 0, false, { full, '' })
          end
        end
      end

      if offset_snip then
        if cp_item.detail == 'Emmet Abbreviation' then
          -- Remove the label from the completion item
          local startrow = lnum - 1
          api.nvim_buf_set_text(bufnr, startrow, startidx, startrow, startidx + #item.word, { '' })
        else
          offset_snip = offset_snip:sub(col - context[args.buf].startidx + 1)
        end
        if #offset_snip > 0 then
          vim.snippet.expand(offset_snip)
        end
      end
      context[args.buf] = nil
      event_delete('CompleteChanged', args.buf)
      if signature then
        local clients =
          vim.lsp.get_clients({ bufnr = args.buf, method = ms.textDocument_signatureHelp })
        if #clients == 0 then
          return
        end
        if
          vim.tbl_contains(
            clients[1].server_capabilities.signatureHelpProvider.triggerCharacters,
            api.nvim_get_current_line():sub(col + 1, col + 1)
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
  if vim.islist(result) then
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

  local lang = vim.treesitter.language.get_lang(vim.bo[ctx.bufnr].filetype)
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
      if item.detail == 'Emmet Abbreviation' then
        entry.word = item.label
        -- Try overwrite the start index in the case to use
        -- completions items with no word characters like > or :
        start_idx = textEdit.range['start'].character
        startcol = start_idx + 1
        context[ctx.bufnr].startidx = start_idx
      else
        local start_col = #prefix ~= 0 and vfn.charidx(before_text, start_idx) + 1 or col
        local range
        if textEdit.range then
          range = textEdit.range
        elseif textEdit.insert then
          range = textEdit.insert
        end
        local te_startcol = charidx_without_comp(ctx.bufnr, range.start)
        if te_startcol ~= start_col then
          local extra = start_idx - te_startcol
          entry.word = textEdit.newText:sub(start_col - te_startcol + extra)
        else
          entry.word = textEdit.newText
        end
      end
    elseif vim.tbl_get(item, 'insertText') then
      entry.word = item.insertText
    else
      entry.word = item.label
    end

    local register = true
    if lsp.protocol.InsertTextFormat[item.insertTextFormat] == 'Snippet' then
      entry.word = make_valid_word(entry.word)
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
        -- Expand the information about the Emmet abbreviation
        if item.detail == 'Emmet Abbreviation' then
          entry.info = item.detail .. '\n```' .. lang .. '\n' .. item.documentation .. '\n```'
        else
          entry.info = item.info
        end
      end

      entry.score = item.sortText or item.label
      entrys[#entrys + 1] = entry
    end
  end

  table.sort(entrys, function(a, b)
    return a.score < b.score
  end)
  if vim.startswith(api.nvim_get_mode().mode, 'i') then
    vfn.complete(startcol, entrys)
    if
      vim.tbl_contains(vim.opt.completeopt:get(), 'popup')
      and not event_has_created('CompleteChanged', ctx.bufnr)
    then
      complete_changed(ctx.bufnr)
      -- fix if to show the info if the noselect is not set in
      -- menuoptions
      local completeopts = vim.opt_local.completeopt:get()
      if not vim.tbl_contains(completeopts, 'noselect') then
        -- show info cause the first item is selected
        if #entrys > 0 then
          timer_remove(info_timer)
          local citem = entrys[1]
          local data = vim.fn.complete_info()
          info_timer = timer_create(100, function()
            show_info(ctx.bufnr, citem, data.selected)
          end)
        end
      end
    end
    if not event_has_created('CompleteDone', ctx.bufnr) then
      complete_ondone(ctx.bufnr)
    end
  end
end

local function debounce(client, bufnr, triggerKind, triggerChar)
  timer_remove(timer)
  local params = util.make_position_params(api.nvim_get_current_win(), client.offset_encoding)
  params.context = {
    triggerKind = triggerKind,
    triggerCharacter = triggerChar,
  }
  timer = timer_create(debounce_time, function()
    client.request(ms.textDocument_completion, params, completion_handler, bufnr)
  end)
end

-- Aux Function for manage completion
local function call_completion(bufnr, client)
  if disable or vim.fn.pumvisible() == 1 then
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
    local triggerCharacters = client.server_capabilities.completionProvider.triggerCharacters or {}
    if not vim.tbl_contains(triggerCharacters, char) then
      return
    end
    triggerKind = lsp.protocol.CompletionTriggerKind.TriggerCharacter
    triggerChar = char
  end

  if not context[bufnr] then
    context_init(bufnr, client.id)
  end
  debounce(client, bufnr, triggerKind, triggerChar)
end

-- Function to trigger autocompletion manually
local function complete()
  local bufnr = vim.fn.bufnr()
  local ctx = context[bufnr]
  if not ctx then
    return
  end
  local client_id = vim.tbl_get(ctx, 'client_id')
  if not client_id then
    return
  end
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    return
  end
  call_completion(bufnr, client)
end

local function auto_complete(client, bufnr)
  au('TextChangedI', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      call_completion(args.buf, client)
    end,
  })
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
  opt = opt or {}
  match_fuzzy = opt.fuzzy or false
  debounce_time = opt.debounce_time or 50
  signature = opt.signature or false
  signature_border = opt.signature_border or 'rounded'
  kind_format = opt.kind_format or function(k)
    return k:lower():sub(1, 1)
  end
  --make sure your neovim is newer enough
  api.nvim_set_option_value('completeopt', 'menu,menuone,noinsert,popup', { scope = 'global' })

  -- Usually I just use one client for completion so just one
  au('LspAttach', {
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

local function disable_trigger()
  if not disable then
    disable = true
  end
end

return {
  setup = setup,
  register_cap = register_cap,
  disable_trigger = disable_trigger,
  complete = complete,
}
