local group = vim.api.nvim_create_augroup("Review", { clear = true })

local function set_hl()
  vim.api.nvim_set_hl(0, "ReviewAdd", { bg = "#1f3d2b" })
  vim.api.nvim_set_hl(0, "ReviewAddText", { bg = "#2e6b44" })
  vim.api.nvim_set_hl(0, "ReviewDel", { bg = "#45212a" })
  vim.api.nvim_set_hl(0, "ReviewDelText", { bg = "#7d2e3b" })
  vim.api.nvim_set_hl(0, "ReviewAsk", { fg = "#9ccfd8", bold = true })
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
local ns = vim.api.nvim_create_namespace("review_ai")
local chats = {}
local panel = { big = false }
local prompt_window

local function current_pr()
  local review = require("octo.reviews").get_current_review()
  return review and review.pull_request.repo .. "#" .. review.pull_request.number
end

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

local function status(chat)
  return chat.busy and "thinking…" or chat.failed and "error" or "done"
end

local function chat_at(buf, line)
  local props, pr = vim.b[buf].octo_diff_props, current_pr()
  if not props then return end
  for i = #chats, 1, -1 do
    local c = chats[i]
    if c.pr == pr and c.side == props.split and c.path == props.path and c.l1 <= line and line <= c.l2 then return c end
  end
end

local function refresh_marks()
  local pr = current_pr()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local props = vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].octo_diff_props
    if props then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      local count = vim.api.nvim_buf_line_count(buf)
      for _, c in ipairs(chats) do
        if c.pr == pr and c.side == props.split and c.path == props.path then
          for l = c.l1, math.min(c.l2, count) do
            vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, {
              sign_text = l == c.l1 and "AI" or "┃",
              sign_hl_group = "ReviewAsk",
              virt_text = l == c.l1 and { { " " .. names[c.agent] .. " · " .. status(c) .. " ", "ReviewAsk" } } or nil,
            })
          end
        end
      end
    end
  end
end

local function panel_open() return panel.win and vim.api.nvim_win_is_valid(panel.win) end

