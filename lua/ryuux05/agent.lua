vim.opt.autoread = true

local ns = vim.api.nvim_create_namespace("agent_changes")
local root = vim.uv.cwd()
local skip = { "/.git/", "/node_modules/", "/dist/", "/build/", "/target/", "/vendor/" }
local base = {}
local changed = {}
local own = {}
local pending = {}
local seen = {}
local reloading = {}

local function stamp(buf)
  local stat = vim.uv.fs_stat(vim.api.nvim_buf_get_name(buf))
  if not stat or stat.type ~= "file" then return end
  return table.concat({ stat.ino, stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
end

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
  seen[buf] = stamp(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

local function reload(buf)
  if reloading[buf] or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then return end
  local autoread = vim.bo[buf].autoread
  if autoread == nil then autoread = vim.go.autoread end
  if vim.bo[buf].modified or not autoread then return end
  if vim.fn.mode():match("^[cr]") or vim.fn.getcmdwintype() ~= "" then return end
  local current = stamp(buf)
  if not current or current == seen[buf] then return end
  local views = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  end
  reloading[buf] = true
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    -- checktime can defer checks and asks to load newly created files even
    -- with autoread. Only clean buffers reach this immediate native reload.
    vim.cmd("silent keepalt keepjumps edit!")
  end)
  reloading[buf] = nil
  if not ok then return vim.notify(tostring(err), vim.log.levels.ERROR) end
  seen[buf] = stamp(buf)
  for win, view in pairs(views) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
    end
  end
  vim.api.nvim_exec_autocmds("FileChangedShellPost", { buffer = buf })
  vim.cmd.redraw()
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
  if not rows[1] then rows = starts(cur, 0) end
  if rows[1] then return vim.api.nvim_win_set_cursor(0, { rows[1] + 1, 0 }) end
  vim.notify("No agent changes in this buffer")
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
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 then reload(buf) end
  pending[path] = true
  classify(path, function(agent)
    pending[path] = nil
    changed[path] = agent or nil
  end)
end))

vim.uv.new_timer():start(250, 250, vim.schedule_wrap(function()
  local checked = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if not checked[buf] then reload(buf); checked[buf] = true end
    end
  end
end))

local group = vim.api.nvim_create_augroup("AgentChanges", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, { group = group, callback = function(a)
  if not base[a.buf] then snapshot(a.buf) end
  seen[a.buf] = stamp(a.buf)
end })
vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, { group = group, callback = function(a) reload(a.buf) end })
vim.api.nvim_create_autocmd("FileChangedShellPost", { group = group, callback = function(a)
  classify(vim.api.nvim_buf_get_name(a.buf), function(agent)
    if not vim.api.nvim_buf_is_valid(a.buf) then return end
    if agent then mark(a.buf) else snapshot(a.buf) end
    vim.cmd.redraw()
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
vim.api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(a)
  base[a.buf], seen[a.buf], reloading[a.buf] = nil, nil, nil
end })

vim.api.nvim_create_user_command("AgentClear", function() clear(vim.api.nvim_get_current_buf()) end, {})
vim.keymap.set("n", "<leader>cc", "<cmd>AgentClear<cr>", { desc = "Clear agent highlights" })
vim.keymap.set("n", "<leader>n", next_change, { desc = "Next agent change" })
vim.keymap.set("n", "<leader>pa", pick, { desc = "Telescope agent changed files" })
