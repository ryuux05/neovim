-- Automatically generated packer.nvim plugin loader code

if vim.api.nvim_call_function('has', {'nvim-0.5'}) ~= 1 then
  vim.api.nvim_command('echohl WarningMsg | echom "Invalid Neovim version for packer.nvim! | echohl None"')
  return
end

vim.api.nvim_command('packadd packer.nvim')

local no_errors, error_msg = pcall(function()

_G._packer = _G._packer or {}
_G._packer.inside_compile = true

local time
local profile_info
local should_profile = false
if should_profile then
  local hrtime = vim.loop.hrtime
  profile_info = {}
  time = function(chunk, start)
    if start then
      profile_info[chunk] = hrtime()
    else
      profile_info[chunk] = (hrtime() - profile_info[chunk]) / 1e6
    end
  end
else
  time = function(chunk, start) end
end

local function save_profiles(threshold)
  local sorted_times = {}
  for chunk_name, time_taken in pairs(profile_info) do
    sorted_times[#sorted_times + 1] = {chunk_name, time_taken}
  end
  table.sort(sorted_times, function(a, b) return a[2] > b[2] end)
  local results = {}
  for i, elem in ipairs(sorted_times) do
    if not threshold or threshold and elem[2] > threshold then
      results[i] = elem[1] .. ' took ' .. elem[2] .. 'ms'
    end
  end
  if threshold then
    table.insert(results, '(Only showing plugins that took longer than ' .. threshold .. ' ms ' .. 'to load)')
  end

  _G._packer.profile_output = results
end

time([[Luarocks path setup]], true)
local package_path_str = "/Users/ryuux05/.cache/nvim/packer_hererocks/2.1.1783773675/share/lua/5.1/?.lua;/Users/ryuux05/.cache/nvim/packer_hererocks/2.1.1783773675/share/lua/5.1/?/init.lua;/Users/ryuux05/.cache/nvim/packer_hererocks/2.1.1783773675/lib/luarocks/rocks-5.1/?.lua;/Users/ryuux05/.cache/nvim/packer_hererocks/2.1.1783773675/lib/luarocks/rocks-5.1/?/init.lua"
local install_cpath_pattern = "/Users/ryuux05/.cache/nvim/packer_hererocks/2.1.1783773675/lib/lua/5.1/?.so"
if not string.find(package.path, package_path_str, 1, true) then
  package.path = package.path .. ';' .. package_path_str
end

if not string.find(package.cpath, install_cpath_pattern, 1, true) then
  package.cpath = package.cpath .. ';' .. install_cpath_pattern
end

time([[Luarocks path setup]], false)
time([[try_loadstring definition]], true)
local function try_loadstring(s, component, name)
  local success, result = pcall(loadstring(s), name, _G.packer_plugins[name])
  if not success then
    vim.schedule(function()
      vim.api.nvim_notify('packer.nvim: Error running ' .. component .. ' for ' .. name .. ': ' .. result, vim.log.levels.ERROR, {})
    end)
  end
  return result
end

time([[try_loadstring definition]], false)
time([[Defining packer_plugins]], true)
_G.packer_plugins = {
  LuaSnip = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/LuaSnip",
    url = "https://github.com/L3MON4D3/LuaSnip"
  },
  ["cmp-buffer"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/cmp-buffer",
    url = "https://github.com/hrsh7th/cmp-buffer"
  },
  ["cmp-nvim-lsp"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/cmp-nvim-lsp",
    url = "https://github.com/hrsh7th/cmp-nvim-lsp"
  },
  ["cmp-path"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/cmp-path",
    url = "https://github.com/hrsh7th/cmp-path"
  },
  cmp_luasnip = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/cmp_luasnip",
    url = "https://github.com/saadparwaiz1/cmp_luasnip"
  },
  harpoon = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/harpoon",
    url = "https://github.com/theprimeagen/harpoon"
  },
  ["markdown-preview.nvim"] = {
    config = { "\27LJ\2\nê\1\0\0\3\0\6\0\t6\0\0\0009\0\1\0'\1\3\0=\1\2\0006\0\0\0009\0\4\0'\2\5\0B\0\2\1K\0\1\0“\1        function OpenMarkdownPreview(url)\n          execute \"silent !open -na 'Arc' --args --new-window \" . a:url\n        endfunction\n        \bcmd\24OpenMarkdownPreview\21mkdp_browserfunc\6g\bvim\0" },
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/markdown-preview.nvim",
    url = "https://github.com/iamcco/markdown-preview.nvim"
  },
  ["mason-lspconfig.nvim"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/mason-lspconfig.nvim",
    url = "https://github.com/williamboman/mason-lspconfig.nvim"
  },
  ["mason.nvim"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/mason.nvim",
    url = "https://github.com/williamboman/mason.nvim"
  },
  ["nvim-cmp"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/nvim-cmp",
    url = "https://github.com/hrsh7th/nvim-cmp"
  },
  ["nvim-lspconfig"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/nvim-lspconfig",
    url = "https://github.com/neovim/nvim-lspconfig"
  },
  ["nvim-treesitter"] = {
    config = { "\27LJ\2\n2\0\0\3\0\2\0\0046\0\0\0'\2\1\0B\0\2\1K\0\1\0\23ryuux05.treesitter\frequire\0" },
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/nvim-treesitter",
    url = "https://github.com/nvim-treesitter/nvim-treesitter"
  },
  ["nvim-web-devicons"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/nvim-web-devicons",
    url = "https://github.com/nvim-tree/nvim-web-devicons"
  },
  nvmd = {
    config = { "\27LJ\2\nU\0\0\3\0\4\0\a6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\3\0B\0\2\1K\0\1\0\1\0\2\16debounce_ms\3–\1\16live_reload\2\nsetup\tnvmd\frequire\0" },
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/nvmd",
    url = "https://github.com/ryuux05/nvmd"
  },
  ["octo.nvim"] = {
    config = { "\27LJ\2\nÜ\a\0\0\a\0'\0?6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\3\0005\3\4\0=\3\5\0025\3\t\0005\4\a\0005\5\6\0=\5\b\4=\4\n\3=\3\v\2B\0\2\0016\0\f\0009\0\r\0009\0\14\0009\0\15\0'\2\16\0'\3\1\0B\0\3\0016\0\f\0009\0\17\0009\0\18\0'\2\19\0'\3\20\0'\4\21\0005\5\22\0B\0\5\0016\0\f\0009\0\17\0009\0\18\0\18\1\0\0'\3\23\0'\4\24\0'\5\25\0005\6\26\0B\1\5\1\18\1\0\0'\3\23\0'\4\27\0'\5\28\0005\6\29\0B\1\5\1\18\1\0\0'\3\23\0'\4\30\0'\5\31\0005\6 \0B\1\5\1\18\1\0\0'\3\23\0'\4!\0'\5\"\0005\6#\0B\1\5\1\18\1\0\0'\3\23\0'\4$\0'\5%\0005\6&\0B\1\5\1K\0\1\0\1\0\1\tdesc\23Octo: start review\31<cmd>Octo review start<cr>\15<leader>ov\1\0\1\tdesc\24Octo: notifications$<cmd>Octo notification list<cr>\15<leader>on\1\0\1\tdesc\17Octo: issues\29<cmd>Octo issue list<cr>\15<leader>oi\1\0\1\tdesc\26Octo: review requests?<cmd>Octo pr search is:pr is:open review-requested:@me<cr>\15<leader>or\1\0\1\tdesc\14Octo: PRs\26<cmd>Octo pr list<cr>\15<leader>op\6n\1\0\2\vbuffer\1\vsilent\2\16@<C-x><C-o>\6@\6i\bset\vkeymap\rmarkdown\rregister\rlanguage\15treesitter\bvim\rmappings\17pull_request\1\0\1\17pull_request\0\15approve_pr\1\0\1\15approve_pr\0\1\0\2\blhs\20<localleader>qA\tdesc\15approve PR\freviews\1\0\2\nfocus\nright\22auto_show_threads\2\1\0\a\rmappings\0\vpicker\14telescope\freviews\0\27default_to_projects_v2\2\26default_delete_branch\1\25default_merge_method\vsquash\19enable_builtin\2\nsetup\tocto\frequire\0" },
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/octo.nvim",
    url = "https://github.com/pwntester/octo.nvim"
  },
  ["packer.nvim"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/packer.nvim",
    url = "https://github.com/wbthomason/packer.nvim"
  },
  ["plenary.nvim"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/plenary.nvim",
    url = "https://github.com/nvim-lua/plenary.nvim"
  },
  ["rose-pine"] = {
    config = { "\27LJ\2\n9\0\0\3\0\3\0\0056\0\0\0009\0\1\0'\2\2\0B\0\2\1K\0\1\0\26colorscheme rose-pine\bcmd\bvim\0" },
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/rose-pine",
    url = "https://github.com/rose-pine/neovim"
  },
  ["telescope.nvim"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/telescope.nvim",
    url = "https://github.com/nvim-telescope/telescope.nvim"
  },
  undotree = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/undotree",
    url = "https://github.com/mbbill/undotree"
  },
  ["vim-fugitive"] = {
    loaded = true,
    path = "/Users/ryuux05/.local/share/nvim/site/pack/packer/start/vim-fugitive",
    url = "https://github.com/tpope/vim-fugitive"
  }
}

