local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>pf', function() 
    builtin.find_files({ previewer = true }) 
end, { desc = 'Telescope find files' })
vim.keymap.set('n', '<C-p>', builtin.git_files, { desc = 'Telescope find git files' })
vim.keymap.set('n', '<leader>ps', function()
	builtin.grep_string({ search = vim.fn.input("Grep > ") });
end, { desc = 'Telescope file search' })

