local M = {}

local group = vim.api.nvim_create_augroup("Ask", { clear = true })
local anchors = vim.api.nvim_create_namespace("ask_anchor")
local marks = vim.api.nvim_create_namespace("ask_marks")
local names = { claude = "Claude", codex = "Codex" }
local chats = {}
local snaps = {}
local panel = { big = false, wins = {} }
local prompt_window

local function set_hl()
  vim.api.nvim_set_hl(0, "AskMark", { fg = "#9ccfd8", bold = true })
end
set_hl()

local function content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

function M.numbered(buf, l1, l2)
  local out = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)) do
    table.insert(out, (l1 + i - 1) .. ": " .. line)
  end
  return "```" .. vim.bo[buf].filetype .. "\n" .. table.concat(out, "\n") .. "\n```"
end

function M.label(path, l1, l2)
  return vim.fn.fnamemodify(path, ":t") .. ":" .. (l1 == l2 and l1 or l1 .. "-" .. l2)
end

local function command(chat, mode)
  local edit = mode == "edit"
  local tools = chat.review and "" or edit and "Read,Grep,Glob,Edit,Write" or "Read,Grep,Glob"
  local sandbox = edit and "workspace-write" or "read-only"
  if chat.agent == "claude" then
    chat.id = chat.id or vim.trim(vim.fn.system("uuidgen")):lower()
    local cmd = { "claude", "-p", "--tools", tools, chat.started and "--resume" or "--session-id", chat.id }
    if edit then vim.list_extend(cmd, { "--permission-mode", "acceptEdits" }) end
    return cmd
  elseif chat.started then
    return { "codex", "exec", "resume", "--skip-git-repo-check", "--json", "-c", "sandbox_mode=" .. sandbox, "-o", chat.out, chat.id, "-" }
  end
  return { "codex", "exec", "--sandbox", sandbox, "--skip-git-repo-check", "--json", "-o", chat.out, "-" }
end

