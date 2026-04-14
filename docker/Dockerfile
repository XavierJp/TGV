FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tools — everything baked in so containers start fast
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    python3 \
    curl \
    wget \
    unzip \
    ca-certificates \
    zsh \
    neovim \
    tmux \
    fzf \
    bat \
    fd-find \
    ripgrep \
    tree \
    locales \
    sudo \
    ncurses-term \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

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

# OpenCode
RUN curl -fsSL https://raw.githubusercontent.com/anomalyco/opencode/refs/heads/dev/install | bash \
    && cp -L /root/.opencode/bin/opencode /usr/local/bin/opencode \
    && chmod 755 /usr/local/bin/opencode

# tgv-diff: open codediff.nvim for a file against HEAD
RUN printf '#!/bin/sh\nnvim -c "CodeDiff" -- "$1"\n' > /usr/local/bin/tgv-diff && \
    chmod 755 /usr/local/bin/tgv-diff

# Non-root dev user with sudo
RUN useradd -m -s /bin/zsh -G sudo dev && \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Oh My Zsh + plugins for dev
USER dev
ENV HOME=/home/dev
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended && \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

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

# tmux config — used by `tmux new-session -A -s tgv` from the TGV app
RUN cat > /home/dev/.tmux.conf << 'TMUXEOF'
set -g status off
set -g mouse on
set -g history-limit 50000
set -g default-terminal "xterm-256color"
set -ga terminal-overrides ",*256col*:Tc"
set -g set-clipboard on
bind-key -n C-q detach
TMUXEOF

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
  {
    "esmuellert/codediff.nvim",
    cmd = { "CodeDiff" },
    opts = {},
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
