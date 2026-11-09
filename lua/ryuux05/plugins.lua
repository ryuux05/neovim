local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", "https://github.com/folke/lazy.nvim.git", lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({ { "Failed to clone lazy.nvim:\n", "ErrorMsg" }, { out, "WarningMsg" } }, true, {})
    return
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    "iamcco/markdown-preview.nvim",
    build = "cd app && npm install",
    config = function()
      vim.g.mkdp_browserfunc = "OpenMarkdownPreview"
      vim.cmd([[
        function OpenMarkdownPreview(url)
          execute "silent !open -na 'Arc' --args --new-window " . a:url
        endfunction
      ]])
    end,
  },

  {
    "ryuux05/nvmd",
    build = "sh scripts/install-binary.sh",
    config = function()
      require("nvmd").setup({
        live_reload = true,
        debounce_ms = 150,
      })
    end,
  },

  { "nvim-telescope/telescope.nvim", tag = "v0.2.0", dependencies = { "nvim-lua/plenary.nvim" } },

  {
    "rose-pine/neovim",
    name = "rose-pine",
    priority = 1000,
    config = function() vim.cmd("colorscheme rose-pine") end,
  },

  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    lazy = false,
    build = ":TSUpdate",
    config = function() require("ryuux05.treesitter") end,
  },

  {
    "pwntester/octo.nvim",
    commit = "d05b852ad7eba6e34ffe38ee2db430f0fd6f6225", -- pin; no tagged releases
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope.nvim",
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      require("octo").setup {
        picker = "telescope",
        enable_builtin = true,
        default_merge_method = "squash",
        default_delete_branch = false,
        default_to_projects_v2 = true,
        reviews = {
          auto_show_threads = true,
          focus = "right",
        },
        mappings = {
          -- move approve off <leader>qa, it's far too easy to hit
          pull_request = {
            approve_pr = { lhs = "<localleader>qA", desc = "approve PR" },
          },
        },
      }

      vim.treesitter.language.register("markdown", "octo")
      vim.keymap.set("i", "@", "@<C-x><C-o>", { silent = true, buffer = false })

      local map = vim.keymap.set
      map("n", "<leader>op", "<cmd>Octo pr list<cr>",           { desc = "Octo: PRs" })
      map("n", "<leader>or", "<cmd>Octo pr search is:pr is:open review-requested:@me<cr>",
                                                               { desc = "Octo: review requests" })
      map("n", "<leader>oi", "<cmd>Octo issue list<cr>",        { desc = "Octo: issues" })
      map("n", "<leader>on", "<cmd>Octo notification list<cr>", { desc = "Octo: notifications" })
      map("n", "<leader>ov", "<cmd>Octo review start<cr>",      { desc = "Octo: start review" })
    end,
  },

  "theprimeagen/harpoon",
  "mbbill/undotree",
  "tpope/vim-fugitive",

  -- Mason for managing LSP servers
  "neovim/nvim-lspconfig",
  "williamboman/mason.nvim",
  "williamboman/mason-lspconfig.nvim",

  -- Autocompletion
  "hrsh7th/nvim-cmp",
  "hrsh7th/cmp-nvim-lsp",
  "hrsh7th/cmp-buffer",
  "hrsh7th/cmp-path",

  -- Snippets (required for cmp)
  "L3MON4D3/LuaSnip",
  "saadparwaiz1/cmp_luasnip",
}, {
  rocks = { enabled = false },
})
