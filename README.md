## epo.nvim

Blazing fast and minimal lsp auto-completion plugin for neovim.

**Needs neovim nightly**

**This plugin would be much more feature-complete after [this pr](https://github.com/neovim/neovim/pull/24723) is merged**

## Usage

```lua
vim.opt.completeopt = "menu,menuone,noselect"
require('epo').setup({
    fuzzy = false,
    -- increase this value can aviod trigger complete when delete character.
    debounce = 50,
    -- when completion confrim auto show a signature help floating window.
    signature = false,
    -- extend vscode format snippet json files. like rust.json/typescriptreact.json/zig.json
    snippet_path = nil,
    -- border for lsp signature popup
    signature_border = 'rounded'
    -- lsp kind formatting
    kind_format = opt.kind_format or function(k)
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
<summary>Click to show some preset mappings</summary>

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

- `<cr>` completion

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
