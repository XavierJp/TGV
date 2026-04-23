FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tools — everything baked in so containers start fast
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    git-delta \
    build-essential \
    python3 \
    curl \
    wget \
    unzip \
    ca-certificates \
    zsh \
    neovim \
    fzf \
    bat \
    fd-find \
    ripgrep \
    tree \
    locales \
    sudo \
    ncurses-term \
    bubblewrap \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# abduco: Ubuntu 24.04 dropped the package, so build from the upstream v0.6
# tarball (single C file, near-instant compile). `make install PREFIX=/usr`
# drops the binary at /usr/bin/abduco.
#
# The sed patch strips the two lines in client.c that emit `\e[?1049h` /
# `\e[?1049l` — abduco-client unconditionally enters the terminal's alternate
# screen on attach. That broke codex scrollback because alt-screen content
# never lands in SwiftTerm's scrollback buffer. After the patch abduco is
# fully pass-through and codex's inline rendering flows into scrollback.
RUN curl -fsSL https://github.com/martanne/abduco/archive/refs/tags/v0.6.tar.gz -o /tmp/abduco.tar.gz \
    && tar -xzf /tmp/abduco.tar.gz -C /tmp \
    && sed -i '/1049[hl]/d' /tmp/abduco-0.6/client.c \
    && make -C /tmp/abduco-0.6 \
    && make -C /tmp/abduco-0.6 install PREFIX=/usr \
    && rm -rf /tmp/abduco-0.6 /tmp/abduco.tar.gz

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Node.js 23
RUN curl -fsSL https://deb.nodesource.com/setup_23.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm \
    && rm -rf /var/lib/apt/lists/*

# uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && cp -L /root/.local/bin/uv /usr/local/bin/uv \
    && chmod 755 /usr/local/bin/uv

# OpenAI Codex CLI
RUN npm install -g @openai/codex

# rtk (Rust Token Killer)
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh \
    && cp -L /root/.local/bin/rtk /usr/local/bin/rtk \
    && chmod 755 /usr/local/bin/rtk

# System-wide git config: use delta as the pager for diff/log/show.
RUN cat > /etc/gitconfig << 'GITEOF'
[core]
    pager = delta
[interactive]
    diffFilter = delta --color-only
[delta]
    navigate = true
    line-numbers = true
    hyperlinks = false
[merge]
    conflictstyle = zdiff3
GITEOF

# tgv-diff: open nvim in diff mode against the HEAD version of the file.
# nvim blocks until the user quits, so mosh keeps the session alive
# (unlike a pager pipeline which auto-exits on short diffs).
RUN cat > /usr/local/bin/tgv-diff << 'DIFFEOF' && chmod 755 /usr/local/bin/tgv-diff
#!/bin/sh
cd /workspace/repo
head_copy=$(mktemp)
trap 'rm -f "$head_copy"' EXIT
if git show "HEAD:$1" > "$head_copy" 2>/dev/null; then
    nvim -d -R "$head_copy" "$1"
else
    nvim "$1"
fi
DIFFEOF

# Non-root dev user with sudo
RUN useradd -m -s /bin/zsh -G sudo dev && \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Oh My Zsh + plugins for dev
USER dev
ENV HOME=/home/dev
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended && \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# rtk integration with Codex (writes AGENTS.md + RTK.md into ~/.codex)
RUN rtk init -g --codex

# Minimal zsh theme: branch ❯
RUN cat > /home/dev/.oh-my-zsh/custom/themes/tgv.zsh-theme << 'THEMEEOF'
function _git_branch() {
  local ref=$(git symbolic-ref --short HEAD 2>/dev/null)
  [[ -n "$ref" ]] && echo "%F{cyan}${ref}%f "
}
PROMPT='$(_git_branch)%F{magenta}❯%f '
RPROMPT=''
THEMEEOF

# .zshrc
RUN cat > /home/dev/.zshrc << 'ZSHEOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="tgv"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh

export EDITOR='nvim'
export LANG=en_US.UTF-8
export COLORTERM=truecolor
export PATH="$HOME/.local/bin:$PATH"

alias vim='nvim'
alias ll='ls -la --color=auto'
command -v batcat &>/dev/null && alias cat='batcat --paging=never'
command -v fdfind &>/dev/null && alias fd='fdfind'
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
ZSHEOF

# Neovim config with lazy.nvim + Tokyo Night + lualine (plugins downloaded at build time)
RUN mkdir -p /home/dev/.config/nvim && cat > /home/dev/.config/nvim/init.lua << 'NVIMEOF'
-- Bootstrap lazy.nvim (already cloned at build time)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- Options
local opt = vim.opt
opt.number = true
opt.relativenumber = true
opt.tabstop = 2
opt.shiftwidth = 2
opt.expandtab = true
opt.smartindent = true
opt.termguicolors = true
opt.signcolumn = "yes"
opt.wrap = false
opt.scrolloff = 10
opt.sidescrolloff = 8
opt.ignorecase = true
opt.smartcase = true
opt.clipboard = "unnamedplus"
opt.mouse = "a"
opt.undofile = true
opt.inccommand = "split"
opt.list = true
opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
opt.cursorline = true
opt.splitbelow = true
opt.splitright = true
opt.showmode = false
opt.updatetime = 250
opt.timeoutlen = 300
opt.fillchars = { eob = " " }
opt.pumheight = 10
opt.laststatus = 3

-- Leader
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Plugins (all pre-installed, no network needed at runtime)
require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      style = "night",
      transparent = false,
      styles = {
        comments = { italic = true },
        keywords = { italic = true },
      },
    },
    config = function(_, opts)
      require("tokyonight").setup(opts)
      vim.cmd.colorscheme("tokyonight")
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = {
      options = {
        theme = "tokyonight",
        component_separators = { left = "│", right = "│" },
        section_separators = { left = "", right = "" },
        globalstatus = true,
      },
      sections = {
        lualine_a = { { "mode", fmt = function(s) return s:sub(1, 1) end } },
        lualine_b = { "branch" },
        lualine_c = {
          { "filename", path = 1, symbols = { modified = " ●", readonly = " ", unnamed = "[No Name]" } },
        },
        lualine_x = { "diagnostics" },
        lualine_y = { "filetype" },
        lualine_z = { "%l:%c" },
      },
      inactive_sections = {
        lualine_c = { { "filename", path = 1 } },
        lualine_x = { "%l:%c" },
      },
    },
  },
}, {
  lockfile = vim.fn.stdpath("data") .. "/lazy-lock.json",
  performance = { rtp = { disabled_plugins = { "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin" } } },
})

-- Keymaps
local map = vim.keymap.set
map("n", "<leader>w", "<cmd>w<CR>", { desc = "Save" })
map("n", "<leader>q", vim.diagnostic.setloclist, { desc = "Diagnostic quickfix" })
map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })

-- Window navigation
map("n", "<C-h>", "<C-w>h", { desc = "Go to left window" })
map("n", "<C-j>", "<C-w>j", { desc = "Go to lower window" })
map("n", "<C-k>", "<C-w>k", { desc = "Go to upper window" })
map("n", "<C-l>", "<C-w>l", { desc = "Go to right window" })

-- Move lines
map("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move line down" })
map("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move line up" })

-- Better indenting (stay in visual mode)
map("v", "<", "<gv")
map("v", ">", ">gv")

-- Buffer navigation
map("n", "<S-h>", "<cmd>bprevious<CR>", { desc = "Prev buffer" })
map("n", "<S-l>", "<cmd>bnext<CR>", { desc = "Next buffer" })

-- Diagnostics
vim.diagnostic.config({
  float = { border = "rounded" },
  severity_sort = true,
  virtual_text = {
    spacing = 4,
    source = "if_many",
    prefix = "●",
  },
})

-- Highlight on yank
vim.api.nvim_create_autocmd("TextYankPost", {
  group = vim.api.nvim_create_augroup("highlight-yank", { clear = true }),
  callback = function() vim.highlight.on_yank({ timeout = 200 }) end,
})
NVIMEOF

# Pre-install lazy.nvim + plugins during build (network available here)
RUN git clone --filter=blob:none --branch=stable \
      https://github.com/folke/lazy.nvim.git \
      /home/dev/.local/share/nvim/lazy/lazy.nvim && \
    nvim --headless "+Lazy! sync" +qa 2>/dev/null || true

USER root
WORKDIR /workspace

# Repo COPY + dependency install are appended by `tgv-init` when building
# the per-project image (the same Dockerfile is reused as a base).
