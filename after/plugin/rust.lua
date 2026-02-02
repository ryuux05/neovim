vim.api.nvim_create_autocmd("FileType", {
  pattern = { "rust" },
  callback = function()
    vim.lsp.start({
      name = "rust-analyzer",
      cmd = { "rust-analyzer" },
      root_dir = vim.fs.root(0, { "Cargo.toml", "rust-project.json", ".git" }),
      settings = {
        ["rust-analyzer"] = {
          diagnostics = {
            disabled = { "unliked-file" },
          },
          checkOnSave = true,
          check = {
            command = "clippy", -- or "check" if you want faster
          },
          cargo = { allFeatures = true },
        },
      },
    })
  end,
})
