local ns = vim.api.nvim_create_namespace("memos")
local file = vim.fn.stdpath("state") .. "/memos.json"
local ok, saved = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(file), "\n")) end)
local memos = ok and saved or {}

local function set_hl()
  vim.api.nvim_set_hl(0, "Memo", { bg = "#a6e3a1", fg = "#191724" })
  vim.api.nvim_set_hl(0, "MemoNote", { fg = "#a3be8c", italic = true })
end
set_hl()

local function is_file(buf)
  return vim.bo[buf].buftype == "" and not vim.api.nvim_buf_get_name(buf):match("^%a+://")
    and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function sync()
  for _, m in ipairs(memos) do
    if m.buf and vim.api.nvim_buf_is_loaded(m.buf) then
      local pos = vim.api.nvim_buf_get_extmark_by_id(m.buf, ns, m.id, { details = true })
      if pos[1] then
        m.l1, m.l2 = pos[1] + 1, pos[3].end_row + 1
        m.text = vim.api.nvim_buf_get_lines(m.buf, pos[1], pos[1] + 1, false)[1]
      end
    end
  end
end

local function save()
  sync()
  local out = {}
  for _, m in ipairs(memos) do
    table.insert(out, { path = m.path, l1 = m.l1, l2 = m.l2, text = m.text, note = m.note })
  end
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(out) }, file)
end

-- The file may have changed while closed, so find the saved first line nearest its old row.
local function place(buf, m, lines)
  local l1
  for i, line in ipairs(lines) do
    if line == m.text and (not l1 or math.abs(i - m.l1) < math.abs(l1 - m.l1)) then l1 = i end
  end
  l1 = l1 or math.min(m.l1, #lines)
  local l2 = math.min(l1 + m.l2 - m.l1, #lines)
  m.buf = buf
  m.id = vim.api.nvim_buf_set_extmark(buf, ns, l1 - 1, 0, {
    end_row = l2 - 1, end_col = #lines[l2], hl_group = "Memo",
    virt_text = m.note ~= "" and { { "  " .. m.note, "MemoNote" } } or nil,
  })
end

local function attach(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, m in ipairs(memos) do
    if m.path == path then place(buf, m, lines) end
  end
end

local function memo_at(buf, row)
  for i, m in ipairs(memos) do
    if m.buf == buf then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, m.id, { details = true })
      if pos[1] and pos[1] <= row and row <= pos[3].end_row then return i end
    end
  end
end

local function add(buf, l1, l2)
  vim.ui.input({ prompt = "Memo note (optional): " }, function(note)
    if not note then return end
    local m = { path = vim.api.nvim_buf_get_name(buf), l1 = l1, l2 = l2, note = note,
      text = vim.api.nvim_buf_get_lines(buf, l1 - 1, l1, false)[1] }
    table.insert(memos, m)
    place(buf, m, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    save()
  end)
end

local function toggle()
  local buf = vim.api.nvim_get_current_buf()
  if not is_file(buf) then return vim.notify("Memos only work in files") end
  local i = memo_at(buf, vim.fn.line(".") - 1)
  if not i then return add(buf, vim.fn.line("."), vim.fn.line(".")) end
  vim.api.nvim_buf_del_extmark(buf, ns, memos[i].id)
  table.remove(memos, i)
  save()
end

local function add_selection()
  local buf = vim.api.nvim_get_current_buf()
  local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  if not is_file(buf) then return vim.notify("Memos only work in files") end
  add(buf, math.min(l1, l2), math.max(l1, l2))
end

local function pick()
  sync()
  local cwd = vim.fn.getcwd() .. "/"
  local results = vim.tbl_filter(function(m) return vim.startswith(m.path, cwd) end, memos)
  if #results == 0 then return vim.notify("No memos in this project") end
  local conf = require("telescope.config").values
  require("telescope.pickers").new({}, {
    prompt_title = "Memos",
    finder = require("telescope.finders").new_table({
      results = results,
      entry_maker = function(m)
        local where = vim.fn.fnamemodify(m.path, ":.") .. ":" .. (m.l1 == m.l2 and m.l1 or m.l1 .. "-" .. m.l2)
        local display = where .. (m.note ~= "" and "  " .. m.note or "") .. "  │ " .. vim.trim(m.text or "")
        return { value = m, display = display, ordinal = display, filename = m.path, lnum = m.l1 }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = conf.grep_previewer({}),
  }):find()
end

local group = vim.api.nvim_create_augroup("Memos", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })
vim.api.nvim_create_autocmd("BufReadPost", { group = group, callback = function(a) attach(a.buf) end })
vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = function(a)
  for _, m in ipairs(memos) do
    if m.buf == a.buf then return save() end
  end
end })

vim.keymap.set("n", "<leader>b", toggle, { desc = "Add or remove memo" })
vim.keymap.set("x", "<leader>b", add_selection, { desc = "Memo selected lines" })
vim.keymap.set("n", "<C-b>", pick, { desc = "Telescope memos" })
