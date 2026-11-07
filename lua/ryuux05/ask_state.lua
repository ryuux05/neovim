local M = {}
local root = vim.fn.stdpath("state") .. "/ask"
local agents = { codex = true, claude = true }

local function read(path)
  if vim.fn.filereadable(path) == 0 then return end
  local ok, value = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) end)
  if ok and type(value) == "table" then return value end
  vim.notify("Could not read AI state: " .. path, vim.log.levels.WARN)
end

local function write(path, value)
  local temp = path .. "." .. vim.fn.getpid() .. ".tmp"
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p", 448)
    assert(vim.fn.writefile({ vim.json.encode(value) }, temp) == 0)
    assert(vim.uv.fs_rename(temp, path))
  end)
  if not ok then
    vim.fn.delete(temp)
    vim.notify("Could not save AI state: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

local function directory(cwd) return root .. "/sessions/" .. vim.fn.sha256(cwd) end

function M.default()
  local settings = read(root .. "/settings.json")
  return settings and agents[settings.default_agent] and settings.default_agent or "codex"
end

function M.set_default(agent) return write(root .. "/settings.json", { default_agent = agent }) end

function M.save(chat)
  if not chat.key then
    chat.key = vim.fn.sha256(vim.fn.tempname())
    local seconds, microseconds = vim.uv.gettimeofday()
    chat.created = seconds + microseconds / 1000000
  end
  local saved = {}
  for _, field in ipairs({
    "key",
    "created",
    "cwd",
    "agent",
    "id",
    "started",
    "messages",
    "context",
    "label",
    "review",
    "mode",
    "source",
    "failed",
  }) do
    saved[field] = chat[field]
  end
  saved.interrupted = not not chat.busy
  return write(directory(chat.cwd) .. "/" .. chat.key .. ".json", saved)
end

function M.delete(chat)
  if chat.key then vim.fn.delete(directory(chat.cwd) .. "/" .. chat.key .. ".json") end
end

function M.load(cwd)
  local chats = {}
  for _, path in ipairs(vim.fn.globpath(directory(cwd), "*.json", false, true)) do
    local chat = read(path)
    local valid = chat
      and agents[chat.agent]
      and chat.cwd == cwd
      and type(chat.label) == "string"
      and type(chat.created) == "number"
      and type(chat.key) == "string"
      and chat.key:match("^%x+$")
      and vim.fn.fnamemodify(path, ":t:r") == chat.key
      and type(chat.messages) == "table"
      and vim.islist(chat.messages)
      and (not chat.started or type(chat.id) == "string")
    if valid and chat.source ~= nil then
      local source = chat.source
      valid = type(source) == "table"
        and type(source.path) == "string"
        and type(source.l1) == "number"
        and source.l1 >= 1
        and source.l1 % 1 == 0
        and type(source.l2) == "number"
        and source.l2 >= source.l1
        and source.l2 % 1 == 0
    end
    if valid then
      for _, message in ipairs(chat.messages) do
        if
          type(message) ~= "table"
          or type(message.role) ~= "string"
          or (message.text ~= nil and type(message.text) ~= "string")
        then
          valid = false
          break
        end
      end
    end
    if valid then
      if chat.interrupted then
        chat.failed = true
        local reply = chat.messages[#chat.messages]
        if reply and not reply.text then reply.text = "_Interrupted. Send a follow-up to continue._" end
      end
      chat.interrupted = nil
      table.insert(chats, chat)
    elseif chat then
      vim.notify("Skipping invalid AI session: " .. path, vim.log.levels.WARN)
    end
  end
  table.sort(chats, function(a, b) return a.created < b.created end)
  return chats
end

return M
