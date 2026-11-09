-- This file can be loaded by calling `lua require('plugins')` from your init.vim

-- Only required if you have packer configured as `opt`
vim.cmd [[packadd packer.nvim]]

return require('packer').startup(function(use)
  -- Packer can manage itself
  use 'wbthomason/packer.nvim'

    use({
      "iamcco/markdown-preview.nvim",
      run = "cd app && npm install",
      config = function()
        vim.g.mkdp_browserfunc = "OpenMarkdownPreview"

        vim.cmd([[
        function OpenMarkdownPreview(url)
          execute "silent !open -na 'Arc' --args --new-window " . a:url
        endfunction
        ]])
      end,
    })

    use {
  "ryuux05/nvmd",
  run = "sh scripts/install-binary.sh",
  config = function()
    require("nvmd").setup({
      live_reload = true,
      debounce_ms = 150,
    })
  end,
}
  use {
	'nvim-telescope/telescope.nvim', tag = 'v0.2.0',
	-- or				, branch = '0.2.x'
	requires = { {'nvim-lua/plenary.nvim'} }
  }

  use ({
	'rose-pine/neovim',
	as = 'rose-pine',
	config = function()
		vim.cmd('colorscheme rose-pine')
	end
  })

use {
  'nvim-treesitter/nvim-treesitter',
  branch = 'main',
  run = ':TSUpdate',
  config = function()
    require('ryuux05.treesitter')
  end
}

use {
  "pwntester/octo.nvim",
  commit = "d05b852ad7eba6e34ffe38ee2db430f0fd6f6225",  -- pin; no tagged releases
  requires = {
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
}

-- use ( 'nvim-treesitter/playground' )
use ( 'theprimeagen/harpoon' )
use ( 'mbbill/undotree' )
use ( 'tpope/vim-fugitive' )

-- Mason for managing LSP servers
use { "neovim/nvim-lspconfig" }
use { 'williamboman/mason.nvim' }
use { 'williamboman/mason-lspconfig.nvim' }

-- Autocompletion
use { 'hrsh7th/nvim-cmp' }
use { 'hrsh7th/cmp-nvim-lsp' }
use { 'hrsh7th/cmp-buffer' }
use { 'hrsh7th/cmp-path' }

-- Snippets (required for cmp)
use { 'L3MON4D3/LuaSnip' }
use { 'saadparwaiz1/cmp_luasnip' }

end)
-- Native LSP config

