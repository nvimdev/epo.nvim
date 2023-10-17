## Epo

a blazing fast and minimal less than 300 lines. neovim lsp auto-completion plugin from [my pr](https://github.com/neovim/neovim/pull/24661)

need neovim nightly version.

## Usage

invoke it on `on_attach` function like:

```lua
on_attach = function(client, bufnr)
    require('epo').auto_complete(client, bufnr, true or false)
end
```

third param is fuzzy match enable.

## License MIT
