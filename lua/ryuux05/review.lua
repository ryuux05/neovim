local ask = require("ryuux05.ask")

local group = vim.api.nvim_create_augroup("Review", { clear = true })

local function set_hl()
  vim.api.nvim_set_hl(0, "ReviewAdd", { bg = "#1f3d2b" })
  vim.api.nvim_set_hl(0, "ReviewAddText", { bg = "#2e6b44" })
  vim.api.nvim_set_hl(0, "ReviewDel", { bg = "#45212a" })
  vim.api.nvim_set_hl(0, "ReviewDelText", { bg = "#7d2e3b" })
end
set_hl()

local function browse_when_loaded(buf, tries, resume)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local octo_buf = _G.octo_buffers[buf]
  if octo_buf and octo_buf.node then
    vim.api.nvim_set_current_buf(buf)
    return vim.cmd("Octo review " .. (resume and "resume" or "browse"))
  end
  if tries == 0 then return vim.notify("Review: PR didn't load", vim.log.levels.ERROR) end
  vim.defer_fn(function() browse_when_loaded(buf, tries - 1, resume) end, 100)
end

local function open(url, resume)
  vim.cmd("Octo " .. url)
  browse_when_loaded(vim.api.nvim_get_current_buf(), 200, resume)
end

local function pr_key(review)
  return review and review.pull_request.repo .. "#" .. review.pull_request.number
end

local function select_when_loaded(key, path, tries)
  local review = require("octo.reviews").get_current_review()
  local files = pr_key(review) == key and review.layout.files or {}
  for _, file in ipairs(files) do
    if file.path == path then return review.layout:set_current_file(file) end
  end
  if #files == 0 and tries > 0 then
    vim.defer_fn(function() select_when_loaded(key, path, tries - 1) end, 100)
  end
end

-- Octo can't refresh an open review, so fetch the PR again and reopen it on the same file.
local function reload()
  local review = require("octo.reviews").get_current_review()
  local pr, key, file = review.pull_request, pr_key(review), review.layout:get_current_file()
  require("octo.reviews").close(review.layout.tabpage)
  pcall(vim.api.nvim_buf_delete, pr.bufnr, { force = true })
  open(string.format("https://github.com/%s/pull/%d", pr.repo, pr.number), review.id ~= -1)
  if file then select_when_loaded(key, file.path, 300) end
end

local function review_chat(buf, l1, l2)
  local review = require("octo.reviews").get_current_review()
  local file = review.layout:get_current_file()
  local props, pr = vim.b[buf].octo_diff_props, pr_key(review)
  local side = props.split == "LEFT" and "base version (before the PR)" or "PR version (after the change)"
  return {
    review = true,
    source = { path = vim.api.nvim_buf_get_name(buf), l1 = l1, l2 = l2 },
    label = ask.label(file.path, l1, l2),
    context = table.concat({
      string.format("I'm reviewing GitHub pull request %s.", pr),
      string.format("File %s, lines %d-%d of the %s:", file.path, l1, l2, side),
      ask.numbered(buf, l1, l2),
      "Full diff of this file in the PR:", "```diff", file.patch or "", "```",
    }, "\n"),
    range = function(b)
      local p = vim.b[b].octo_diff_props
      if p and p.split == props.split and p.path == props.path and pr_key(require("octo.reviews").get_current_review()) == pr then
        return l1, l2
      end
    end,
  }
end

vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })

local function pr_title(pr)
  local octo_buf = _G.octo_buffers[pr.bufnr]
  return octo_buf and octo_buf.node and octo_buf.node.title or ""
end

-- Vim colors lines that exist only on the left as DiffAdd, so each side gets its own colors.
vim.api.nvim_create_autocmd("BufWinEnter", { group = group, callback = function(a)
  local props = vim.b[a.buf].octo_diff_props
  if not props then return end
  local review, win = require("octo.reviews").get_current_review(), vim.api.nvim_get_current_win()
  local layout = review and review.layout
  if not layout or (win ~= layout.left_winid and win ~= layout.right_winid) then
    -- A local PR file opened outside the review would inherit the review window's options.
    vim.wo[0][0].winhighlight, vim.wo[0][0].winbar = "", ""
    return
  end
  local pr, bar = review.pull_request
  if props.split == "LEFT" then
    vim.wo[0][0].winhighlight = "DiffAdd:ReviewDel,DiffChange:ReviewDel,DiffText:ReviewDelText"
    bar = string.format(" BASE · %s ", props.path)
  else
    vim.wo[0][0].winhighlight = "DiffAdd:ReviewAdd,DiffChange:ReviewAdd,DiffText:ReviewAddText"
    bar = string.format(" PR #%d · %s · %s ", pr.number, props.path, pr_title(pr))
  end
  vim.wo[0][0].winbar = (bar:gsub("%%", "%%%%"))
  if a.match:match("^octo://") then ask.attach(a.buf, review_chat) end
end })

vim.api.nvim_create_autocmd("FileType", { group = group, pattern = "octo_panel", callback = function(a)
  vim.keymap.set("n", "<LeftRelease>", "<LeftRelease><CR>", { buffer = a.buf, remap = true })
end })

vim.api.nvim_create_user_command("Review", function(o) open(o.args) end, { nargs = 1 })

vim.keymap.set("n", "<C-r>", function()
  if not require("octo.reviews").get_current_review() then return "<C-r>" end
  vim.schedule(reload)
  return ""
end, { expr = true, desc = "Reload PR review, else redo" })

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
