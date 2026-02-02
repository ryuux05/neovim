vim.keymap.set("n", "<leader>gs", vim.cmd.Git)

-- git add .
vim.keymap.set("n", "<leader>ga", function()
    vim.cmd.Git("add .")
end, { desc = "git add ."})

-- git commit
vim.keymap.set("n", "<leader>gc", function()
    local msg = vim.fn.input("Commit messages: ")
    if msg == nil or msg == "" then return end
    vim.cmd.Git('commit -S -m "' ..msg:gsub('"', '\\"') ..'"')
end, { desc = "git commit -S -m" })

-- git push
vim.keymap.set("n", "<leader>gp", function()
    local branch = vim.fn.input("Branch: ")
    if branch == nil or branch == "" then return end
    vim.cmd.Git('push origin "' ..branch:gsub('"', '\\"') ..'"')
end, { desc = "git push origin" })

-- add + commit + push (commit will open the commit message editor)
vim.keymap.set("n", "<leader>gP", function()
    vim.cmd.Git("add .")
    local msg = vim.fn.input("Commit messages: ")
    if msg == nil or msg == "" then return end
    vim.cmd.Git('commit -S -m "' ..msg:gsub('"', '\\"') ..'"')
    vim.cmd.Git("push")
end, { desc = "git add + commit + push" })

-- git branch
vim.keymap.set("n", "<leader>gb", function()
    vim.cmd.Git("branch")
end, { decs = "git branch" })


