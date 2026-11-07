-- Run: nvim --headless -u NONE -i NONE -l tests/agent_navigation.lua
local config = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(config)
vim.g.mapleader = " "
require("ryuux05.agent")

local function buffer(lines, changes)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace("agent_changes")
  for _, row in ipairs(changes) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { " Agent ", "AgentTag" } } })
  end
  return buf
end

local current = buffer({ "1", "2", "3", "4", "5", "6", "7", "8" }, { 1, 4 })
buffer({ "other file" }, { 0 })
vim.api.nvim_set_current_buf(current)
local next_change = vim.fn.maparg(" n", "n", false, true).callback
for _, row in ipairs({ 2, 5, 2, 5 }) do
  next_change()
  assert(vim.api.nvim_get_current_buf() == current, "Must stay in the current file")
  assert(vim.api.nvim_win_get_cursor(0)[1] == row, "Must wrap within the current file")
end
local empty = buffer({ "no changes" }, {})
vim.api.nvim_set_current_buf(empty)
next_change()
assert(vim.api.nvim_get_current_buf() == empty, "An unchanged file must not jump to another file")
print("PASS: next agent change wraps within the current file")
