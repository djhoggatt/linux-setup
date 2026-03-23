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
    -- "github/copilot.vim",
    {
        "andythigpen/nvim-coverage",
        version = "*",
        config = function()
          require("coverage").setup({
            command = true, -- CoverageLoad, CoverageSummary, etc
            auto_reload = true,
          })
        end,
    },
    {
      "hrsh7th/nvim-cmp",
      dependencies = {
        "hrsh7th/cmp-nvim-lsp",
        "hrsh7th/cmp-buffer",
        "hrsh7th/cmp-path",
        "L3MON4D3/LuaSnip",
        "saadparwaiz1/cmp_luasnip",
      },
    },
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

-- Make it pretty
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

-- Fuzzy Finder
local telescope = require("telescope")
local actions = require("telescope.actions")
telescope.setup({
  defaults = {
    history = {
      path = vim.fn.stdpath("data") .. "/telescope_history",
      limit = 100,
    },
    mappings = {
      i = {
        ["<C-Up>"] = actions.cycle_history_prev,
        ["<C-Down>"] = actions.cycle_history_next,
      },
    },
  },
})

-- Remote server
local sock = "/tmp/nvim.sock"

local function is_listening(addr)
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", addr, { rpc = true })
  if not ok or chan == 0 then return false end
  pcall(vim.fn.chanclose, chan)
  return true
end

if vim.uv.fs_stat(sock) and not is_listening(sock) then
  pcall(vim.fn.delete, sock)
end

pcall(vim.fn.serverstart, sock)

-- Auto Completion
local cmp = require("cmp")
local luasnip = require("luasnip")
cmp.setup({
  snippet = {
    expand = function(args) luasnip.lsp_expand(args.body) end,
  },
  mapping = cmp.mapping.preset.insert({
    ["<CR>"] = cmp.mapping.confirm({ select = true }),
    ["<Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then cmp.select_next_item()
      elseif luasnip.expand_or_jumpable() then luasnip.expand_or_jump()
      else fallback() end
    end, { "i", "s" }),
    ["<S-Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then cmp.select_prev_item()
      elseif luasnip.jumpable(-1) then luasnip.jump(-1)
      else fallback() end
    end, { "i", "s" }),
  }),
  sources = {
    { name = "nvim_lsp" },
    { name = "buffer" },
    { name = "path" },
    { name = "luasnip" },
  },
})

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

vim.opt.diffopt:append({
    "vertical",
    "linematch:60",
    "context:99999",
})

----------------------------------- Language Server -----------------------------------------------

vim.lsp.config('luals', {
  cmd = { 'lua-language-server' },
  filetypes = { 'lua' },
  root_markers = { '.luarc.json', '.luarc.jsonc', '.git' },

  settings = {
    Lua = {
      runtime = { version = 'LuaJIT' },
      diagnostics = { globals = { 'vim' } },
      workspace = {
        library = vim.api.nvim_get_runtime_file('', true),
        checkThirdParty = false,
      },
      telemetry = { enable = false },
    },
  },
})

local caps = require("cmp_nvim_lsp").default_capabilities()
caps.offsetEncoding = { "utf-16" }
vim.lsp.config("clangd", {
  cmd = { "clangd", "--background-index", "--clang-tidy", "--completion-style=detailed" },
  filetypes = { "c", "cpp" },
  capabilities = caps,
  autostart = true,
  root_markers = { "compile_commands.json", ".git" },
  root_dir = vim.fs.root(0, {'compile_commands.json'}),
})

vim.lsp.config('zls', {
    cmd = {'zls'},
    filetypes = {'zig'},
    root_markers = {'build.zig'},
})

vim.lsp.config('pyls', {
    cmd = {'pyright'},
    filetypes = {'.py'},
    root_markers = {'.git'},
})

vim.lsp.enable('luals')
vim.lsp.enable('clangd')
vim.lsp.enable('zls')
vim.lsp.enable('pyls')

--vim.cmd('set completeopt=fuzzy,menuone,noselect')

vim.opt.exrc = true

-- clangd isn't properly shut down on exit, so we force stop it and wait a moment
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    local clients = vim.lsp.get_clients({ name = "clangd" })

    -- ask nicely
    for _, c in ipairs(clients) do
      pcall(vim.lsp.stop_client, c.id, true) -- force=true
    end

    -- give Neovim a moment to finish the shutdown RPC
    vim.wait(1000, function()
      return #vim.lsp.get_clients({ name = "clangd" }) == 0
    end, 50)

    -- last resort: kill leftover clangd pids
    for _, c in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
      local pid = c.rpc and c.rpc.pid
      if pid then
        pcall(vim.uv.kill, pid, "sigterm")
        vim.wait(200)
        pcall(vim.uv.kill, pid, "sigkill")
      end
    end
  end,
})

-- Print LSP clients using get_client_by_id() (workaround for get_clients() returning {})
local function lsp_clients_dump(opts)
  opts = opts or {}
  local bufnr = (opts.bufnr ~= nil) and opts.bufnr or vim.api.nvim_get_current_buf()

  local header = ("buf=%d ft=%s file=%s"):format(
    bufnr,
    vim.bo[bufnr].filetype,
    vim.api.nvim_buf_get_name(bufnr)
  )

  local clients = {}

  -- Preferred: enumerate active clients
  if vim.lsp.get_active_clients then
    clients = vim.lsp.get_active_clients()
  end

  -- Fallback: scan client ids (cheap + reliable enough)
  if #clients == 0 then
    for id = 1, 64 do
      local c = vim.lsp.get_client_by_id(id)
      if c then table.insert(clients, c) end
    end
  end

  local lines = { header }

  for _, c in ipairs(clients) do
    local attached = (c.attached_buffers and c.attached_buffers[bufnr]) and true or false
    table.insert(lines, ("- id=%d name=%s attached=%s root=%s pid=%s"):format(
      c.id or -1,
      c.name or "?",
      tostring(attached),
      tostring(c.config and c.config.root_dir),
      tostring(c.rpc and c.rpc.pid)
    ))
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "LSP clients" })
end

vim.api.nvim_create_user_command("LspClients", function(cmdopts)
  local b = tonumber(cmdopts.args)
  lsp_clients_dump({ bufnr = b })
end, { nargs = "?" })
