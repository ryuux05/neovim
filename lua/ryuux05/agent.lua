vim.opt.autoread = true

local ns = vim.api.nvim_create_namespace("agent_changes")
local root = vim.uv.cwd()
local skip = { "/.git/", "/node_modules/", "/dist/", "/build/", "/target/", "/vendor/" }
local base = {}
local changed = {}
local own = {}
local pending = {}

local function set_hl()
  vim.api.nvim_set_hl(0, "AgentChange", { bg = "#1e3a5f" })
  vim.api.nvim_set_hl(0, "AgentTag", { fg = "#191724", bg = "#9ccfd8", bold = true })
end
set_hl()

local function content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

local function snapshot(buf)
  base[buf] = content(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

local function clear(buf)
  snapshot(buf)
  changed[vim.api.nvim_buf_get_name(buf)] = nil
end

local function mark(buf)
  if not base[buf] then return snapshot(buf) end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local last = vim.api.nvim_buf_line_count(buf)
  for _, h in ipairs(vim.diff(base[buf], content(buf), { result_type = "indices" })) do
    local start, count = h[3], h[4]
    if count == 0 then
      local row = math.min(math.max(start, 1), last) - 1
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { " Agent −" .. h[2] .. " ", "AgentTag" } } })
    else
      for row = start - 1, start + count - 2 do
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "AgentChange" })
      end
      vim.api.nvim_buf_set_extmark(buf, ns, start - 1, 0, { virt_text = { { " Agent ", "AgentTag" } } })
    end
  end
end

-- Changes that leave the file matching HEAD (checkout, pull, reset) come from git, not the agent.
local function classify(path, cb)
  vim.defer_fn(function()
    local repo = vim.fs.root(path, ".git")
    if not repo then return cb(true) end
    if vim.uv.fs_stat(repo .. "/.git/index.lock") then return classify(path, cb) end
    vim.system({ "git", "status", "--porcelain", "--", path }, { cwd = repo, text = true }, vim.schedule_wrap(function(r)
      cb(r.code ~= 0 or r.stdout ~= "")
    end))
  end, 500)
end

local function starts(buf, from)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { from, 0 }, -1, { details = true })) do
    if m[4].virt_text then table.insert(rows, m[2]) end
  end
  return rows
end

local function next_change()
  local cur = vim.api.nvim_get_current_buf()
  local rows = starts(cur, vim.api.nvim_win_get_cursor(0)[1])
  if rows[1] then return vim.api.nvim_win_set_cursor(0, { rows[1] + 1, 0 }) end
  local bufs = vim.api.nvim_list_bufs()
  local i = vim.fn.index(bufs, cur)
  for k = 1, #bufs do
    local buf = bufs[(i + k) % #bufs + 1]
    rows = starts(buf, 0)
    if rows[1] then
      vim.api.nvim_set_current_buf(buf)
      return vim.api.nvim_win_set_cursor(0, { rows[1] + 1, 0 })
    end
  end
  vim.notify("No agent changes")
end

local function pick()
  local files = {}
  for path in pairs(changed) do
    if vim.uv.fs_stat(path) then table.insert(files, vim.fn.fnamemodify(path, ":.")) end
  end
  table.sort(files)
  local conf = require("telescope.config").values
  require("telescope.pickers").new({}, {
    prompt_title = "Agent changes",
    finder = require("telescope.finders").new_table({
      results = files,
      entry_maker = require("telescope.make_entry").gen_from_file({}),
    }),
    sorter = conf.file_sorter({}),
    previewer = conf.file_previewer({}),
  }):find()
end

vim.uv.new_fs_event():start(root, { recursive = true }, vim.schedule_wrap(function(err, file)
  if err or not file then return end
  local path = root .. "/" .. file
  if own[path] then return end
  for _, p in ipairs(skip) do
    if ("/" .. file):find(p, 1, true) then return end
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" or pending[path] then return end
  pending[path] = true
  classify(path, function(agent)
    pending[path] = nil
    changed[path] = agent or nil
  end)
end))

vim.uv.new_timer():start(1000, 1000, vim.schedule_wrap(function()
  if vim.fn.mode() == "c" or vim.fn.getcmdwintype() ~= "" then return end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      vim.cmd("silent! checktime " .. buf)
    end
  end
end))

local group = vim.api.nvim_create_augroup("AgentChanges", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })
vim.api.nvim_create_autocmd("BufReadPost", { group = group, callback = function(a)
  if not base[a.buf] then snapshot(a.buf) end
end })
vim.api.nvim_create_autocmd("FileChangedShellPost", { group = group, callback = function(a)
  classify(vim.api.nvim_buf_get_name(a.buf), function(agent)
    if not vim.api.nvim_buf_is_valid(a.buf) then return end
    if agent then mark(a.buf) else snapshot(a.buf) end
  end)
end })
vim.api.nvim_create_autocmd("BufWritePre", { group = group, callback = function(a)
  own[vim.api.nvim_buf_get_name(a.buf)] = true
end })
vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = function(a)
  local name = vim.api.nvim_buf_get_name(a.buf)
  clear(a.buf)
  vim.defer_fn(function() own[name] = nil end, 1000)
end })
vim.api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(a) base[a.buf] = nil end })

vim.api.nvim_create_user_command("AgentClear", function() clear(vim.api.nvim_get_current_buf()) end, {})
vim.keymap.set("n", "<leader>cc", "<cmd>AgentClear<cr>", { desc = "Clear agent highlights" })
vim.keymap.set("n", "<leader>n", next_change, { desc = "Next agent change" })
vim.keymap.set("n", "<leader>pa", pick, { desc = "Telescope agent changed files" })
