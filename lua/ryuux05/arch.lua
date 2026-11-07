local ask = require("ryuux05.ask")

vim.api.nvim_create_user_command("Arch", function(o)
  local file = o.args
  if file == "" then
    file = vim.bo.filetype == "markdown" and vim.fn.expand("%") ~= "" and vim.fn.expand("%") or "docs/architecture.md"
  end
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  vim.cmd.tabedit(vim.fn.fnameescape(file))
  ask.dock()
  pcall(vim.cmd, "MarkdownPreview")
end, { nargs = "?", complete = "file", desc = "Architecture notes with docked AI panel and preview" })
