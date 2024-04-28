## epo.nvim

Blazingly fast, minimal lsp auto-completion and snippet plugin for neovim.

**Needs neovim nightly**

## Usage

```lua
-- the default completetopt set by epo
vim.opt.completeopt = "menu,menuone,noselect,popup"

-- default settings
require('epo').setup({
    -- fuzzy match
    fuzzy = false,
    -- increase this value can aviod trigger complete when delete character.
    debounce = 50,
    -- when completion confrim auto show a signature help floating window.
    signature = false,
    -- border for lsp signature popup, :h nvim_open_win
    signature_border = 'rounded',
    -- lsp kind formatting, k is kind string "Field", "Struct", "Keyword" etc.
    kind_format = function(k)
      return k:lower():sub(1, 1)
    end
})
```

You may want to pass the capabilities to your lsp

```lua
local capabilities = vim.tbl_deep_extend(
      'force',
      vim.lsp.protocol.make_client_capabilities(),
      require('epo').register_cap()
    )
```

Completion menu look dull and boring? Your colorscheme may be missing these highlights:

```
Pmenu
PmenuExtra
PmenuSel
PmenuKind
PmenuKindSel
PmenuExtraSel
PmenuSbar
PmenuThumb
```

<details>
<summary>Click to show some mapping presets</summary>

- <kbd>TAB</kbd> complete

```lua
vim.keymap.set('i', '<TAB>', function()
  if vim.fn.pumvisible() == 1 then
    return '<C-n>'
  elseif vim.snippet.jumpable(1) then
    return '<cmd>lua vim.snippet.jump(1)<cr>'
  else
    return '<TAB>'
  end
end, { expr = true })

vim.keymap.set('i', '<S-TAB>', function()
  if vim.fn.pumvisible() == 1 then
    return '<C-p>'
  elseif vim.snippet.jumpable(-1) then
    return '<cmd>lua vim.snippet.jump(-1)<CR>'
  else
    return '<S-TAB>'
  end
end, { expr = true })

vim.keymap.set('i', '<C-e>', function()
  if vim.fn.pumvisible() == 1 then
    require('epo').disable_trigger()
  end
  return '<C-e>'
end, {expr = true})
```

- use `<cr>` to accept completion

```lua
-- For using enter as completion, may conflict with some autopair plugin
vim.keymap.set("i", "<cr>", function()
    if vim.fn.pumvisible() == 1 then
        return "<C-y>"
    end
    return "<cr>"
end, { expr = true, noremap = true })

-- nvim-autopair compatibility
vim.keymap.set("i", "<cr>", function()
    if vim.fn.pumvisible() == 1 then
        return "<C-y>"
    end
    return require("nvim-autopairs").autopairs_cr()
end, { expr = true, noremap = true })
```

</details>

## License MIT
