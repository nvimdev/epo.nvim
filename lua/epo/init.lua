local api, vfn, uv, lsp = vim.api, vim.fn, vim.uv, vim.lsp
local protocol = require('vim.lsp.protocol')
local util = require('vim.lsp.util')
local ms = protocol.Methods
local group = api.nvim_create_augroup('Epo', { clear = true })
local ns = api.nvim_create_namespace('Epo')
local au = api.nvim_create_autocmd
local match_fuzzy = false
local signature = false
local debounce_time = 200
local snippet_path, signature_border, kind_format
local timer = nil
local info_timer = nil

-- Ctrl-Y will trigger TextChangedI again
-- avoid completion redisplay add a status check
local disable = nil
local context = {
  snippets = {},
}

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
  return kind_format(k)
end

local function show_info(bufnr, curitem, selected)
  local param = vim.tbl_get(curitem, 'user_data', 'nvim', 'lsp', 'completion_item')
  local client = lsp.get_clients({ id = context[bufnr].client_id })[1]
  client.request(ms.completionItem_resolve, param, function(_, result)
    local data = vim.fn.complete_info()
    if
      not result
      or not data.items
      or (data.items[data.selected + 1] and data.items[data.selected + 1].word ~= curitem.word)
    then
      if data.preview_winid and api.nvim_win_is_valid(data.preview_winid) then
        api.nvim_win_close(data.preview_winid, true)
      end
      return
    end
    local value = vim.tbl_get(result, 'documentation', 'value')
    if value then
      local wininfo = api.nvim_complete_set(selected, { info = value })
      if wininfo.winid and wininfo.bufnr then
        vim.wo[wininfo.winid].conceallevel = 2
        vim.wo[wininfo.winid].concealcursor = 'niv'
        vim.treesitter.start(wininfo.bufnr, 'markdown')
      end
    end
  end, bufnr)
end

local function complete_changed(bufnr)
  api.nvim_create_autocmd('CompleteChanged', {
    buffer = bufnr,
    group = group,
    callback = function(args)
      if info_timer and info_timer:is_active() and not info_timer:is_closing() then
        info_timer:close()
      end
      local curitem = vim.v.event.completed_item
      if not curitem then
        return
      end
      local data = vim.fn.complete_info()
      if curitem.info and #curitem.info > 0 and data.preview_winid and data.preview_bufnr then
        vim.wo[data.preview_winid].conceallevel = 2
        vim.wo[data.preview_winid].concealcursor = 'niv'
        vim.treesitter.start(data.preview_bufnr, 'markdown')
        return
      end

      info_timer = uv.new_timer()
      info_timer:start(
        100,
        0,
        vim.schedule_wrap(function()
          show_info(args.buf, curitem, data.selected)
        end)
      )
    end,
  })
end

local function signature_help(client, bufnr, lnum)
  local params = util.make_position_params()
  local fwin, fbuf
  client.request(ms.textDocument_signatureHelp, params, function(err, result, ctx)
    if err or not result or not api.nvim_buf_is_valid(ctx.bufnr) then
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
      border = signature_border,
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

    ---@diagnostic disable-next-line: invisible
    local count = vim.tbl_count(vim.snippet._session.tabstops)
    api.nvim_create_autocmd({ 'CursorMovedI', 'CursorMoved' }, {
      buffer = ctx.bufnr,
      group = g,
      callback = function(args)
        local curline = api.nvim_win_get_cursor(0)[1]
        local is_out = false
        if
          args.event == 'CursorMovedI'
          ---@diagnostic disable-next-line: invisible
          and vim.snippet._session
          ---@diagnostic disable-next-line: invisible
          and vim.snippet._session.current_tabstop.index + 1 == count
        then
          is_out = true
        end
        if (curline ~= lnum and api.nvim_win_is_valid(fwin)) or is_out then
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
          lsp.util.apply_text_edits({ cp_item.textEdit }, bufnr, client.offset_encoding)
          api.nvim_win_set_cursor(
            0,
            { lnum, range['end'].character + #newText + extra - (startidx - range.start.character) }
          )
        end
      elseif cp_item.insertTextFormat == protocol.InsertTextFormat.Snippet then
        offset_snip = cp_item.insertText
      end

      if cp_item.additionalTextEdits then
        lsp.util.apply_text_edits(cp_item.additionalTextEdits, bufnr, client.offset_encoding)
      end

      if offset_snip then
        offset_snip = offset_snip:sub(col - context[args.buf].startidx + 1)
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

local function extend_snippets(ft)
  local fname = vim.fs.joinpath(snippet_path, ('%s.json'):format(ft))
  if not snippet_path or context.snippets[ft] or not uv.fs_stat(fname) then
    return
  end
  local chunks = {}
  uv.fs_open(fname, 'r', 438, function(err, fd)
    assert(not err, err)
    uv.fs_fstat(fd, function(err, stat)
      assert(not err, err)
      uv.fs_read(fd, stat.size, 0, function(err, data)
        assert(not err, err)
        if data then
          chunks[#chunks + 1] = data
        end
        uv.fs_close(fd, function(err)
          assert(not err, err)
          local t = vim.json.decode(table.concat(chunks))
          context.snippets[ft] = {}
          for k, v in pairs(t) do
            local e = {
              label = k,
              insertText = v.body[1],
              kind = 15,
              insertTextFormat = 2,
            }
            table.insert(context.snippets[ft], e)
          end
        end)
      end)
    end)
  end)
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

  for _, item in
    ipairs(vim.list_extend(compitems, context.snippets[vim.bo[ctx.bufnr].filetype] or {}))
  do
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
  end
end

local function debounce(client, bufnr, triggerKind, triggerChar)
  if timer and timer:is_active() then
    timer:close()
    timer:stop()
    timer = nil
  end

  local params = util.make_position_params(api.nvim_get_current_win(), client.offset_encoding)
  params.context = {
    triggerKind = triggerKind,
    triggerCharacter = triggerChar,
  }
  timer = uv.new_timer()
  timer:start(
    debounce_time,
    0,
    vim.schedule_wrap(function()
      client.request(ms.textDocument_completion, params, completion_handler, bufnr)
    end)
  )
end

local function auto_complete(client, bufnr)
  au('TextChangedI', {
    group = group,
    buffer = bufnr,
    callback = function(args)
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
  snippet_path = opt.snippet_path
  signature_border = opt.signature_border or 'rounded'
  kind_format = opt.kind_format or function(k)
    return k:lower():sub(1, 1)
  end
  --make sure your neovim is newer enough
  api.nvim_set_option_value('completeopt', 'menu,menuone,noinsert', { scope = 'global' })

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

      if snippet_path then
        extend_snippets(vim.bo[args.buf].filetype)
      end

      if vim.tbl_contains(opt.compleopt:get(), 'popup') then
        complete_changed(args.buf)
      end
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
}
