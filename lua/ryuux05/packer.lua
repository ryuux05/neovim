-- This file can be loaded by calling `lua require('plugins')` from your init.vim

-- Only required if you have packer configured as `opt`
vim.cmd [[packadd packer.nvim]]

return require('packer').startup(function(use)
  -- Packer can manage itself
  use 'wbthomason/packer.nvim'

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
  tag = 'v0.9.3',
  run = ':TSUpdate',
  config = function()
    require('nvim-treesitter.configs').setup {
      ensure_installed = { "c", "lua", "vim", "go", "typescript", "rust", "javascript" },
      sync_install = false,
      auto_install = true,
      highlight = {
        enable = true,
      },
    }
  end
}

use ( 'nvim-treesitter/playground' )
use ( 'theprimeagen/harpoon' )
use ( 'mbbill/undotree' )
use ( 'tpope/vim-fugitive' )

-- Mason for managing LSP servers
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