local function panel_config()
  local busy = #vim.tbl_filter(function(c) return c.busy end, chats)
  local config = {
    relative = "editor", width = math.min(60, vim.o.columns - 4), height = 10, footer_pos = "center",
    title = string.format(" AI · %d session%s · %s ", #chats, #chats == 1 and "" or "s", busy > 0 and busy .. " thinking…" or "done"),
    footer = " i ask · ]] [[ jump · m " .. (panel.big and "min" or "max") .. " · q delete · Esc hide ",
  }
  if panel.big then
    config.width, config.height = math.floor(vim.o.columns * 0.8), math.floor(vim.o.lines * 0.8)
    config.row, config.col = math.floor((vim.o.lines - config.height) / 2), math.floor((vim.o.columns - config.width) / 2)
  else
    config.row, config.col = vim.o.lines - config.height - 4, vim.o.columns - config.width - 2
  end
  return config
end

local function chat_in_panel(row)
  for _, c in ipairs(chats) do
    if c.first and c.first <= row and row <= c.last then return c end
  end
end

local function reveal(row)
  if not panel_open() then return end
  vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
  vim.api.nvim_win_call(panel.win, function() vim.cmd("normal! zt") end)
end

local function render()
  local row, keep = panel_open() and vim.api.nvim_win_get_cursor(panel.win)[1]
  keep = row and chat_in_panel(row)
  local offset = keep and row - keep.first
  local lines = {}
  for i, c in ipairs(chats) do
    if i > 1 then table.insert(lines, "") end
    c.first = #lines + 1
    vim.list_extend(lines, { "# " .. names[c.agent] .. " ▸ " .. c.label, "" })
    for _, m in ipairs(c.messages) do
      m.row = #lines + 1
      vim.list_extend(lines, { "## " .. m.role, "" })
      vim.list_extend(lines, vim.split(m.text or "_thinking…_", "\n"))
      table.insert(lines, "")
    end
    c.last = #lines
  end
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  if panel_open() then
    vim.api.nvim_win_set_config(panel.win, panel_config())
    if keep and vim.tbl_contains(chats, keep) then row = keep.first + offset elseif keep then row = keep.first end
    vim.api.nvim_win_set_cursor(panel.win, { math.max(1, math.min(row, #lines)), 0 })
  end
  refresh_marks()
end

local function delete(chat)
  for i, c in ipairs(chats) do
    if c == chat then table.remove(chats, i) break end
  end
  render()
  if #chats == 0 and panel_open() then vim.api.nvim_win_close(panel.win, true) end
end

local function panel_buf()
  if panel.buf and vim.api.nvim_buf_is_valid(panel.buf) then return panel.buf end
  panel.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[panel.buf].filetype = "markdown"
  local function map(lhs, rhs) vim.keymap.set("n", lhs, rhs, { buffer = panel.buf, nowait = true }) end
  map("<Esc>", "<cmd>close<cr>")
  map("m", function()
    panel.big = not panel.big
    vim.api.nvim_win_set_config(panel.win, panel_config())
  end)
  map("q", function()
    local chat = chat_in_panel(vim.fn.line("."))
    if chat then delete(chat) end
  end)
  map("i", function()
    local chat = chat_in_panel(vim.fn.line("."))
    if not chat then return end
    if chat.busy then return vim.notify(names[chat.agent] .. " is still thinking") end
    prompt_window(chat)
  end)
  map("]]", function()
    for _, c in ipairs(chats) do
      if c.first > vim.fn.line(".") then return reveal(c.first) end
    end
  end)
  map("[[", function()
    for i = #chats, 1, -1 do
      if chats[i].first < vim.fn.line(".") then return reveal(chats[i].first) end
    end
  end)
  return panel.buf
end

local function show_panel(focus)
  if not panel_open() then
    panel.win = vim.api.nvim_open_win(panel_buf(), focus, vim.tbl_extend("force", panel_config(), { border = "rounded" }))
    vim.wo[panel.win].wrap = true
    vim.wo[panel.win].linebreak = true
  elseif focus then
    vim.api.nvim_set_current_win(panel.win)
  end
end

local function send(chat, question)
  if not vim.tbl_contains(chats, chat) then table.insert(chats, chat) end
  local reply = { role = names[chat.agent] }
  vim.list_extend(chat.messages, { { role = "You", text = question }, reply })
  chat.busy = true
  show_panel(false)
  render()
  reveal(reply.row)
  run(chat, chat.context and (chat.context .. "\n\nQuestion: " .. question) or question, function(answer, err)
    chat.busy, chat.failed = false, not answer
    if answer then chat.started, chat.context = true, nil end
    reply.text = answer and vim.trim(answer) or ("**Error:** " .. vim.trim(err or "unknown"))
    render()
    if vim.tbl_contains(chats, chat) and vim.api.nvim_get_current_win() ~= panel.win then reveal(reply.row) end
  end)
end

prompt_window = function(chat)
  local buf = vim.api.nvim_create_buf(false, true)
  local new = #chat.messages == 0
  local function title() return " Ask " .. names[chat.agent] .. " ▸ " .. chat.label .. " " end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = math.min(80, vim.o.columns - 4), height = 3,
    border = "rounded", title = title(), footer_pos = "center",
    footer = new and " Tab: Claude/Codex · Enter: send · Esc: cancel " or " Enter: send · Esc: cancel ",
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
  if new then
    vim.keymap.set({ "i", "n" }, "<Tab>", function()
      chat.agent = chat.agent == "claude" and "codex" or "claude"
      vim.api.nvim_win_set_config(win, { title = title() })
    end, { buffer = buf })
  end
end

local function ask(buf, l1, l2)
  local ctx, label = context(buf, l1, l2)
  local props = vim.b[buf].octo_diff_props
  prompt_window({
    agent = "claude", context = ctx, label = label, out = vim.fn.tempname(), messages = {},
    pr = current_pr(), side = props.split, path = props.path, l1 = l1, l2 = l2,
  })
end

vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })

-- Vim colors lines that exist only on the left as DiffAdd, so each side gets its own colors.
vim.api.nvim_create_autocmd("BufWinEnter", { group = group, pattern = "octo://*/review/*/file/*", callback = function(a)
  if a.match:find("/file/LEFT/", 1, true) then
    vim.wo.winhighlight = "DiffAdd:ReviewDel,DiffChange:ReviewDel,DiffText:ReviewDelText"
  else
    vim.wo.winhighlight = "DiffAdd:ReviewAdd,DiffChange:ReviewAdd,DiffText:ReviewAddText"
  end
  local function ask_line() ask(a.buf, vim.fn.line("."), vim.fn.line(".")) end
  local function ask_selection()
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    ask(a.buf, math.min(l1, l2), math.max(l1, l2))
  end
  vim.keymap.set("n", "<CR>", function()
    local chat = chat_at(a.buf, vim.fn.line("."))
    if chat then
      show_panel(true)
      return reveal(chat.first)
    end
    if vim.fn.foldclosed(".") ~= -1 then return vim.cmd("normal! zo") end
    ask_line()
  end, { buffer = a.buf, desc = "Open AI session, expand fold, or ask AI" })
  vim.keymap.set("n", "<S-CR>", ask_line, { buffer = a.buf, desc = "Ask AI" })
  vim.keymap.set("x", "<CR>", ask_selection, { buffer = a.buf, desc = "Ask AI about selection" })
  vim.keymap.set("x", "<S-CR>", ask_selection, { buffer = a.buf, desc = "Ask AI about selection" })
  vim.keymap.set("n", "q", function()
    local chat = chat_at(a.buf, vim.fn.line("."))
    if not chat then return "q" end
    vim.schedule(function() delete(chat) end)
    return ""
  end, { buffer = a.buf, expr = true, desc = "Delete AI session on this line" })
  vim.keymap.set("n", "ga", function()
    if #chats == 0 then return vim.notify("No AI answers yet") end
    show_panel(true)
  end, { buffer = a.buf, desc = "Go to AI answers" })
  refresh_marks()
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
