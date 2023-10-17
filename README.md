## Epo

a blazing fast neovim lsp auto-completion plugin

## Usage

invoke it on `on_attach` function like:

```lua
on_attach = function(client, bufnr)
    require('epo').auto_complete(client, bufnr, true or false)
end
```

third param is fuzzy match enable.

## License MIT
