local group = vim.api.nvim_create_augroup("Review", { clear = true })

local function set_hl()
  vim.api.nvim_set_hl(0, "ReviewAdd", { bg = "#1f3d2b" })
  vim.api.nvim_set_hl(0, "ReviewAddText", { bg = "#2e6b44" })
  vim.api.nvim_set_hl(0, "ReviewDel", { bg = "#45212a" })
  vim.api.nvim_set_hl(0, "ReviewDelText", { bg = "#7d2e3b" })
end
set_hl()

local function browse_when_loaded(buf, tries)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local octo_buf = _G.octo_buffers[buf]
  if octo_buf and octo_buf.node then
    vim.api.nvim_set_current_buf(buf)
    return vim.cmd("Octo review browse")
  end
  if tries == 0 then return vim.notify("Review: PR didn't load", vim.log.levels.ERROR) end
  vim.defer_fn(function() browse_when_loaded(buf, tries - 1) end, 100)
end

local function open(url)
  vim.cmd("Octo " .. url)
  browse_when_loaded(vim.api.nvim_get_current_buf(), 200)
end

local names = { claude = "Claude", codex = "Codex" }

local function context(buf, l1, l2)
  local review = require("octo.reviews").get_current_review()
  local file = review.layout:get_current_file()
  local side = vim.api.nvim_buf_get_name(buf):find("/file/LEFT/", 1, true) and "base version (before the PR)"
    or "PR version (after the change)"
  local numbered = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)) do
    table.insert(numbered, (l1 + i - 1) .. ": " .. line)
  end
  return table.concat({
    string.format("I'm reviewing GitHub pull request %s#%d.", review.pull_request.repo, review.pull_request.number),
    string.format("File %s, lines %d-%d of the %s:", file.path, l1, l2, side),
    "```" .. vim.bo[buf].filetype, table.concat(numbered, "\n"), "```",
    "Full diff of this file in the PR:", "```diff", file.patch or "", "```",
  }, "\n"), file.basename .. ":" .. (l1 == l2 and l1 or l1 .. "-" .. l2)
end

local function run(chat, prompt, cb)
  local cmd
  if chat.agent == "claude" then
    chat.id = chat.id or vim.trim(vim.fn.system("uuidgen")):lower()
    cmd = { "claude", "-p", "--tools", "", chat.started and "--resume" or "--session-id", chat.id }
  elseif chat.started then
    cmd = { "codex", "exec", "resume", "--skip-git-repo-check", "--json", "-c", "sandbox_mode=read-only", "-o", chat.out, chat.id, "-" }
  else
    cmd = { "codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--json", "-o", chat.out, "-" }
  end
  vim.system(cmd, { stdin = prompt, text = true }, vim.schedule_wrap(function(r)
    if chat.agent == "claude" then
      if r.code ~= 0 then return cb(nil, r.stderr ~= "" and r.stderr or r.stdout) end
      return cb(r.stdout)
    end
    local err
    for _, line in ipairs(vim.split(r.stdout, "\n", { trimempty = true })) do
      local ok, ev = pcall(vim.json.decode, line)
      if ok and ev.type == "thread.started" then chat.id = ev.thread_id end
      if ok and (ev.type == "error" or ev.type == "turn.failed") then err = ev.message or ev.error.message end
    end
    if err or vim.fn.filereadable(chat.out) == 0 then return cb(nil, err or r.stderr) end
    cb(table.concat(vim.fn.readfile(chat.out), "\n"))
  end))
end

local prompt_window
local ns = vim.api.nvim_create_namespace("review_ai")
local panel = { busy = 0, big = false }

local function panel_layout()
  local width, height = math.min(60, vim.o.columns - 4), 10
  if panel.big then
    width, height = math.floor(vim.o.columns * 0.8), math.floor(vim.o.lines * 0.8)
    return { row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2), width = width, height = height }
  end
  return { row = vim.o.lines - height - 4, col = vim.o.columns - width - 2, width = width, height = height }
end

local function panel_title()
  local status = panel.busy > 0 and "thinking…" or "done"
  return " " .. names[panel.chat.agent] .. " ▸ " .. panel.chat.label .. " · " .. status .. " "
end

local function panel_open() return panel.win and vim.api.nvim_win_is_valid(panel.win) end

local function show_panel(focus)
  local config = vim.tbl_extend("force", panel_layout(), {
    relative = "editor", title = panel_title(), footer_pos = "center",
    footer = " i: follow-up · m: " .. (panel.big and "minimize" or "maximize") .. " · q: close ",
  })
  if panel_open() then
    vim.api.nvim_win_set_config(panel.win, config)
    if focus then vim.api.nvim_set_current_win(panel.win) end
    return
  end
  panel.win = vim.api.nvim_open_win(panel.buf, focus, vim.tbl_extend("force", config, { border = "rounded" }))
  vim.wo[panel.win].wrap = true
  vim.wo[panel.win].linebreak = true
end

