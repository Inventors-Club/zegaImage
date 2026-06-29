#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "Run as your regular user (NOT sudo)." >&2
    exit 1
fi

cd "$HOME"
sudo apt-get install -y -o "Acquire::Retries=3" cargo
export PATH="$PATH:$HOME/.cargo/bin"

echo "extras.sh: this will take 30-60 minutes and download multiple GB."
echo "Press Ctrl+C in the next 5 seconds to abort."
sleep 5

cargo install bob-nvim tree-sitter-cli
bob install stable

if [[ -d ~/.config/nvim ]]; then
    mv ~/.config/nvim ~/.config/nvim.bak.$(date +%s)
fi
git clone https://github.com/NvChad/starter ~/.config/nvim
sed -i '/require("lazy").setup({/a \  git = { timeout = 300 },\n  concurrency = 1,' \
    ~/.config/nvim/lua/config/lazy.lua

nvim --headless "+Lazy! sync" +MasonInstallAll +TSInstallAll +qa
