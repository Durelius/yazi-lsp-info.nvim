# yazi-lsp.nvim

> Export Neovim LSP diagnostics to Yazi file manager

Display LSP diagnostics (errors, warnings) directly in [Yazi](https://github.com/sxyazi/yazi) file manager as file icons.

## Features

- 🔍 Automatic workspace file discovery
- ⚡ Optimized for large codebases (batched file loading)
- 🎯 Multi-LSP support (C++, Go, Rust, TypeScript, etc.)
- 🎨 Configurable diagnostic icons
- 💾 Memory-efficient with configurable limits
- WARNING: NEW PROJECT. Appreciate thoughts and suggestions for improvement!

## Why and what?
This is a nvim plugin that attaches to your LSP servers and parses the files around the current one you're working in, showing the most severe icon and total err/warn count.
It writes the LSP info to a file, that then gets parsed by an additional plugin made for Yazi. This is a plugin I wrote for myself, as I really like Yazi but found no solution. 
Keep in mind this is the first draft, and my first Lua project. Suggestions and ideas for improvement are greatly appreciated.

## Requirements

- Neovim >= 0.9.0
- LSP client configured
- Yazi file manager
- Yazi LSP plugin

## Lazy installation
 
### [lazy.nvim](https://github.com/folke/lazy.nvim)
```lua
return {
  "durelius/yazi-lsp-info.nvim",
}
```
## Installation with all config options
 
```lua
return {
  "durelius/yazi-lsp-info.nvim",
  opts = {
    debug = false,
    enabled = true,
    icons = {
      warning = "🔶",
      error = "🛑",
      info = "ℹ️",
      other = "●",
    },
    memory = {
      max_files = 5000,
      max_lsp_buffer_files = 100,
      files_per_batch = 5,
      debounce_ms = 100,
    },
    files = {
      ignore_types = {
        [".log"] = true,
      },
      ignore_dirs = {
        [".git"] = true,
        ["node_modules"] = true,
        ["build"] = true,
        ["dist"] = true,
        ["target"] = true,
        [".venv"] = true,
        [".cache"] = true,
      },
    },
  },
} --- This is all config options available
```


## Yazi Integration

TODO

The plugin exports diagnostics to `~/.local/share/nvim/yazi_lsp_data.lua`.



## How It Works

1. When LSP attaches, the plugin discovers workspace files
2. Files are loaded in batches to avoid memory issues
3. Diagnostics are collected from all loaded buffers
4. Data is exported to a Lua file for Yazi to consume
5. Updates are debounced to avoid excessive writes

## Troubleshooting

Log file location: `~/.local/share/nvim/yazi_lsp_plugin.log`

### Performance issues

Reduce memory limits:
```lua
require("yazi-lsp").setup({
  memory = {
    max_files = 1000,
    max_lsp_buffer_files = 20,
  }
})
```

## Contributing

Contributions welcome! Please:

1. Fork the repo
2. Create a feature branch
3. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file


Special thanks to the Yazi team.

## Related Projects

- [yazi.nvim](https://github.com/mikavilpas/yazi.nvim) - Yazi integration for Neovim
