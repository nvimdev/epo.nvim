## Epo

a blazing fast and minimal less than 300 lines. neovim lsp auto-completion plugin.

**Need neovim nightly**


## Usage

```lua
require('epo').setup({})
```

register capabilities for `vim.snippet`

```lua
server_config = {
    capabilities = vim.tbl_deep_extend(
      'force',
      vim.lsp.protocol.make_client_capabilities(),
      require('epo').register_cap()
    )
}
```


third param is fuzzy match enable.

## License MIT
