-- ~/.config/nvim/after/plugin/mason-lsp.lua
-- Compatible version (no setup_handlers), and avoids trying to treat tools like "stylua" as LSP servers.

require("mason").setup()

local mlsp = require("mason-lspconfig")
mlsp.setup({
  -- LSP servers only (NOT formatters like stylua)
  ensure_installed = { "gopls", "rust_analyzer", "lua_ls" },
})

local capabilities = vim.lsp.protocol.make_client_capabilities()
local ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
if ok then
  capabilities = cmp_lsp.default_capabilities(capabilities)
end


vim.diagnostic.config({
  virtual_text = true,
  signs = true,
  underline = true,
  update_in_insert = false,
  severity_sort = true,
})
