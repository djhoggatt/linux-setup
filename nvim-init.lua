---------------------------------------- Plugins --------------------------------------------------

plugins = {
    {
        'nvim-telescope/telescope.nvim',
        branch = '0.1.x',
        dependencies = { 'nvim-lua/plenary.nvim' },
    },
    {
        "nvim-treesitter/nvim-treesitter",
        branch = "master",
        lazy = false,
        build = ":TSUpdate"
    },
    {
        "ThePrimeagen/harpoon",
        branch = "harpoon2",
        dependencies = { "nvim-lua/plenary.nvim" }
    },
    "mbbill/undotree",
    "rose-pine/neovim",
    {
        "rbong/vim-flog",
        lazy = true,
        cmd = { "Flog", "Flogsplit", "Floggit" },
        dependencies = {
            "tpope/vim-fugitive",
        },
    },
    "github/copilot.vim",
    "neovim/nvim-lspconfig",
}

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- Make sure to setup `mapleader` and `maplocalleader` before
-- loading lazy.nvim so that mappings are correct.
-- This is also a good place to setup other settings (vim.opt)
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Setup lazy.nvim
require("lazy").setup({
  spec = plugins,
  -- Configure any other settings here. See the documentation for more details.
  -- colorscheme that will be used when installing plugins.
  install = { colorscheme = { "habamax" } },
  -- do not automatically check for plugin updates
  checker = { enabled = false },
})

------------------------------------------ Setup --------------------------------------------------

require('nvim-treesitter.configs').setup {
    ensure_installed = { "c", 
                         "lua", 
                         "vim", 
                         "vimdoc", 
                         "query", 
                         "markdown",
                         "markdown_inline", 
                         "python", 
                         "zig" },
    sync_install = false,
    auto_install = true,
    highlight = {
        enable = true,
        additional_vim_regex_highlighting = false,
    },
}

vim.cmd.colorscheme("rose-pine")
vim.api.nvim_set_hl(0, "Normal", { bg = "none" })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "none" })

------------------------------------- Key Remappings ----------------------------------------------

vim.keymap.set("i", "<C-v>", "<C-r>+", { noremap = true, silent = true })
vim.keymap.set("n", "<C-c>", '"+y', { noremap = true, silent = true })

local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>ff', builtin.find_files, { desc = 'Telescope find files' })
vim.keymap.set('n', '<leader>fg', builtin.live_grep, { desc = 'Telescope live grep' })
vim.keymap.set('n', '<leader>fb', builtin.buffers, { desc = 'Telescope buffers' })
vim.keymap.set('n', '<leader>fh', builtin.help_tags, { desc = 'Telescope help tags' })
vim.keymap.set('n', '<leader>gf', builtin.git_files, { desc = 'Telescope find git files' })

local harpoon = require("harpoon")
harpoon:setup()
vim.keymap.set("n", "<leader>hh", function() harpoon:list():add() end)
vim.keymap.set("n", "<leader>hl", function() harpoon.ui:toggle_quick_menu(harpoon:list()) end)
vim.keymap.set("n", "<leader>1", function() harpoon:list():select(1) end)
vim.keymap.set("n", "<leader>2", function() harpoon:list():select(2) end)
vim.keymap.set("n", "<leader>3", function() harpoon:list():select(3) end)
vim.keymap.set("n", "<leader>4", function() harpoon:list():select(4) end)
vim.keymap.set("n", "<leader>5", function() harpoon:list():select(5) end)
vim.keymap.set("n", "<leader>6", function() harpoon:list():select(6) end)
vim.keymap.set("n", "<leader>7", function() harpoon:list():select(7) end)
vim.keymap.set("n", "<leader>8", function() harpoon:list():select(8) end)
vim.keymap.set("n", "<leader>9", function() harpoon:list():select(9) end)
vim.keymap.set("n", "<leader>hn", function() harpoon:list():prev() end)
vim.keymap.set("n", "<leader>hp", function() harpoon:list():next() end)

vim.keymap.set('n', '<leader>u', vim.cmd.UndotreeToggle)

vim.keymap.set({'x', 'n'}, 'y', '"+y', {silent = true})

vim.keymap.set('n', '<C-q>', '<C-v>', { noremap = true })
vim.keymap.set('x', '<C-q>', '<C-v>', { noremap = true })

---------------------------------------- Settings -------------------------------------------------

vim.opt.modelines = 0
vim.opt.number = true
vim.opt.encoding = 'utf-8'
vim.opt.wrap = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4
vim.opt.expandtab = true
vim.opt.autoindent = true
vim.opt.copyindent = true
vim.opt.shiftround = false
vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.showmatch = true
vim.opt.smartcase = true
vim.opt.visualbell = true
vim.opt.laststatus = 2
vim.opt.showcmd = true
vim.opt.undolevels = 50
vim.opt.undofile = true
vim.opt.backup = false
vim.opt.swapfile = false

local undo_dir = (os.getenv("HOME") or "") .. "/.config/nvim/undo"
if vim.fn.isdirectory(undo_dir) == 0 then
  vim.fn.mkdir(undo_dir, "p")
end
vim.opt.undodir = undo_dir

----------------------------------- Language Server -----------------------------------------------

--vim.lsp.config('luals', {
--    cmd = {'lua-language-server'},
--    filetypes = {'lua'},
--    root_markers = {'.luarc.json', '.luarc.jsonc'},
--})

vim.lsp.config('clangd', {
    cmd = { 'clangd' },
  -- filetypes = { 'c', 'cpp' },
  -- root_markers = { 'compile_commands.json' },
  -- root_dir = function(_) return vim.fn.getcwd() end,
})

--vim.lsp.config('zls', {
--    cmd = {'zls'},
--    filetypes = {'zig'},
--    root_markers = {'build.zig'},
--})

--vim.lsp.config('pyls', {
--    cmd = {'pyright'},
--    filetypes = {'.py'},
--    root_markers = {'.git'},
--})

--vim.lsp.enable('luals')
vim.lsp.enable('clangd')
--vim.lsp.enable('zls')
--vim.lsp.enable('pyls')

--vim.cmd('set completeopt=fuzzy,menuone,noselect')

--vim.api.nvim_create_autocmd('LspAttach', {
--    group = vim.api.nvim_create_augroup('lsp', {}),
--    callback = function(args)
--        local clientID = args.data.client_id
--        vim.lsp.completion.enable(true, clientID, 0, { autotrigger = true })
--    end,
--})

--vim.keymap.set('i', '<C-n>', function()
--    vim.lsp.completion.get()
--end)
--
--vim.lsp.set_log_level("debug")
vim.opt.exrc = true
