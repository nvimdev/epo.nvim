local api, vfn = vim.api, vim.fn
local protocol = require('vim.lsp.protocol')
local uv = vim.uv
local lsp = vim.lsp
local util = require('vim.lsp.util')
local ms = protocol.Methods
local group = api.nvim_create_augroup('Epo', { clear = true })
local match_fuzzy = false
local debouce_time = 100
local cmp_data = {}

local function buf_data_init(bufnr)
  cmp_data[bufnr] = {
    incomplete = {},
    timer = nil,
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
    cmp_data[ctx.bufnr].incomplete[ctx.client_id] = result.isIncomplete or false
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
  cmp_data[ctx.bufnr].startidx = start_idx
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
    elseif not cmp_data[ctx.bufnr].incomplete then
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

local function complete_ondone(bufnr)
  api.nvim_create_autocmd('CompleteDone', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      local item = vim.v.completed_item
      local completion_item = vim.tbl_get(item, 'user_data', 'nvim', 'lsp', 'completion_item')
      if item.kind == 's' and vim.snippet then
        local before_col = api.nvim_win_get_cursor(0)[2] - 1
        local snippet = completion_item.insertText:sub(before_col - cmp_data[args.buf].startidx + 2)
        vim.snippet.expand(snippet)
      end

      local textedits =
        vim.tbl_get(item, 'user_data', 'nvim', 'lsp', 'completion_item', 'additionalTextEdits')
      if textedits then
        lsp.util.apply_text_edits(textedits, bufnr, 'utf-16')
      end
    end,
  })
end

local function get_documentation(selected, param, bufnr)
  lsp.buf_request(bufnr, ms.completionItem_resolve, param, function(_, result)
    if not vim.tbl_get(result, 'documentation', 'value') then
      return
    end
    local wininfo = api.nvim_complete_set_info(selected, result.documentation.value)
    if not vim.tbl_isempty(wininfo) and wininfo.bufnr and api.nvim_buf_is_valid(wininfo.bufnr) then
      vim.bo[wininfo.bufnr].filetype = 'markdown'
    end
  end)
end

local function show_info(cmp_info, bufnr)
  if not cmp_info.items[cmp_info.selected + 1] then
    return
  end

  local info = vim.tbl_get(cmp_info.items[cmp_info.selected + 1], 'info')
  if not info or #info == 0 then
    local param = vim.tbl_get(
      cmp_info.items[cmp_info.selected + 1],
      'user_data',
      'nvim',
      'lsp',
      'completion_item'
    )
    get_documentation(cmp_info.selected, param, bufnr)
  end
end

local function complete_changed(bufnr)
  api.nvim_create_autocmd('CompleteChanged', {
    buffer = bufnr,
    group = group,
    callback = function(args)
      local cmp_info = vfn.complete_info()
      if cmp_info.selected == -1 then
        return
      end
      local build = vim.version().build
      if build:match('^g') or build:match('dirty') then
        show_info(cmp_info, args.buf)
      end
    end,
  })
end

local function debounce(client, bufnr, triggerKind, triggerChar)
  if not cmp_data[bufnr] then
    return
  end
  if cmp_data[bufnr].timer and cmp_data[bufnr].timer:is_active() then
    cmp_data[bufnr].timer:close()
    cmp_data[bufnr].timer:stop()
    cmp_data[bufnr].timer = nil
  end
  cmp_data[bufnr].timer = uv.new_timer()
  cmp_data[bufnr].timer:start(debouce_time, 0, function()
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
      local col = vfn.charcol('.')
      local line = api.nvim_get_current_line()
      if col == 0 or #line == 0 then
        return
      end
      local triggerKind = lsp.protocol.CompletionTriggerKind.Invoked
      local triggerChar = ''

      local ok, val = pcall(api.nvim_eval, ([['%s' !~ '\k']]):format(line:sub(col - 1, col - 1)))
      if not ok then
        return
      end

      if val ~= 0 then
        local triggerCharacters = client.server_capabilities.completionProvider.triggerCharacters
          or {}
        if not vim.tbl_contains(triggerCharacters, line:sub(col - 1, col - 1)) then
          return
        end
        triggerKind = lsp.protocol.CompletionTriggerKind.TriggerCharacter
        triggerChar = line:sub(col - 1, col - 1)
      end

      if not cmp_data[args.buf] then
        buf_data_init(args.buf)
      end

      debounce(client, args.buf, triggerKind, triggerChar)
    end,
  })

  complete_ondone(bufnr)
  local build = vim.version().build
  if build:match('^g') or build:match('dirty') then
    api.nvim_set_option_value('completeopt', 'menu,noinsert,popup', { scope = 'global' })
  end
  complete_changed(bufnr)
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
  debouce_time = opt.debouce_time or 100

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
        event = { 'TextChangedI', 'CompleteChanged', 'CompleteDone' },
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
