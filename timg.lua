#!/usr/bin/env lua
-- timg.lua - rgba-terminal-renderer
-- Version 25.11.04 (updated 2025-11-04)
--
-- Render images/video to the terminal using ffmpeg -> raw RGBA -> unicode half-blocks (▀) with 24-bit color.
--
-- Usage:
--   lua timg.lua <input-file-or--> [width_cols] [fps] [mode]
--
-- Arguments:
--   <input-file-or-> : path to input image or video file, or '-' to read from stdin
--   [width_cols]    : optional target width in character columns (default: terminal width)
--   [fps]           : optional target frames per second for video input (default: 15)
--   [mode]          : optional mode flag; pass "-i", "--inline" or "inline" to disable in-place overwrite mode
--
-- Example:
--   lua timg.lua image.png
--   lua timg.lua video.mp4 80 16 -i
--   lua timg.lua -                 # read input from stdin (no probing available; will fall back to terminal-height behavior)
--
-- WARN: terminals cannot actually show more character columns than their real width; if you provide a very large
-- width_cols that exceeds your terminal's real column count, the output may wrap/clip in your terminal.
-- If you want to display a wider image you must resize the terminal emulator or use a different display target.
--

local usage_string =
[[Usage:
lua timg.lua <input-file-or--> [width_cols] [fps] [mode]

Examples:
lua timg.lua img.png
lua timg.lua video.mp4 80 20 -i]]

