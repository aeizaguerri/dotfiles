return {
  'folke/tokyonight.nvim',
  lazy = false,
  priority = 1000,
  opts = {
    style = 'night',
    comments = { italic = false },
  },
  config = function()
    -- load the colorscheme here
    vim.cmd [[colorscheme tokyonight]]
  end,
}
