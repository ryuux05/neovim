local treesitter = require('nvim-treesitter')

treesitter.setup {}
treesitter.install {
  'c',
  'lua',
  'vim',
  'go',
  'typescript',
  'rust',
  'javascript',
  'markdown',
  'markdown_inline',
}

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('ryuux05_treesitter', { clear = true }),
  callback = function(event)
    local lang = vim.treesitter.language.get_lang(vim.bo[event.buf].filetype)
    if lang and vim.treesitter.language.add(lang) then
      vim.treesitter.start(event.buf, lang)
    end
  end,
})
