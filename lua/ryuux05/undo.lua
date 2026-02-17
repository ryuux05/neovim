-- lua/undo.lua

-- Persistent undo (bounded)
vim.opt.undofile = true
vim.opt.undolevels = 200 -- adjust: 50/200/500

-- Keep undo files in one place
local undo_dir = vim.fn.expand("~/.local/state/nvim/undo//")
vim.fn.mkdir(undo_dir, "p")
vim.opt.undodir = undo_dir

-- Disable persistent undo for big/generated paths
local aug = vim.api.nvim_create_augroup("NoUndoForJunk", { clear = true })

vim.api.nvim_create_autocmd({ "BufNewFile", "BufReadPre" }, {
  group = aug,
  callback = function(args)
    local name = vim.api.nvim_buf_get_name(args.buf)
    if name == "" then return end

    if name:match("/node_modules/")
      or name:match("/dist/")
      or name:match("/build/")
      or name:match("/target/")
      or name:match("/vendor/")
      or name:match("%.log$")
      or name:match("%.min%.js$") then
      vim.bo[args.buf].undofile = false
    end
  end,
})
