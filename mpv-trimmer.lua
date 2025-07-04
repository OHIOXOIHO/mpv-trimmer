-- Load required MPV modules
local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

-- --- Global Variables ---
local start_time = nil -- Cut start point
local end_time = nil   -- Cut end point
local cut_counter = 0  -- Cut counter for unique filenames
local is_windows = package.config:sub(1,1) == '\\' -- Simple OS check for path separators
-- Find home directory, works on Win/Linux
local home_dir = os.getenv("HOME") or (is_windows and os.getenv("USERPROFILE") or "/home/user")

-- Default output directory for streams or when toggled
local OUTPUT_DIR_DEFAULT = utils.join_path(home_dir, "Desktop/mpvstreamcut")
-- Current output mode: "default_dir" (Desktop/mpvstreamcut) or "source_dir" (original file's directory)
local current_output_mode = "default_dir" 
local TEMP_VIDEO = utils.join_path(os.getenv("TEMP") or "/tmp", "mpv_temp_video.mp4")

-- --- Output Settings ---
-- CRF quality setting. Lower is better quality/bigger file.
local VIDEO_QUALITY_CRF = 23 

-- Quality modes and their corresponding CRF values
local QUALITY_MODES = {
    untouched = {name = "Original/Untouched", crf = nil}, -- 'untouched' is for stream copying
    high = {name = "High Quality", crf = 18},
    medium = {name = "Medium Quality", crf = 23},
    low = {name = "Low Quality", crf = 28}
}
-- Default quality mode is always medium on script load
local current_quality_mode = "medium" 

-- Set initial CRF based on default quality mode
VIDEO_QUALITY_CRF = QUALITY_MODES[current_quality_mode].crf

-- Output format options and their default codecs
local OUTPUT_FORMAT_OPTIONS = {
    {format = "mp4", video_codec = "libx264", audio_codec = "aac"},
    {format = "mkv", video_codec = "libx264", audio_codec = "aac"}, 
    {format = "webm", video_codec = "libvpx-vp9", audio_codec = "libopus"},
    {format = "gif", video_codec = "gif", audio_codec = nil} -- gif is special, video-only
}
local current_format_index = 1 -- Default to mp4

local OUTPUT_FORMAT = OUTPUT_FORMAT_OPTIONS[current_format_index].format
local VIDEO_CODEC = OUTPUT_FORMAT_OPTIONS[current_format_index].video_codec
local AUDIO_CODEC = OUTPUT_FORMAT_OPTIONS[current_format_index].audio_codec

-- --- Helper Functions ---

-- OSD messages with logging
function show_osd_message(message, duration, type)
    local prefix = ""
    if type == "error" then
        prefix = "❗ Error: "
    elseif type == "success" then
        prefix = "✅ Success: "
    elseif type == "info" then
        prefix = "💬 Info: "
    else -- Default to info
        prefix = "ℹ️ "
    end
    
    mp.osd_message(prefix .. message, duration or 4)
    if type == "error" then
        msg.error(message)
    else
        msg.info(message)
    end
end

-- Nuke the temp file after we're done
function cleanup_temp_file()
    if utils.file_info(TEMP_VIDEO) then
        os.remove(TEMP_VIDEO)
        msg.info("Temporary file cleaned up: " .. TEMP_VIDEO)
    end
end

-- Make a clean filename from a path or URL
function get_clean_filename(path)
    local is_stream = path:match("^https?://") ~= nil
    local _, filename = utils.split_path(path)
    
    if is_stream then
        -- Decode URL-encoded characters
        filename = filename:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
        -- Remove query parameters and file extension
        filename = filename:gsub("%?.*$", ""):gsub("%.%w+$", "")
        if filename == "" then filename = "stream" end
    else
        -- Remove file extension for local files
        filename = filename:gsub("%.[^.]+$", "")
    end
    
    -- Replace invalid characters for filenames with an underscore
    filename = filename:gsub("[<>:\"/\\|?*]", "_")
    return filename
end

-- Checks if ffmpeg is available in the system's PATH
function check_ffmpeg_exists()
    local res = mp.command_native({
        name = "subprocess",
        args = {is_windows and "where" or "which", "ffmpeg"},
        capture_stdout = true,
        capture_stderr = true
    })
    return res.status == 0
end

-- Get info about active subtitle or audio track
function get_active_track_info(track_type)
    local tracks = mp.get_property_native("track-list") or {}
    local active_id_prop = (track_type == "sub") and "sid" or "aid"
    local active_id = mp.get_property(active_id_prop)
    
    -- The important bit: check if user actually disabled subs
    if track_type == "sub" then
        local current_sid = mp.get_property("sid")
        if not current_sid or current_sid == "no" then
            -- if sid is "no", don't burn anything in.
            return nil, false
        end
    end

    if active_id and active_id ~= "no" then
        for _, t in ipairs(tracks) do
            if t.type == track_type and tostring(t.id) == active_id then
                if track_type == "sub" and t.external then
                    return t["external-filename"], true -- External subtitle path
                else
                    return tostring(t.id), false -- Internal track ID
                end
            end
        end
    end

    -- Fallback for subtitles: check for auto-loaded external subs
    if track_type == "sub" then
        local sub_path = mp.get_property("sub-file")
        if sub_path and sub_path ~= "" and utils.file_info(sub_path) then
            return sub_path, true
        end
        for _, t in ipairs(tracks) do
            if t.type == "sub" and t["default"] and not t.external then
                return tostring(t.id), false
            end
        end
    end
    return nil, false
end

-- --- Core Functions ---

-- Sets the start time for the video cut
function set_start_time()
    -- Reset times to ensure a fresh selection
    start_time = nil
    end_time = nil
    start_time = mp.get_property_number("time-pos")
    if not start_time then
        show_osd_message("Failed to get start time. Make sure a video is playing.", 6, "error")
        return
    end
    show_osd_message(string.format("⏱️ Start Time: %.2f seconds", start_time), 3, "info")
    msg.info("Start time set to: " .. start_time)
end

-- Sets the end time for the video cut
function set_end_time()
    if not start_time then
        show_osd_message("Please set start time first (Ctrl+s).", 6, "error")
        return
    end
    end_time = mp.get_property_number("time-pos")
    if not end_time then
        show_osd_message("Failed to get end time.", 6, "error")
        return
    end
    if end_time <= start_time then
        show_osd_message("End time must be after start time.", 6, "error")
        end_time = nil -- Invalidate end_time if it's not logical
        return
    end
    show_osd_message(string.format("⏱️ End Time: %.2f seconds", end_time), 3, "info")
    msg.info("End time set to: " .. end_time)
end

-- Takes screenshots at start and end times
function take_screenshots()
    if not start_time or not end_time then
        show_osd_message("Please set start and end times to take screenshots.", 6, "error")
        return
    end

    local path = mp.get_property("path")
    if not path then
        show_osd_message("No video loaded.", 6, "error")
        return
    end

    local clean_name = get_clean_filename(path)
    local output_base_dir
    if current_output_mode == "default_dir" then
        output_base_dir = OUTPUT_DIR_DEFAULT
    else
        local dir, _ = utils.split_path(path)
        output_base_dir = dir
    end

    -- Ensure output directory exists
    if not utils.file_info(output_base_dir) then
        local mkdir_cmd = is_windows and 'mkdir "' .. output_base_dir .. '"' or "mkdir -p '" .. output_base_dir .. "'"
        local res = os.execute(mkdir_cmd)
        if res ~= 0 then
            show_osd_message("Failed to create output directory for screenshots: " .. output_base_dir, 6, "error")
            return
        end
    end

    local screenshot_start_file = utils.join_path(output_base_dir, string.format("%s_start_%.2f.jpg", clean_name, start_time))
    local screenshot_end_file = utils.join_path(output_base_dir, string.format("%s_end_%.2f.jpg", clean_name, end_time))

    show_osd_message("Taking screenshots...", 3, "info")

    -- Save current time, seek, screenshot, seek, screenshot, then restore time
    local current_pos = mp.get_property_number("time-pos")
    mp.set_property("pause", "yes") -- Pause to ensure correct frame capture

    mp.commandv("seek", start_time, "absolute", "keyframes")
    mp.commandv("screenshot-to-file", screenshot_start_file)
    show_osd_message(string.format("✅ Start Screenshot: %s", screenshot_start_file), 3, "success")

    mp.commandv("seek", end_time, "absolute", "keyframes")
    mp.commandv("screenshot-to-file", screenshot_end_file)
    show_osd_message(string.format("✅ End Screenshot: %s", screenshot_end_file), 3, "success")

    -- Restore original position and pause state
    mp.commandv("seek", current_pos, "absolute", "keyframes")
    mp.set_property("pause", "no")
    
    msg.info("Screenshots taken: " .. screenshot_start_file .. ", " .. screenshot_end_file)
end

-- Renders the selected portion of the video to a temporary file using MPV
-- This is where re-encoding happens (for subtitles, quality changes, etc.)
function render_video_with_mpv_reencode()
    local path = mp.get_property("path")
    if not path then
        show_osd_message("No video loaded.", 6, "error")
        return nil
    end

    -- Command generation logic
    local cmd = {
        "mpv", path,
        "--start=" .. tostring(start_time),
        "--end=" .. tostring(end_time),
        "--vo=lavc",
        "--o=" .. TEMP_VIDEO,
        "--of=" .. OUTPUT_FORMAT,
        "--ovc=" .. VIDEO_CODEC,
        (VIDEO_CODEC == "libx264" and "--ovcopts=crf=" .. VIDEO_QUALITY_CRF .. ",preset=medium,profile=main,level=3.1,tune=fastdecode") or
        (VIDEO_CODEC == "libvpx-vp9" and "--ovcopts=crf=" .. VIDEO_QUALITY_CRF .. ",speed=2,threads=4,row-mt=1") or
        (VIDEO_CODEC == "libaom-av1" and "--ovcopts=crf=" .. VIDEO_QUALITY_CRF .. ",preset=medium") or
        "",
        "--no-ocopy-metadata",
        "--quiet"
    }

    -- We'll build our video filter chain here
    local vf_chain = {}

    -- If there's a sub, add it to the filter chain
    local sub_info, is_external_sub = get_active_track_info("sub")
    if sub_info then
        table.insert(vf_chain, "sub") -- Add 'sub' filter to burn in the subtitles
        
        -- Add other subtitle-related options to the main command
        table.insert(cmd, "--sub-ass=yes")
        table.insert(cmd, "--sub-ass-force-style=Fonts=true")

        if is_external_sub and sub_info:match("^edl://") then
            show_osd_message("❗ Warning: Complex subtitle (edl://) detected. Skipping subtitle embedding to prevent hangs.", 6, "info")
            msg.warn("Skipping edl:// subtitle embedding in subprocess.")
        else
            if is_external_sub then
                table.insert(cmd, "--sub-file=" .. sub_info)
                msg.info("Using external subtitle: " .. sub_info)
            else
                table.insert(cmd, "--sid=" .. sub_info)
                msg.info("Using internal subtitle track: " .. sub_info)
            end
            local sub_delay = mp.get_property_number("sub-delay")
            if sub_delay and sub_delay ~= 0 then
                table.insert(cmd, "--sub-delay=" .. tostring(sub_delay))
                msg.info("Applying sub-delay: " .. tostring(sub_delay) .. " seconds.")
            end
        end
    else
        msg.info("No subtitle detected. Explicitly disabling subtitles in subprocess.")
        table.insert(cmd, "--no-sub")
    end

    -- Handle active audio track
    if AUDIO_CODEC then
        table.insert(cmd, "--oac=" .. AUDIO_CODEC)
        local audio_info, _ = get_active_track_info("audio")
        if audio_info then
            table.insert(cmd, "--aid=" .. audio_info)
            msg.info("Using audio track: " .. audio_info)
        else
            msg.info("No specific audio track detected, using default.")
        end
    else
        msg.info("No audio codec specified for current format. Skipping audio.")
        table.insert(cmd, "--no-audio")
    end

    -- Add current video filters from user's config to the chain
    local user_vf = mp.get_property("vf")
    if user_vf and user_vf ~= "" then
        table.insert(vf_chain, user_vf)
        msg.info("Applying user video filters: " .. user_vf)
    end

    -- yuv420p at the end for max compatibility
    table.insert(vf_chain, "format=yuv420p")

    -- Now, build the final --vf argument from the chain and add it to the command
    if #vf_chain > 0 then
        table.insert(cmd, "--vf=" .. table.concat(vf_chain, ","))
    end

    -- Filter out any empty strings that might have been added to the command table
    local filtered_cmd = {}
    for _, v in ipairs(cmd) do
        if v ~= "" then
            table.insert(filtered_cmd, v)
        end
    end
    cmd = filtered_cmd

    msg.info("Rendering video with MPV command: " .. table.concat(cmd, " "))
    show_osd_message("Step 1/2: Rendering video...", 0, "info")
    
    local res = mp.command_native({
        name = "subprocess",
        args = cmd,
        capture_stdout = true,
        capture_stderr = true
    })

    if res.status == 0 and utils.file_info(TEMP_VIDEO) then
        msg.info("Video successfully rendered to: " .. TEMP_VIDEO)
        show_osd_message("Step 1/2: Render complete.", 2, "info")
        return TEMP_VIDEO
    else
        show_osd_message("❗ Video rendering failed: " .. (res.stderr or "Unknown error"), 6, "error")
        cleanup_temp_file()
        return nil
    end
end

-- Main function to cut and save the video
function cut_video()
    if not start_time or not end_time then
        show_osd_message("Please set start and end times (Ctrl+s / Ctrl+e).", 6, "error")
        return
    end

    local path = mp.get_property("path")
    if not path then
        show_osd_message("No video loaded.", 6, "error")
        return
    end

    if not check_ffmpeg_exists() then
        show_osd_message("❗ FFmpeg not found. Please install it and ensure it's in your PATH.", 8, "error")
        return
    end

    local is_stream = path:match("^https?://") ~= nil
    local clean_name = get_clean_filename(path)
    
    local output_base_dir
    -- Set default output directory based on media type
    if is_stream then
        current_output_mode = "default_dir" -- Force default_dir for streams
        output_base_dir = OUTPUT_DIR_DEFAULT
    else
        -- If it's a local file, respect current_output_mode
        if current_output_mode == "default_dir" then
            output_base_dir = OUTPUT_DIR_DEFAULT
        else -- source_dir mode
            local dir, _ = utils.split_path(path)
            output_base_dir = dir
        end
    end

    -- Create output directory if it doesn't exist
    if not utils.file_info(output_base_dir) then
        local mkdir_cmd = is_windows and 'mkdir "' .. output_base_dir .. '"' or "mkdir -p '" .. output_base_dir .. "'"
        local res = os.execute(mkdir_cmd)
        if res ~= 0 then
            show_osd_message("❗ Failed to create output directory: " .. output_base_dir, 6, "error")
            return
        end
    end

    cut_counter = cut_counter + 1 -- Increment cut counter for unique filename
    local output_file = utils.join_path(
        output_base_dir,
        string.format("%s_%02d_%.2f-%.2f.%s", clean_name, cut_counter, start_time, end_time, OUTPUT_FORMAT)
    )

    msg.info("Original path: " .. path)
    msg.info("Clean filename: " .. clean_name)
    msg.info("Final output file: " .. output_file)

    local temp_file_for_ffmpeg = nil
    local sub_info, _ = get_active_track_info("sub")

    if current_quality_mode == "untouched" and not sub_info then
        -- Direct copy (untouched) if no subtitles are active
        show_osd_message("Cutting video (Direct Copy)...", 0, "info")
        temp_file_for_ffmpeg = path -- Use original file directly
        
        local cmd = {
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", tostring(start_time),
            "-to", tostring(end_time),
            "-i", temp_file_for_ffmpeg,
            "-c:v", "copy",
            "-c:a", "copy",
            "-movflags", "+faststart",
            output_file
        }

        -- Special handling for GIF output if untouched: ffmpeg conversion
        if OUTPUT_FORMAT == "gif" then
            show_osd_message("Warning: GIF output is video-only. Audio will be ignored.", 5, "info")
            cmd = {
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-ss", tostring(start_time),
                "-to", tostring(end_time),
                "-i", temp_file_for_ffmpeg,
                "-vf", "fps=10,scale=500:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse", -- Basic GIF conversion filters
                "-loop", "0", -- Loop forever
                output_file
            }
        end

        msg.info("Finalizing with direct FFmpeg command: " .. table.concat(cmd, " "))
        local res = mp.command_native({
            name = "subprocess",
            args = cmd,
            capture_stdout = true,
            capture_stderr = true
        })

        if res.status == 0 then
            show_osd_message("✅ Video cut saved successfully: " .. output_file, 8, "success")
        else
            show_osd_message("❌ Video cut failed: " .. (res.stderr or "Unknown error"), 8, "error")
            cut_counter = cut_counter - 1 
        end

    else
        -- Re-encode path (if not untouched, or if subtitles are active)
        if current_quality_mode == "untouched" and sub_info then
            show_osd_message("Subs enabled, can't use 'untouched'. Re-encoding at High quality.", 6, "info")
            VIDEO_QUALITY_CRF = QUALITY_MODES.high.crf -- Force high quality re-encode
        else
            VIDEO_QUALITY_CRF = QUALITY_MODES[current_quality_mode].crf
        end

        temp_file_for_ffmpeg = render_video_with_mpv_reencode()
        if not temp_file_for_ffmpeg then
            return -- render_video_with_mpv_reencode already handled the error
        end
        
        -- Use FFmpeg to quickly copy (remux) the temporary file to the final output
        show_osd_message("Step 2/2: Finalizing cut...", 0, "info")

        local cmd = {
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", temp_file_for_ffmpeg,
            "-c:v", "copy", -- Copy video stream without re-encoding
            "-c:a", "copy", -- Copy audio stream without re-encoding
            "-movflags", "+faststart", -- Optimize for web streaming
            "-pix_fmt", "yuv420p",    -- Ensure pixel format compatibility
            output_file
        }

        -- Special handling for GIF output if re-encoding
        if OUTPUT_FORMAT == "gif" then
            show_osd_message("Warning: GIF output is video-only. Audio will be ignored.", 5, "info")
            cmd = {
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-i", temp_file_for_ffmpeg,
                "-vf", "fps=10,scale=500:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                "-loop", "0", -- Loop forever
                output_file
            }
        end

        msg.info("Finalizing with FFmpeg command: " .. table.concat(cmd, " "))
        local res = mp.command_native({
            name = "subprocess",
            args = cmd,
            capture_stdout = true,
            capture_stderr = true
        })

        cleanup_temp_file() -- Always clean up the temp file

        if res.status == 0 then
            show_osd_message("✅ Video cut saved successfully: " .. output_file, 8, "success")
        else
            show_osd_message("❌ Finalizing video cut failed: " .. (res.stderr or "Unknown error"), 8, "error")
            cut_counter = cut_counter - 1 
        end
    end
end

-- --- Configuration Functions ---

-- Toggles output directory between default and source directory
function toggle_output_directory()
    local path = mp.get_property("path")
    local is_stream = path and path:match("^https?://") ~= nil

    if is_stream then
        show_osd_message("Cannot change output directory for streams. Always saves to Desktop/mpvstreamcut.", 3, "info")
        return
    end

    if current_output_mode == "default_dir" then
        current_output_mode = "source_dir"
        show_osd_message("Output path: Source file directory.", 3, "info")
    else
        current_output_mode = "default_dir"
        show_osd_message("Output path: Desktop/mpvstreamcut.", 3, "info")
    end
end

-- Sets video quality (CRF or untouched)
function set_video_quality(quality_key)
    current_quality_mode = quality_key
    local quality_info = QUALITY_MODES[quality_key]
    if quality_info then
        show_osd_message("Video Quality: " .. quality_info.name .. (quality_info.crf and " (CRF=" .. quality_info.crf .. ")" or ""), 3, "info")
        if quality_key ~= "untouched" then
            VIDEO_QUALITY_CRF = quality_info.crf
        end
    end
    msg.info("Set video quality mode to: " .. current_quality_mode)
end

-- Toggles output format and updates codecs
function toggle_output_format()
    current_format_index = current_format_index % #OUTPUT_FORMAT_OPTIONS + 1
    local selected_format = OUTPUT_FORMAT_OPTIONS[current_format_index]
    OUTPUT_FORMAT = selected_format.format
    VIDEO_CODEC = selected_format.video_codec
    AUDIO_CODEC = selected_format.audio_codec
    
    local audio_info_str = AUDIO_CODEC and (", Audio: " .. AUDIO_CODEC) or ""
    show_osd_message("Output Format: " .. OUTPUT_FORMAT .. 
                       " (Video: " .. VIDEO_CODEC .. audio_info_str .. ")", 4, "info")
    
    if OUTPUT_FORMAT == "gif" then
        local has_audio = mp.get_property_number("audio-active") ~= nil
        if has_audio then
            show_osd_message("Warning: GIF output is video-only. Audio will be ignored.", 5, "info")
        end
    end
    msg.info("Set output format to: " .. OUTPUT_FORMAT .. ", Video Codec: " .. VIDEO_CODEC .. ", Audio Codec: " .. tostring(AUDIO_CODEC))
end


-- Initialize output directory based on media type when a file is loaded
mp.observe_property("path", "string", function(_, path)
    if path then
        local is_stream = path:match("^https?://") ~= nil
        if is_stream then
            current_output_mode = "default_dir"
        else
            -- For local files, initially set to source directory
            current_output_mode = "source_dir" 
        end
    end
end)

-- --- Help Message Function ---
function show_help_message()
    local start_str = start_time and string.format("%.2f", start_time) or "Not Set"
    local end_str = end_time and string.format("%.2f", end_time) or "Not Set"
    local quality_str = QUALITY_MODES[current_quality_mode].name .. (QUALITY_MODES[current_quality_mode].crf and " (CRF=" .. QUALITY_MODES[current_quality_mode].crf .. ")" or "")
    local format_str = OUTPUT_FORMAT .. " (Video: " .. VIDEO_CODEC .. (AUDIO_CODEC and ", Audio: " .. AUDIO_CODEC or "") .. ")"

    local help_text = string.format([[
🎬 Advanced MPV Video Cutter Help:
  Selected Cut: %s - %s seconds
  Quality: %s
  Format: %s
  Ctrl+s: Set Cut Start Time
  Ctrl+e: Set Cut End Time
  Ctrl+x: Cut and Save Video
  Ctrl+p: Take Screenshots of Start/End Frames
  Ctrl+d: Toggle Output Directory (Default/Source)
  Ctrl+f: Toggle Output Format (MP4/MKV/WebM/GIF)
  Ctrl+Alt+0: Set Quality: Original/Untouched
  Ctrl+Alt+1: Set Quality: High
  Ctrl+Alt+2: Set Quality: Medium
  Ctrl+Alt+3: Set Quality: Low
  Ctrl+h: Show this Help Message
]], start_str, end_str, quality_str, format_str)
    mp.osd_message(help_text, 10, "info") -- Show for 10 seconds
end

-- --- Key Bindings ---
mp.add_key_binding("Ctrl+s", "set_start_time", set_start_time, {
    description = "Set cut start time"
})
mp.add_key_binding("Ctrl+e", "set_end_time", set_end_time, {
    description = "Set cut end time"
})
mp.add_key_binding("Ctrl+x", "cut_video", cut_video, {
    description = "Cut and save video"
})
mp.add_key_binding("Ctrl+p", "take_screenshots", take_screenshots, {
    description = "Take screenshots of start/end frames"
})
mp.add_key_binding("Ctrl+d", "toggle_output_dir", toggle_output_directory, {
    description = "Toggle output directory (Default/Source)"
})
mp.add_key_binding("Ctrl+f", "toggle_output_format", toggle_output_format, {
    description = "Toggle output format (MP4/MKV/WebM/GIF)"
})

-- Quality settings key bindings
mp.add_key_binding("Ctrl+Alt+0", "set_quality_untouched", function() set_video_quality("untouched") end, {
    description = "Set video quality: Original/Untouched"
})
mp.add_key_binding("Ctrl+Alt+1", "set_quality_high", function() set_video_quality("high") end, {
    description = "Set video quality: High"
})
mp.add_key_binding("Ctrl+Alt+2", "set_quality_medium", function() set_video_quality("medium") end, {
    description = "Set video quality: Medium"
})
mp.add_key_binding("Ctrl+Alt+3", "set_quality_low", function() set_video_quality("low") end, {
    description = "Set video quality: Low"
})

-- Help message key binding
mp.add_key_binding("Ctrl+h", "show_help", show_help_message, {
    description = "Show script help message"
})


-- --- MPV Menu Integration ---
-- Function to create menu entries for options
local function create_menu_entry(name, func, description)
    mp.add_key_binding(nil, name, func, {
        description = description,
        complex = true,
        menu = true
    })
end

create_menu_entry("cutter_set_start", set_start_time, "Set Cut Start Time (Ctrl+s)")
create_menu_entry("cutter_set_end", set_end_time, "Set Cut End Time (Ctrl+e)")
create_menu_entry("cutter_cut_video", cut_video, "Cut and Save Video (Ctrl+x)")
create_menu_entry("cutter_take_screenshots", take_screenshots, "Take Screenshots (Ctrl+p)")
create_menu_entry("cutter_toggle_output_dir", toggle_output_directory, "Toggle Output Directory (Ctrl+d)")
create_menu_entry("cutter_toggle_output_format", toggle_output_format, "Toggle Output Format (Ctrl+f)")
create_menu_entry("cutter_set_quality_untouched", function() set_video_quality("untouched") end, "Set Quality: Original/Untouched (Ctrl+Alt+0)")
create_menu_entry("cutter_set_quality_high", function() set_video_quality("high") end, "Set Quality: High (Ctrl+Alt+1)")
create_menu_entry("cutter_set_quality_medium", function() set_video_quality("medium") end, "Set Quality: Medium (Ctrl+Alt+2)")
create_menu_entry("cutter_set_quality_low", function() set_video_quality("low") end, "Set Quality: Low (Ctrl+Alt+3)")
create_menu_entry("cutter_show_help", show_help_message, "Show Help Message (Ctrl+h)")


-- --- Initial Setup on MPV Load ---
-- No noisy startup messages. Use Ctrl+h for help.
-- Quality defaults to medium, no persistence.
-- Output directory is set by the file observer.
