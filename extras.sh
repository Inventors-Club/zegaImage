#!/usr/bin/env bash
cargo install bob-nvim tree-sitter-cli 
bob install stable
git clone https://github.com/NvChad/starter ~/.config/nvim
sed -i '/require("lazy").setup({/a \  git = { timeout = 300 },\n  concurrency = 1,' ~/.config/nvim/lua/config/lazy.lua
nvim --headless "+Lazy! sync" +MasonInstallAll +TSInstallAll +qa