local function run(chat, mode, prompt, cb)
  vim.system(command(chat, mode), { stdin = prompt, text = true, cwd = chat.cwd }, vim.schedule_wrap(function(r)
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
  if chat.busy then return chat.busy == "edit" and "editing…" or "thinking…" end
  return chat.failed and "error" or "done"
end

local function chat_at(buf, line)
  for i = #chats, 1, -1 do
    local l1, l2 = chats[i].range(buf)
    if l1 and l1 <= line and line <= l2 then return chats[i] end
  end
end

local function refresh()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].ask_attached then
      vim.api.nvim_buf_clear_namespace(buf, marks, 0, -1)
      local count = vim.api.nvim_buf_line_count(buf)
      for _, c in ipairs(chats) do
        local l1, l2 = c.range(buf)
        for l = l1 or 1, l1 and math.min(l2, count) or 0 do
          vim.api.nvim_buf_set_extmark(buf, marks, l - 1, 0, {
            sign_text = l == l1 and "AI" or "┃",
            sign_hl_group = "AskMark",
            virt_text = l == l1 and { { " " .. names[c.agent] .. " · " .. status(c) .. " ", "AskMark" } } or nil,
          })
        end
      end
    end
  end
end

local function panel_win()
  local win = panel.wins[vim.api.nvim_get_current_tabpage()]
  return win and vim.api.nvim_win_is_valid(win) and win or nil
end

local function is_float(win) return vim.api.nvim_win_get_config(win).relative ~= "" end

local function panel_title()
  local busy = #vim.tbl_filter(function(c) return c.busy end, chats)
  return string.format(" AI · %d session%s · %s ", #chats, #chats == 1 and "" or "s", busy > 0 and busy .. " working…" or "done")
end

local function panel_config()
  local config = {
    relative = "editor", width = math.min(60, vim.o.columns - 4), height = 10, footer_pos = "center",
    title = panel_title(),
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

local function update_panel(win)
  -- Window options follow the buffer, so a float would inherit the docked panel's winbar.
  local float = is_float(win)
  vim.wo[win][0].winbar = float and "" or panel_title() .. "│ i ask · ]] [[ jump · q delete · Esc hide"
  if float then vim.api.nvim_win_set_config(win, panel_config()) end
end

local function chat_in_panel(row)
  for _, c in ipairs(chats) do
    if c.first and c.first <= row and row <= c.last then return c end
  end
end

local function reveal(row)
  local win = panel_win()
  if not win then return end
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  vim.api.nvim_win_call(win, function() vim.cmd("normal! zt") end)
end

local function render()
  local win = panel_win()
  local row = win and vim.api.nvim_win_get_cursor(win)[1]
  local keep = row and chat_in_panel(row)
  local offset = keep and row - keep.first
  local lines = {}
  for i, c in ipairs(chats) do
    if i > 1 then table.insert(lines, "") end
    c.first = #lines + 1
    vim.list_extend(lines, { "# " .. names[c.agent] .. " ▸ " .. c.label, "" })
    for _, m in ipairs(c.messages) do
      m.row = #lines + 1
      vim.list_extend(lines, { "## " .. m.role, "" })
      vim.list_extend(lines, vim.split(m.text or "_working…_", "\n"))
      table.insert(lines, "")
    end
    c.last = #lines
  end
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  for _, w in pairs(panel.wins) do
    if vim.api.nvim_win_is_valid(w) then update_panel(w) end
  end
  if win then
    if keep and vim.tbl_contains(chats, keep) then row = keep.first + offset elseif keep then row = keep.first end
    vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(row, #lines)), 0 })
  end
  refresh()
end

local function delete(chat)
  for i, c in ipairs(chats) do
    if c == chat then table.remove(chats, i) break end
  end
  if chat.forget then chat.forget() end
  render()
  local win = panel_win()
  if #chats == 0 and win and is_float(win) then vim.api.nvim_win_close(win, true) end
end

local function panel_buf()
  if panel.buf and vim.api.nvim_buf_is_valid(panel.buf) then return panel.buf end
  panel.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[panel.buf].filetype = "markdown"
  local function map(lhs, rhs) vim.keymap.set("n", lhs, rhs, { buffer = panel.buf, nowait = true }) end
  map("<Esc>", "<cmd>close<cr>")
  map("m", function()
    local win = panel_win()
    if not win or not is_float(win) then return end
    panel.big = not panel.big
    update_panel(win)
  end)
  map("q", function()
    local chat = chat_in_panel(vim.fn.line("."))
    if chat then delete(chat) end
  end)
  map("i", function()
    local chat = chat_in_panel(vim.fn.line("."))
    if not chat then return end
    if chat.busy then return vim.notify(names[chat.agent] .. " is still working") end
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
  local win = panel_win()
  if win then
    if focus then vim.api.nvim_set_current_win(win) end
    return
  end
  local config = vim.t.ask_dock and { split = "right", win = -1, width = math.floor(vim.o.columns * 0.4) }
    or vim.tbl_extend("force", panel_config(), { border = "rounded" })
  win = vim.api.nvim_open_win(panel_buf(), focus, config)
  panel.wins[vim.api.nvim_get_current_tabpage()] = win
  vim.wo[win][0].wrap = true
  vim.wo[win][0].linebreak = true
  update_panel(win)
end

-- Docks the panel as a split in the current tab instead of a float.
function M.dock()
  vim.t.ask_dock = true
  show_panel(false)
end

local function send(chat, mode, question)
  if not vim.tbl_contains(chats, chat) then table.insert(chats, chat) end
  local reply = { role = names[chat.agent] }
  vim.list_extend(chat.messages, { { role = mode == "edit" and "You (edit)" or "You", text = question }, reply })
  chat.busy = mode
  if mode == "edit" and vim.bo[chat.buf].modified then
    vim.api.nvim_buf_call(chat.buf, function() vim.cmd("silent write") end)
  end
  show_panel(false)
  render()
  reveal(reply.row)
  local request = mode == "edit"
      and ("Make this change by editing the files directly, keeping it minimal: " .. question .. "\nThen briefly summarize what you changed.")
    or ("Question: " .. question)
  run(chat, mode, (chat.context and chat.context .. "\n\n" or "") .. request, function(answer, err)
    chat.busy, chat.failed = false, not answer
    if answer then chat.started, chat.context = true, nil end
    reply.text = answer and vim.trim(answer) or ("**Error:** " .. vim.trim(err or "unknown"))
    if mode == "edit" and vim.api.nvim_buf_is_valid(chat.buf) then vim.cmd("checktime " .. chat.buf) end
    render()
    if vim.tbl_contains(chats, chat) and vim.api.nvim_get_current_win() ~= panel_win() then reveal(reply.row) end
  end)
end

prompt_window = function(chat)
  local buf = vim.api.nvim_create_buf(false, true)
  local new = #chat.messages == 0
  chat.mode = chat.mode or "ask"
  local function title()
    return " " .. (chat.mode == "edit" and "Edit with " or "Ask ") .. names[chat.agent] .. " ▸ " .. chat.label .. " "
  end
  local hints = {}
  if new then table.insert(hints, "Tab: Claude/Codex") end
  if chat.buf then table.insert(hints, "^E edit · ^A ask") end
  vim.list_extend(hints, { "Enter: send", "Esc: cancel" })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = math.min(80, vim.o.columns - 4), height = 3,
    border = "rounded", title = title(), footer = " " .. table.concat(hints, " · ") .. " ", footer_pos = "center",
  })
  vim.wo[win][0].wrap = true
  vim.cmd.startinsert()
  local function close()
    vim.cmd.stopinsert()
    pcall(vim.api.nvim_win_close, win, true)
  end
  local function map(modes, lhs, fn) vim.keymap.set(modes, lhs, fn, { buffer = buf }) end
  map({ "i", "n" }, "<CR>", function()
    local question = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    close()
    if question ~= "" then send(chat, chat.mode, question) end
  end)
  map("n", "<Esc>", close)
  map("n", "q", close)
  if new then
    map({ "i", "n" }, "<Tab>", function()
      chat.agent = chat.agent == "claude" and "codex" or "claude"
      vim.api.nvim_win_set_config(win, { title = title() })
    end)
  end
  if chat.buf then
    local function set_mode(mode, insert)
      return function()
        chat.mode = mode
        vim.api.nvim_win_set_config(win, { title = title() })
        if insert then vim.cmd.startinsert({ bang = true }) end
      end
    end
    map("i", "<C-e>", set_mode("edit"))
    map("i", "<C-a>", set_mode("ask"))
    map("n", "e", set_mode("edit", true))
    map("n", "a", set_mode("ask", true))
  end
end

-- Maps an old 0-based row to its new row using vim.diff hunks.
local function remap_row(row, hunks)
  local line, delta = row + 1, 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca == 0 then
      if line <= sa then break end
      delta = delta + cb
    elseif line < sa then
      break
    elseif line < sa + ca then
      return math.max(sb - 1, 0)
    else
      delta = delta + cb - ca
    end
  end
  return line - 1 + delta
end

local function file_chat(buf, l1, l2)
  local name = vim.api.nvim_buf_get_name(buf)
  snaps[buf] = snaps[buf] or content(buf)
  local function place(r1, r2, id)
    return vim.api.nvim_buf_set_extmark(buf, anchors, r1, 0, {
      id = id, end_row = r2, end_col = #vim.api.nvim_buf_get_lines(buf, r2, r2 + 1, false)[1],
    })
  end
  local anchor = place(l1 - 1, l2 - 1)
  return {
    buf = buf,
    label = M.label(name, l1, l2),
    context = table.concat({
      "I'm working in the project at " .. vim.fn.getcwd() .. ".",
      string.format("File %s, lines %d-%d:", vim.fn.fnamemodify(name, ":."), l1, l2),
      M.numbered(buf, l1, l2),
    }, "\n"),
    range = function(b)
      if b ~= buf then return end
      local m = vim.api.nvim_buf_get_extmark_by_id(buf, anchors, anchor, { details = true })
      if m[1] then return m[1] + 1, m[3].end_row + 1 end
    end,
    remap = function(hunks)
      local m = vim.api.nvim_buf_get_extmark_by_id(buf, anchors, anchor, { details = true })
      if not m[1] then return end
      local last = vim.api.nvim_buf_line_count(buf) - 1
      local r1 = math.min(remap_row(m[1], hunks), last)
      place(r1, math.min(math.max(remap_row(m[3].end_row, hunks), r1), last), anchor)
    end,
    forget = function() pcall(vim.api.nvim_buf_del_extmark, buf, anchors, anchor) end,
  }
end

function M.attach(buf, make_chat)
  vim.b[buf].ask_attached = true
  local function ask(l1, l2)
    local chat = make_chat(buf, l1, l2)
    chat.agent, chat.messages, chat.out, chat.cwd = "claude", {}, vim.fn.tempname(), vim.fn.getcwd()
    prompt_window(chat)
  end
  local function ask_line() ask(vim.fn.line("."), vim.fn.line(".")) end
  local function ask_selection()
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    ask(math.min(l1, l2), math.max(l1, l2))
  end
  local function map(modes, lhs, rhs, opts)
    vim.keymap.set(modes, lhs, rhs, vim.tbl_extend("force", { buffer = buf }, opts or {}))
  end
  map("n", "<CR>", function()
    local chat = chat_at(buf, vim.fn.line("."))
    if chat then
      show_panel(true)
      return reveal(chat.first)
    end
    if vim.fn.foldclosed(".") ~= -1 then return vim.cmd("normal! zo") end
    ask_line()
  end, { desc = "Open AI session, expand fold, or ask AI" })
  map("n", "<S-CR>", ask_line, { desc = "Ask AI" })
  map("x", "<CR>", ask_selection, { desc = "Ask AI about selection" })
  map("x", "<S-CR>", ask_selection, { desc = "Ask AI about selection" })
  map("n", "q", function()
    local chat = chat_at(buf, vim.fn.line("."))
    if not chat then return "q" end
    vim.schedule(function() delete(chat) end)
    return ""
  end, { expr = true, desc = "Delete AI session on this line" })
  map("n", "ga", function()
    if #chats == 0 then return vim.notify("No AI sessions yet") end
    show_panel(true)
  end, { desc = "Go to AI sessions" })
  refresh()
end

vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })

vim.api.nvim_create_autocmd("BufEnter", { group = group, callback = function(a)
  local name = vim.api.nvim_buf_get_name(a.buf)
  if vim.b[a.buf].ask_attached or vim.bo[a.buf].buftype ~= "" or name == "" or name:match("^%a+://") then return end
  M.attach(a.buf, file_chat)
end })

-- Not on BufReadPost: it also fires during a reload, before FileChangedShellPost needs the old content.
vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = function(a)
  if snaps[a.buf] then snaps[a.buf] = content(a.buf) end
end })

-- On reload, extmarks keep their old row numbers, so re-anchor sessions using a diff.
vim.api.nvim_create_autocmd("FileChangedShellPost", { group = group, callback = function(a)
  local old = snaps[a.buf]
  if not old then return end
  snaps[a.buf] = content(a.buf)
  local hunks = vim.diff(old, snaps[a.buf], { result_type = "indices" })
  for _, c in ipairs(chats) do
    if c.remap and c.buf == a.buf then c.remap(hunks) end
  end
  refresh()
end })

vim.api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(a) snaps[a.buf] = nil end })

return M
