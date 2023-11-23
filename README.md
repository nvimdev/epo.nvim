## epo.nvim

Blazing fast and minimal lsp auto-completion plugin for neovim.

**Needs neovim nightly**

## Usage

```lua
require('epo').setup({
    fuzzy = false,
    -- increase this value can aviod trigger complete when delete character.
    debounce = 50,
    -- when completion confrim auto show a signature help floating window.
    signature = false,
    -- extend vscode format snippet json files. like rust.json/typescriptreact.json/zig.json
    snippet_path = nil,
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

## Keymap

Supercharge <kbd>TAB</kbd> and <kbd>Shift-tab</kbd> for completion and snippet expansion.

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

## License MIT
