local M = {}
local root = vim.fn.stdpath("state") .. "/ask"
local source = debug.getinfo(1, "S").source:sub(2)
local helper = vim.fn.fnamemodify(source, ":h:h:h") .. "/scripts/ask_store.py"
local fields = {
  "key",
  "created",
  "cwd",
  "agent",
  "id",
  "started",
  "context",
  "label",
  "review",
  "mode",
  "source",
  "failed",
}

local function command() return { vim.g.ask_python or "python3", helper, "--root", root } end
local function decode(text) return vim.json.decode(text, { luanil = { object = true, array = true } }) end
local function warn(message)
  if message then vim.notify(message, vim.log.levels.WARN) end
end

local function call(request)
  local ok, result = pcall(function()
    local process = vim.system(command(), { stdin = vim.json.encode(request), text = true }):wait(10000)
    local response = decode(process.stdout or "")
    if not response.ok then error(response.error or process.stderr) end
    return response.result
  end)
  if ok then return result end
  local message = "AI storage: " .. tostring(result)
  vim.notify(message, vim.log.levels.ERROR)
  return nil, message
end

local function snapshot(chat)
  if not chat.key then
    chat.key = vim.fn.sha256(vim.fn.tempname())
    local seconds, microseconds = vim.uv.gettimeofday()
    chat.created = seconds + microseconds / 1000000
  end
  local saved = {}
  for _, field in ipairs(fields) do
    saved[field] = chat[field]
  end
  saved.messages = {}
  for _, message in ipairs(chat.messages) do
    table.insert(saved.messages, { role = message.role, text = message.text })
  end
  saved.interrupted = not not chat.busy
  return saved
end

local function hydrate(chat)
  if not chat then return end
  if chat.active then
    chat.busy = "external"
  elseif chat.interrupted then
    chat.failed = true
    local reply = chat.messages[#chat.messages]
    if reply and not reply.text then reply.text = "_Interrupted. Send a follow-up to continue._" end
  end
  chat.active, chat.interrupted = nil, nil
  return chat
end

function M.default() return call({ op = "default" }) or "codex" end
function M.set_default(agent) return call({ op = "default", agent = agent }) ~= nil end

function M.save(chat)
  -- The request worker owns durable updates while a turn is running.
  if chat.busy then return true end
  local result = call({ op = "save", chat = snapshot(chat), revision = chat.revision or 0 })
  if not result then return false end
  chat.revision = result.revision
  warn(result.warning)
  return true
end

function M.delete(chat)
  local result = call({ op = "delete", cwd = chat.cwd, key = chat.key, revision = chat.revision })
  if not result then return false end
  warn(result.warning)
  return true
end

function M.load(cwd)
  local chats = call({ op = "load", cwd = cwd })
  if not chats then return end
  for _, chat in ipairs(chats) do
    hydrate(chat)
  end
  return chats
end

function M.get(cwd, key)
  local chat, err = call({ op = "get", cwd = cwd, key = key })
  return hydrate(chat), err
end
function M.search(query) return call({ op = "search", query = query }) end
function M.rebuild() return call({ op = "rebuild" }) end

function M.run(chat, mode, prompt, callback)
  local pending, completion = "", nil
  local function event(line)
    if line == "" then return end
    local ok, value = pcall(decode, line)
    if not ok or type(value) ~= "table" then return end
    if value.id then chat.id = value.id end
    if value.started ~= nil then chat.started = value.started end
    if value.revision then chat.revision = value.revision end
    if value.type == "complete" then
      completion = value
      warn(value.warning)
    elseif value.ok == false then
      completion = value
    end
  end
  local ok, err = pcall(
    vim.system,
    command(),
    {
      stdin = vim.json.encode({
        op = "run",
        chat = snapshot(chat),
        revision = chat.revision or 0,
        mode = mode,
        prompt = prompt,
      }),
      text = true,
      detach = true,
      stdout = vim.schedule_wrap(function(error, chunk)
        if error then return end
        pending = pending .. (chunk or "")
        while true do
          local finish = pending:find("\n", 1, true)
          if not finish then break end
          event(pending:sub(1, finish - 1))
          pending = pending:sub(finish + 1)
        end
      end),
    },
    vim.schedule_wrap(function(result)
      event(pending)
      if completion then
        callback(completion.answer, completion.error)
      else
        callback(
          nil,
          vim.trim(result.stderr or "") ~= "" and result.stderr or "Agent worker stopped; reopen the saved conversation"
        )
      end
    end)
  )
  if not ok then callback(nil, tostring(err)) end
end

return M
