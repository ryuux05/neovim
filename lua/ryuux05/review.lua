local ask = require("ryuux05.ask")

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

local function pr_key(review)
  return review and review.pull_request.repo .. "#" .. review.pull_request.number
end

local function review_chat(buf, l1, l2)
  local review = require("octo.reviews").get_current_review()
  local file = review.layout:get_current_file()
  local props, pr = vim.b[buf].octo_diff_props, pr_key(review)
  local side = props.split == "LEFT" and "base version (before the PR)" or "PR version (after the change)"
  return {
    review = true,
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

-- Vim colors lines that exist only on the left as DiffAdd, so each side gets its own colors.
vim.api.nvim_create_autocmd("BufWinEnter", { group = group, pattern = "octo://*/review/*/file/*", callback = function(a)
  if a.match:find("/file/LEFT/", 1, true) then
    vim.wo[0][0].winhighlight = "DiffAdd:ReviewDel,DiffChange:ReviewDel,DiffText:ReviewDelText"
  else
    vim.wo[0][0].winhighlight = "DiffAdd:ReviewAdd,DiffChange:ReviewAdd,DiffText:ReviewAddText"
  end
  ask.attach(a.buf, review_chat)
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