time([[Defining packer_plugins]], false)
-- Config for: octo.nvim
time([[Config for octo.nvim]], true)
try_loadstring("\27LJ\2\nÜ\a\0\0\a\0'\0?6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\3\0005\3\4\0=\3\5\0025\3\t\0005\4\a\0005\5\6\0=\5\b\4=\4\n\3=\3\v\2B\0\2\0016\0\f\0009\0\r\0009\0\14\0009\0\15\0'\2\16\0'\3\1\0B\0\3\0016\0\f\0009\0\17\0009\0\18\0'\2\19\0'\3\20\0'\4\21\0005\5\22\0B\0\5\0016\0\f\0009\0\17\0009\0\18\0\18\1\0\0'\3\23\0'\4\24\0'\5\25\0005\6\26\0B\1\5\1\18\1\0\0'\3\23\0'\4\27\0'\5\28\0005\6\29\0B\1\5\1\18\1\0\0'\3\23\0'\4\30\0'\5\31\0005\6 \0B\1\5\1\18\1\0\0'\3\23\0'\4!\0'\5\"\0005\6#\0B\1\5\1\18\1\0\0'\3\23\0'\4$\0'\5%\0005\6&\0B\1\5\1K\0\1\0\1\0\1\tdesc\23Octo: start review\31<cmd>Octo review start<cr>\15<leader>ov\1\0\1\tdesc\24Octo: notifications$<cmd>Octo notification list<cr>\15<leader>on\1\0\1\tdesc\17Octo: issues\29<cmd>Octo issue list<cr>\15<leader>oi\1\0\1\tdesc\26Octo: review requests?<cmd>Octo pr search is:pr is:open review-requested:@me<cr>\15<leader>or\1\0\1\tdesc\14Octo: PRs\26<cmd>Octo pr list<cr>\15<leader>op\6n\1\0\2\vbuffer\1\vsilent\2\16@<C-x><C-o>\6@\6i\bset\vkeymap\rmarkdown\rregister\rlanguage\15treesitter\bvim\rmappings\17pull_request\1\0\1\17pull_request\0\15approve_pr\1\0\1\15approve_pr\0\1\0\2\blhs\20<localleader>qA\tdesc\15approve PR\freviews\1\0\2\nfocus\nright\22auto_show_threads\2\1\0\a\rmappings\0\vpicker\14telescope\freviews\0\27default_to_projects_v2\2\26default_delete_branch\1\25default_merge_method\vsquash\19enable_builtin\2\nsetup\tocto\frequire\0", "config", "octo.nvim")
time([[Config for octo.nvim]], false)
-- Config for: nvmd
time([[Config for nvmd]], true)
try_loadstring("\27LJ\2\nU\0\0\3\0\4\0\a6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\3\0B\0\2\1K\0\1\0\1\0\2\16debounce_ms\3–\1\16live_reload\2\nsetup\tnvmd\frequire\0", "config", "nvmd")
time([[Config for nvmd]], false)
-- Config for: markdown-preview.nvim
time([[Config for markdown-preview.nvim]], true)
try_loadstring("\27LJ\2\nê\1\0\0\3\0\6\0\t6\0\0\0009\0\1\0'\1\3\0=\1\2\0006\0\0\0009\0\4\0'\2\5\0B\0\2\1K\0\1\0“\1        function OpenMarkdownPreview(url)\n          execute \"silent !open -na 'Arc' --args --new-window \" . a:url\n        endfunction\n        \bcmd\24OpenMarkdownPreview\21mkdp_browserfunc\6g\bvim\0", "config", "markdown-preview.nvim")
time([[Config for markdown-preview.nvim]], false)
-- Config for: rose-pine
time([[Config for rose-pine]], true)
try_loadstring("\27LJ\2\n9\0\0\3\0\3\0\0056\0\0\0009\0\1\0'\2\2\0B\0\2\1K\0\1\0\26colorscheme rose-pine\bcmd\bvim\0", "config", "rose-pine")
time([[Config for rose-pine]], false)
-- Config for: nvim-treesitter
time([[Config for nvim-treesitter]], true)
try_loadstring("\27LJ\2\n2\0\0\3\0\2\0\0046\0\0\0'\2\1\0B\0\2\1K\0\1\0\23ryuux05.treesitter\frequire\0", "config", "nvim-treesitter")
time([[Config for nvim-treesitter]], false)

_G._packer.inside_compile = false
if _G._packer.needs_bufread == true then
  vim.cmd("doautocmd BufRead")
end
_G._packer.needs_bufread = false

if should_profile then save_profiles() end

end)

if not no_errors then
  error_msg = error_msg:gsub('"', '\\"')
  vim.api.nvim_command('echohl ErrorMsg | echom "Error in packer_compiled: '..error_msg..'" | echom "Please check your config for correctness" | echohl None')
end