-- Throw an error message and exit
-- NOTE: The LSP may not pick up os.exit calls well
-- You may need another exit call after this function
-- to appease the LSP
local function err(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

-- Clamp utility: keep numeric values within [a, b]
local function clamp(v, a, b)
  if v ~= v then return a end -- guard NaN (defensive)
  if v < a then return a elseif v > b then return b else return v end
end

-- Get terminal size (cols, rows)
local function get_tty_size()
  local fh = io.popen("stty size 2>/dev/null")
  if fh then
    local s = fh:read("*l")
    fh:close()
    if s then
      local r, c = s:match("(%d+)%s+(%d+)")
      if r and c then
        return tonumber(c), tonumber(r)
      end
    end
  end
  -- Fallback to tput
  local okc = io.popen("tput cols 2>/dev/null")
  local okr = io.popen("tput lines 2>/dev/null")
  if okc and okr then
    local c = tonumber(okc:read("*l") or "80")
    local r = tonumber(okr:read("*l") or "24")
    okc:close(); okr:close()
    return c, r
  end
  return 80, 24
end

-- Quote a string for safe inclusion in shell command line
local function shell_quote(s)
  if not s then return '""' end
  if s:match("[ \"'\\]") then
    if not s:find("'") then
      return "'" .. s .. "'"
    else
      return '"' .. s:gsub('(["\\$`])', "\\%1") .. '"'
    end
  end
  return s
end

-- Probe input video/image dimensions using ffprobe. Returns w,h or nil on failure.
local function probe_size(path)
  local cmd = string.format('ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x %s',
    shell_quote(path))
  local ph = io.popen(cmd)
  if not ph then return nil end
  local s = ph:read("*a")
  ph:close()
  if not s then return nil end
  s = s:match("^%s*(.-)%s*$")
  if s == "" then return nil end
  local w, h = s:match("^(%d+)x(%d+)$")
  if not w then return nil end
  return tonumber(w), tonumber(h)
end

-- Parse args
local input = arg[1] or ""
local width_override = nil
if arg[2] then
  local v = tonumber(arg[2])
  if v then
    width_override = math.floor(v)
    if width_override < 1 then
      err("Invalid width specified: " ..
        tostring(arg[2]) .. "\n" .. usage_string)
    end
  end
end

local fps = tonumber(arg[3]) or 15

-- Default to inplace mode; pass "inline" or -i/--inline to disable in-place overwrite
local inplace = true
if arg[4] then
  local m = tostring(arg[4]):lower()
  if m == "inline" or m == "-i" or m == "--inline" then inplace = false end
end

if input == "" then
  err(usage_string)
end

-- Determine terminal geometry
local term_w, term_h = get_tty_size()
-- Keep a copy of the real terminal columns for decision-making
local real_term_w = term_w
if width_override then term_w = width_override end

-- Compute frame size. Behavior:
-- - If width_override is provided and we can probe the source, set frame_w = width_override and compute frame_h from aspect.
--   Do not later shrink frame_w just to make the image fit vertically (that was causing surprising shrinking).
-- - If width_override is not provided, we compute a target width based on terminal columns and cap height to terminal pixel height.
local frame_w, frame_h
local use_pad = false

if input ~= "-" then
  local src_w, src_h = probe_size(input)
  if src_w and src_h and src_w > 0 and src_h > 0 then
    if width_override then
      -- Respect explicit width override: set pixel width to character columns and compute height by aspect.
      frame_w = width_override
      frame_h = math.floor((src_h * frame_w) / src_w + 0.5)
      -- Ensure even height (we print 2 pixels per character cell)
      if frame_h % 2 == 1 then frame_h = frame_h + 1 end
      -- Do NOT force-fit height to terminal vertical space here. The result can be taller than the terminal
      -- (which may cause scrolling/wrapping in some terminals).
    else
      -- Pick terminal columns as width and cap height so image fits in terminal vertical pixel area.
      local tgt_w = term_w
      local tgt_h = math.floor((src_h * tgt_w) / src_w + 0.5)
      if tgt_h % 2 == 1 then tgt_h = tgt_h + 1 end
      local max_h = term_h * 2
      if tgt_h > max_h then
        tgt_h = max_h
        local tgt_w2 = math.floor((src_w * tgt_h) / src_h + 0.5)
        if tgt_w2 < 1 then tgt_w2 = 1 end
        if tgt_w2 > term_w then tgt_w2 = term_w end
        frame_w = tgt_w2
        frame_h = tgt_h
      else
        frame_w = tgt_w
        frame_h = tgt_h
      end
    end
  end
end

-- If probe failed or input is stdin, fall back to pad-to-terminal behavior
if not frame_w or not frame_h then
  use_pad = true
  -- Use the (possibly overridden) term_w and full terminal pixel height
  frame_w = term_w
  frame_h = term_h * 2
end

-- Enforce sane minimum and even height
if frame_w < 1 then frame_w = 1 end
if frame_h < 2 then frame_h = 2 end
if frame_h % 2 == 1 then frame_h = frame_h + 1 end

local frame_size = frame_w * frame_h * 4
local printed_lines = math.floor(frame_h / 2)

-- Build ffmpeg command
local input_spec = (input == "-") and "-" or shell_quote(input)
local vf
if use_pad then
  vf = string.format('scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black',
    frame_w, frame_h, frame_w, frame_h)
else
  vf = string.format('scale=%d:%d', frame_w, frame_h)
end

-- Add -re for file inputs so ffmpeg reads at native rate (pacing). Do not use -re for stdin.
local ffmpeg_cmd
if input_spec == "-" then
  ffmpeg_cmd = string.format(
    'ffmpeg -nostdin -loglevel error -i %s -vf "%s" -r %d -f rawvideo -pix_fmt rgba -',
    input_spec, vf, fps
  )
else
  ffmpeg_cmd = string.format(
    'ffmpeg -nostdin -loglevel error -re -i %s -vf "%s" -r %d -f rawvideo -pix_fmt rgba -',
    input_spec, vf, fps
  )
end

-- Try opening ffmpeg process
local fh, open_err = io.popen(ffmpeg_cmd, "r")
if not fh then
  err("Failed to run ffmpeg: " .. (open_err or "unknown"))
  os.exit(1)
end

-- Terminal control sequences
local ESC = string.char(27)
local function fg(r, g, b) return string.format("%s[38;2;%d;%d;%dm", ESC, r, g, b) end
local function bg(r, g, b) return string.format("%s[48;2;%d;%d;%dm", ESC, r, g, b) end
local RESET = ESC .. "[0m"
local HIDE_CURSOR = ESC .. "[?25l"
local SHOW_CURSOR = ESC .. "[?25h"
local CURSOR_UP = function(n) return ESC .. "[" .. tostring(n) .. "A" end
local ERASE_LINE = ESC .. "[2K"
local CURSOR_COL1 = ESC .. "[G"

-- Cleanup routine that will be called on any exit/error to restore terminal state
local function safe_close_fh(handle)
  if not handle then return end
  pcall(function() handle:close() end)
end

local function cleanup()
  -- restore ANSI state and cursor visibility
  io.write(RESET)
  io.write("\n")
  io.write(SHOW_CURSOR)
  io.flush()
  safe_close_fh(fh)
  fh = nil
end

-- detect an interrupt-like error string (Ctrl-C causes "interrupted" in many Lua builds)
local function is_interrupt_err(e)
  if not e then return false end
  local s = tostring(e):lower()
  if s:match("interrupt") or s:match("interrupted") or s:match("c%-c") then
    return true
  end
  return false
end

-- Render one frame (raw rgba string of length frame_size)
local first_frame = true
local function render_frame(data)
  local out_lines = {}
  for y = 0, frame_h - 1, 2 do
    local chars = {}
    local top_row_off = y * frame_w * 4
    local bot_row_off = (y + 1) * frame_w * 4
    for x = 0, frame_w - 1 do
      local top_i = top_row_off + x * 4 + 1
      local bot_i = bot_row_off + x * 4 + 1
      local t1, t2, t3, t4 = data:byte(top_i, top_i + 3)
      local b1, b2, b3, b4 = data:byte(bot_i, bot_i + 3)

      -- Missing data -> solid opaque black
      if not t1 then t1, t2, t3, t4 = 0, 0, 0, 255 end
      if not b1 then b1, b2, b3, b4 = 0, 0, 0, 255 end

      -- Respect alpha threshold: if very transparent, treat as black
      if t4 < 10 then t1, t2, t3 = 0, 0, 0 end
      if b4 < 10 then b1, b2, b3 = 0, 0, 0 end

      -- Defensive clamping & integer conversion for color channels before formatting escape sequences
      local rt = math.floor(clamp(t1 or 0, 0, 255))
      local gt = math.floor(clamp(t2 or 0, 0, 255))
      local bt = math.floor(clamp(t3 or 0, 0, 255))

      local rb = math.floor(clamp(b1 or 0, 0, 255))
      local gb = math.floor(clamp(b2 or 0, 0, 255))
      local bb = math.floor(clamp(b3 or 0, 0, 255))

      local seq = fg(rt, gt, bt) .. bg(rb, gb, bb) .. "▀"
      chars[#chars + 1] = seq
    end
    out_lines[#out_lines + 1] = table.concat(chars) .. RESET
  end

  if inplace then
    if first_frame then
      -- Hide cursor for nicer playback, print the block and leave a trailing newline so cursor sits on the line after the image
      io.write(HIDE_CURSOR)
      io.write(table.concat(out_lines, "\n"))
      io.write("\n") -- ensure CURSOR_UP addresses the correct lines later
      io.flush()
      first_frame = false
    else
      -- Move cursor up to the start of the image block, then overwrite line by line
      io.write(CURSOR_UP(printed_lines))
      for i = 1, #out_lines do
        io.write(CURSOR_COL1)
        io.write(ERASE_LINE)
        io.write(out_lines[i])
        if i < #out_lines then io.write("\n") end
      end
      -- Keep cursor on line after image block
      io.write("\n")
      io.flush()
    end
  else
    -- Inline append mode: print the frame and then a newline so prompt/content starts on a fresh line
    io.write(table.concat(out_lines, "\n"))
    io.write("\n")
    io.flush()
  end
end

-- Main loop with protected reads and graceful exit handling
local frame_count = 0
local aborted = false

local ok_main, main_err = pcall(function()
  while true do
    local ok_read, data_or_err = pcall(function() return fh:read(frame_size) end)
    if not ok_read then
      if is_interrupt_err(data_or_err) then
        aborted = true
        return
      else
        io.stderr:write("Read error: " .. tostring(data_or_err) .. "\n")
        aborted = true
        return
      end
    end

    local data = data_or_err
    if not data or #data < frame_size then
      -- EOF or incomplete frame => normal end of stream
      return
    end

    frame_count = frame_count + 1
    local ok_render, render_err = pcall(render_frame, data)
    if not ok_render then
      if is_interrupt_err(render_err) then
        aborted = true
        return
      else
        io.stderr:write("Render error: " .. tostring(render_err) .. "\n")
        aborted = true
        return
      end
    end
  end
end)

-- Always cleanup terminal state and ffmpeg pipe
cleanup()

if not ok_main then
  io.stderr:write("Exited with error: " .. tostring(main_err) .. "\n")
  os.exit(1)
end

if aborted then
  io.stderr:write("Playback interrupted by user or error; cleaned up terminal state.\n")
  os.exit(0)
end

-- Normal exit summary
if width_override then
  io.stderr:write(string.format(
    "Rendered %d frames to %dx%d terminal (frame pixel size: %dx%d) with width override %d columns (use_pad=%s, inplace=%s)\n",
    frame_count, real_term_w, term_h, frame_w, frame_h, width_override, tostring(use_pad), tostring(inplace)))
else
  io.stderr:write(string.format(
    "Rendered %d frames to %dx%d terminal (frame pixel size: %dx%d) (use_pad=%s, inplace=%s)\n",
    frame_count, real_term_w, term_h, frame_w, frame_h, tostring(use_pad), tostring(inplace)))
end

os.exit(0)
