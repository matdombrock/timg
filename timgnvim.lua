-- A Neovim plugin to display images/videos in a floating terminal using timg.lua
-- Opens a floating terminal window and runs timg.lua with specified parameters
--
-- NOTE: Its not easily possible to render something like this directly in a Neovim buffer,
-- so we use a terminal window as a workaround.
--
-- Usage:
--   :Timg <input-file-or-> [width_cols] [fps] [mode]
--
-- Arguments:
--   <input-file-or-> : path to input image or video file, or '-' to read from stdin
--   [width_cols]     : optional target width in character columns (default: terminal width)
--   [fps]            : optional target frames per second for video input (default: 15)
--   [mode]           : optional mode flag; pass "-i", "--inline" or "inline" to disable in-place overwrite mode
--
-- Example:
--   :Timg /path/to/image.png
--   :Timg /path/to/video.mp4 80 30 -i
--
-- NOTE: It is also possible to use a path relative to your current working directory.
--
-- NOTE: The `timg.lua` script is a standalone Lua script for displaying images/videos in terminal emulators.
-- It depends on `ffmpeg`
-- See `timg.lua` for more details

-- Set your timg.lua path here
local timg_path = "lua/apps/timg/timg.lua" -- <-- CHANGE THIS
-- Chose to use lua or luaJIT interpreter
local lua_cmd = 'lua'                      -- or 'luajit'

local function open_timg(img_path, width_cols, fps, mode)
  if not img_path or img_path == "" then
    img_path = vim.fn.input("Image/video file: ")
    if img_path == "" then return end
  end

  -- Create a terminal buffer in a floating window
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local win_opts = {
    relative = 'editor',
    width = width,
    height = height,
    row = (vim.o.lines - height) / 2,
    col = (vim.o.columns - width) / 2,
    style = 'minimal',
    border = 'rounded',
  }

  local term_buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(term_buf, true, win_opts)
  local term_cmd = { lua_cmd, timg_path }
  if img_path then table.insert(term_cmd, img_path) end
  if width_cols then table.insert(term_cmd, width_cols) end
  if fps then table.insert(term_cmd, fps) end
  if mode then table.insert(term_cmd, mode) end

  -- WARN: This code is deprecated and will be removed in future versions of NVIM.
  vim.fn.termopen(term_cmd)

  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = term_buf })
  vim.api.nvim_set_option_value('filetype', 'timg-term', { buf = term_buf })

  -- Map 'q' in normal mode to close window and wipe buffer
  -- TODO: This might not be needed
  -- The process exits and should close the terminal automatically on any key press
  vim.api.nvim_buf_set_keymap(term_buf, 'n', 'q', '', {
    noremap = true,
    silent = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(term_buf) then
        vim.api.nvim_buf_delete(term_buf, { force = true })
      end
    end,
  })

  -- Enter terminal mode automatically
  vim.cmd("startinsert")
end

vim.api.nvim_create_user_command('Timg', function(opts)
  -- Split args: expects "<img_path> [width] [fps] [mode]"
  local args = {}
  for word in opts.args:gmatch("%S+") do table.insert(args, word) end
  local img_path = args[1]
  local width_cols = args[2]
  local fps = args[3]
  local mode = args[4]
  open_timg(img_path, width_cols, fps, mode)
end, { nargs = '*', desc = 'Open image/video in floating terminal using timg.lua' })

-- Return the function for potential external use
return open_timg