local function panel_buf()
  if panel.buf and vim.api.nvim_buf_is_valid(panel.buf) then return panel.buf end
  panel.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[panel.buf].filetype = "markdown"
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = panel.buf })
  vim.keymap.set("n", "m", function()
    panel.big = not panel.big
    show_panel(true)
  end, { buffer = panel.buf })
  vim.keymap.set("n", "i", function()
    if panel.chat.busy then return vim.notify(names[panel.chat.agent] .. " is still thinking") end
    prompt_window(panel.chat)
  end, { buffer = panel.buf })
  return panel.buf
end

local function send(chat, question)
  local buf = panel_buf()
  local lines = { "## You", "", question, "", "## " .. names[chat.agent], "", "_thinking…_" }
  if not chat.asked then lines = vim.list_extend({ "# " .. names[chat.agent] .. " ▸ " .. chat.label, "" }, lines) end
  local empty = vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, empty and lines or vim.list_extend({ "" }, lines))
  local last = vim.api.nvim_buf_line_count(buf)
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, last - 1, 0, {})
  chat.asked, chat.busy, panel.chat, panel.busy = true, true, chat, panel.busy + 1
  show_panel(false)
  vim.api.nvim_win_set_cursor(panel.win, { last, 0 })
  run(chat, chat.context and (chat.context .. "\n\nQuestion: " .. question) or question, function(answer, err)
    chat.busy, panel.busy = false, panel.busy - 1
    if answer then chat.started, chat.context = true, nil end
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local row = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})[1]
    vim.api.nvim_buf_del_extmark(buf, ns, mark)
    local text = answer and vim.trim(answer) or ("**Error:** " .. vim.trim(err or "unknown"))
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, vim.split(text, "\n"))
    if panel_open() then
      vim.api.nvim_win_set_config(panel.win, { title = panel_title() })
      vim.api.nvim_win_set_cursor(panel.win, { row + 1, 0 })
      vim.api.nvim_win_call(panel.win, function() vim.cmd("normal! zt") end)
    end
  end)
end

prompt_window = function(chat)
  local buf = vim.api.nvim_create_buf(false, true)
  local function title() return " Ask " .. names[chat.agent] .. " ▸ " .. chat.label .. " " end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = math.min(80, vim.o.columns - 4), height = 3,
    border = "rounded", title = title(), footer_pos = "center",
    footer = chat.asked and " Enter: send · Esc: cancel " or " Tab: Claude/Codex · Enter: send · Esc: cancel ",
  })
  vim.wo[win].wrap = true
  vim.cmd.startinsert()
  local function close()
    vim.cmd.stopinsert()
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    local question = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    close()
    if question ~= "" then send(chat, question) end
  end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  vim.keymap.set("n", "q", close, { buffer = buf })
  if not chat.asked then
    vim.keymap.set({ "i", "n" }, "<Tab>", function()
      chat.agent = chat.agent == "claude" and "codex" or "claude"
      vim.api.nvim_win_set_config(win, { title = title() })
    end, { buffer = buf })
  end
end

local function ask(buf, l1, l2)
  local ctx, label = context(buf, l1, l2)
  prompt_window({ agent = "claude", context = ctx, label = label, out = vim.fn.tempname() })
end

vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })

-- Vim colors lines that exist only on the left as DiffAdd, so each side gets its own colors.
vim.api.nvim_create_autocmd("BufWinEnter", { group = group, pattern = "octo://*/review/*/file/*", callback = function(a)
  if a.match:find("/file/LEFT/", 1, true) then
    vim.wo.winhighlight = "DiffAdd:ReviewDel,DiffChange:ReviewDel,DiffText:ReviewDelText"
  else
    vim.wo.winhighlight = "DiffAdd:ReviewAdd,DiffChange:ReviewAdd,DiffText:ReviewAddText"
  end
  vim.keymap.set("n", "<CR>", function()
    if vim.fn.foldclosed(".") ~= -1 then return vim.cmd("normal! zo") end
    ask(a.buf, vim.fn.line("."), vim.fn.line("."))
  end, { buffer = a.buf, desc = "Expand fold or ask AI" })
  vim.keymap.set("x", "<CR>", function()
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    ask(a.buf, math.min(l1, l2), math.max(l1, l2))
  end, { buffer = a.buf, desc = "Ask AI about selection" })
  vim.keymap.set("n", "ga", function()
    if not panel.chat then return vim.notify("No AI answers yet") end
    show_panel(true)
  end, { buffer = a.buf, desc = "Go to AI answers" })
end })

vim.api.nvim_create_autocmd("FileType", { group = group, pattern = "octo_panel", callback = function(a)
  vim.keymap.set("n", "<LeftRelease>", "<LeftRelease><CR>", { buffer = a.buf, remap = true })
end })

vim.api.nvim_create_user_command("Review", function(o) open(o.args) end, { nargs = 1 })

local arg = vim.fn.argv(0)
if vim.fn.argc() == 1 and arg:match("^https://github%.com/[^/]+/[^/]+/pull/%d+") then
  -- Rename the URL buffer so netrw doesn't download the page with curl.
  local placeholder = vim.fn.bufnr(arg)
  vim.api.nvim_buf_set_name(placeholder, "review-loading")
  vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, nested = true, callback = function()
    open(arg)
    vim.api.nvim_buf_delete(placeholder, { force = true })
  end })
end
