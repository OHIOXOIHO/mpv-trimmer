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

-- Seed for random temp file generation
math.randomseed(os.time())

-- --- Output Settings ---
-- Quality modes and their corresponding CRF values
local QUALITY_MODES = {
    untouched = {name = "Original/Untouched", crf = nil}, -- 'untouched' is for stream copying
    high = {name = "High Quality", crf = 18},
    medium = {name = "Medium Quality", crf = 23},
    low = {name = "Low Quality", crf = 28}
}
-- Default quality mode is always medium on script load
local current_quality_mode = "medium" 
local VIDEO_QUALITY_CRF = QUALITY_MODES[current_quality_mode].crf

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

-- State variables for async processing
local is_processing = false
local progress_timer = nil
local process_start_time = 0

-- --- Helper Functions ---

-- Progress OSD timer (Shows animated spinner and elapsed time)
local function start_progress_osd(msg_text)
    local frames = {"|", "/", "-", "\\"}
    local i = 1
    process_start_time = os.time()
    
    progress_timer = mp.add_periodic_timer(0.5, function()
        local elapsed = os.time() - process_start_time
        mp.osd_message(string.format("⏳ %s (Elapsed: %ds) %s", msg_text, elapsed, frames[i]), 0.6)
        i = i % 4 + 1
    end)
end

local function stop_progress_osd()
    if progress_timer then
        progress_timer:kill()
        progress_timer = nil
    end
end

-- OSD messages with logging and Emojis
local function show_osd_message(message, duration, type)
    local prefix = ""
    if type == "error" then
        prefix = "❗ Error: "
    elseif type == "success" then
        prefix = "✅ Success: "
    elseif type == "info" then
        prefix = "💬 Info: "
    else
        prefix = "ℹ️ "
    end
    
    mp.osd_message(prefix .. message, duration or 4)
    
    if type == "error" then
        msg.error(message)
    else
        msg.info(message)
    end
end

-- Generates a unique temporary file path
local function get_temp_file_path()
    local temp_dir = os.getenv("TEMP") or "/tmp"
    local rand_num = math.random(100000, 999999)
    return utils.join_path(temp_dir, string.format("mpv_trim_temp_%06d.mkv", rand_num))
end

-- Nuke the temp file after we're done
local function cleanup_temp_file(filepath)
    if filepath and utils.file_info(filepath) then
        os.remove(filepath)
        msg.info("Temporary file cleaned up: " .. filepath)
    end
end

-- Make a clean filename from a path or URL
local function get_clean_filename(path)
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
local function check_ffmpeg_exists()
    local res = mp.command_native({
        name = "subprocess",
        args = {is_windows and "where" or "which", "ffmpeg"},
        capture_stdout = true,
        capture_stderr = true
    })
    return res.status == 0
end

-- Detects if the currently playing file is audio-only (like MP3/FLAC)
local function is_audio_only_file()
    local tracks = mp.get_property_native("track-list") or {}
    for _, t in ipairs(tracks) do
        if t.type == "video" and t.albumart ~= "yes" then
            return false -- It has a real video track
        end
    end
    return true -- It's audio-only (or audio with cover art)
end

-- Get info about active subtitle or audio track
local function get_active_track_info(track_type)
    local tracks = mp.get_property_native("track-list") or {}
    local active_id_prop = (track_type == "sub") and "sid" or "aid"
    local active_id = mp.get_property(active_id_prop)
    
    -- The important bit: check if user actually disabled subs
    if track_type == "sub" then
        local current_sid = mp.get_property("sid")
        if not current_sid or current_sid == "no" then
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
    end
    return nil, false
end

-- Injects user's custom subtitle styles from mpv.conf to the render command
local function inject_user_subtitle_styles(cmd_table)
    local sub_props = {
        "sub-font", "sub-font-size", "sub-color", "sub-border-color",
        "sub-border-size", "sub-shadow-color", "sub-shadow-offset",
        "sub-bold", "sub-italic", "sub-margin-y", "sub-margin-x"
    }
    for _, prop in ipairs(sub_props) do
        local val = mp.get_property(prop)
        if val and val ~= "" then
            table.insert(cmd_table, "--" .. prop .. "=" .. tostring(val))
        end
    end
end

-- --- Core Functions ---

-- Sets the start time for the video cut
local function set_start_time()
    start_time = mp.get_property_number("time-pos")
    if not start_time then
        show_osd_message("Failed to get start time. Make sure media is playing.", 6, "error")
        return
    end
    end_time = nil -- Reset end time for a fresh selection
    show_osd_message(string.format("⏱️ Start Time: %.2f seconds", start_time), 3, "info")
end

-- Sets the end time for the video cut
local function set_end_time()
    if not start_time then
        show_osd_message("Please set start time first (Ctrl+s).", 6, "error")
        return
    end
    local temp_end = mp.get_property_number("time-pos")
    if not temp_end or temp_end <= start_time then
        show_osd_message("End time must be after start time.", 6, "error")
        return
    end
    end_time = temp_end
    show_osd_message(string.format("⏱️ End Time: %.2f seconds", end_time), 3, "info")
end

-- Final step: copy from the temporary re-encoded file to the final output file
local function finalize_video_reencode(temp_file, output_file, gif_filter)
    local cmd = {
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", temp_file,
        "-c:v", "copy", -- Copy video stream without re-encoding
        "-c:a", "copy", -- Copy audio stream without re-encoding
        "-movflags", "+faststart", -- Optimize for web streaming
        "-pix_fmt", "yuv420p",    -- Ensure pixel format compatibility
        output_file
    }

    -- Special handling for GIF output if re-encoding
    if OUTPUT_FORMAT == "gif" then
        cmd = {
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", temp_file,
            "-vf", gif_filter,
            "-loop", "0", -- Loop forever
            output_file
        }
    end

    mp.command_native_async({
        name = "subprocess",
        args = cmd,
        capture_stderr = true
    }, function(success, res, err)
        stop_progress_osd()
        is_processing = false
        cleanup_temp_file(temp_file)
        
        if success and res and res.status == 0 then
            show_osd_message("Video cut saved successfully: " .. get_clean_filename(output_file), 8, "success")
        else
            show_osd_message("Finalizing video cut failed. Check console for details.", 8, "error")
            if res and res.stderr then msg.error(res.stderr) end
            cut_counter = cut_counter - 1 
        end
    end)
end

-- Renders the selected portion of the video to a temporary file using MPV (Async)
local function render_video_async(temp_video_path, output_file, gif_filter)
    local path = mp.get_property("path")
    
    local cmd = {
        "mpv", path,
        "--start=" .. tostring(start_time),
        "--end=" .. tostring(end_time),
        "--vo=lavc",
        "--o=" .. temp_video_path,
        "--of=matroska", -- Using MKV as intermediate container is safest
        "--ovc=" .. VIDEO_CODEC,
        (VIDEO_CODEC == "libx264" and "--ovcopts=crf=" .. VIDEO_QUALITY_CRF .. ",preset=medium,profile=main,level=3.1,tune=fastdecode") or
        (VIDEO_CODEC == "libvpx-vp9" and "--ovcopts=crf=" .. VIDEO_QUALITY_CRF .. ",speed=2,threads=4,row-mt=1") or
        "",
        "--msg-level=all=error" -- Prevent RAM buffer overflow on long renders
    }

    -- Build the video filter chain
    local vf_chain = {}
    local sub_info, is_external_sub = get_active_track_info("sub")
    
    if sub_info then
        table.insert(vf_chain, "sub") -- Add 'sub' filter to burn in the subtitles
        table.insert(cmd, "--sub-ass=yes")
        
        -- Inject user's subtitle styling
        inject_user_subtitle_styles(cmd)

        if not (is_external_sub and sub_info:match("^edl://")) then
            if is_external_sub then
                table.insert(cmd, "--sub-file=" .. sub_info)
            else
                table.insert(cmd, "--sid=" .. sub_info)
            end
            
            -- Apply subtitle delay if set in player
            local sub_delay = mp.get_property_number("sub-delay")
            if sub_delay and sub_delay ~= 0 then
                table.insert(cmd, "--sub-delay=" .. tostring(sub_delay))
            end
        end
    else
        table.insert(cmd, "--no-sub")
    end

    -- Handle active audio track and delay
    if AUDIO_CODEC then
        table.insert(cmd, "--oac=" .. AUDIO_CODEC)
        local audio_info, _ = get_active_track_info("audio")
        if audio_info then table.insert(cmd, "--aid=" .. audio_info) end
        
        -- Apply audio delay if set in player
        local audio_delay = mp.get_property_number("audio-delay")
        if audio_delay and audio_delay ~= 0 then
            table.insert(cmd, "--audio-delay=" .. tostring(audio_delay))
        end
    else
        table.insert(cmd, "--no-audio")
    end

    -- Add current video filters from user's config to the chain
    local user_vf = mp.get_property("vf")
    if user_vf and user_vf ~= "" then
        table.insert(vf_chain, user_vf)
    end
    table.insert(vf_chain, "format=yuv420p")

    if #vf_chain > 0 then
        table.insert(cmd, "--vf=" .. table.concat(vf_chain, ","))
    end

    -- Filter out any empty strings
    local final_cmd = {}
    for _, v in ipairs(cmd) do
        if v ~= "" then table.insert(final_cmd, v) end
    end

    -- Start the background rendering
    mp.command_native_async({
        name = "subprocess",
        args = final_cmd,
        capture_stderr = true
    }, function(success, res, err)
        if success and res and res.status == 0 and utils.file_info(temp_video_path) then
            stop_progress_osd()
            start_progress_osd("Finalizing cut...")
            finalize_video_reencode(temp_video_path, output_file, gif_filter)
        else
            stop_progress_osd()
            is_processing = false
            cleanup_temp_file(temp_video_path)
            show_osd_message("Video rendering failed. File might be too complex.", 6, "error")
            if res and res.stderr then msg.error(res.stderr) end
        end
    end)
end

-- Main function to cut and save the media
local function cut_video()
    if is_processing then
        show_osd_message("A process is already running. Please wait...", 4, "error")
        return
    end

    if not start_time or not end_time then
        show_osd_message("Please set start and end times (Ctrl+s / Ctrl+e).", 6, "error")
        return
    end
    
    local path = mp.get_property("path")
    if not check_ffmpeg_exists() then
        show_osd_message("❗ FFmpeg not found. Please install it and ensure it's in your PATH.", 8, "error")
        return
    end

    local clean_name = get_clean_filename(path)
    local output_base_dir = current_output_mode == "default_dir" and OUTPUT_DIR_DEFAULT or select(1, utils.split_path(path))
    
    -- Force stream outputs to the default directory
    if path:match("^https?://") ~= nil then
        output_base_dir = OUTPUT_DIR_DEFAULT
    end

    -- Create output directory if it doesn't exist
    if not utils.file_info(output_base_dir) then
        local mkdir_cmd = is_windows and 'mkdir "' .. output_base_dir .. '"' or "mkdir -p '" .. output_base_dir .. "'"
        os.execute(mkdir_cmd)
        if not utils.file_info(output_base_dir) then
            show_osd_message("❗ Failed to create output directory.", 6, "error")
            return
        end
    end

    cut_counter = cut_counter + 1 
    
    -- --- Handling Audio-Only Files ---
    if is_audio_only_file() then
        is_processing = true
        start_progress_osd("Cutting Audio...")
        
        -- Detect the original audio extension
        local ext = path:match("^.+%.([^.]+)$") or "mp3"
        local output_file = utils.join_path(output_base_dir, string.format("%s_%02d_%.2f-%.2f.%s", clean_name, cut_counter, start_time, end_time, ext))
        
        local cmd = {
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", tostring(start_time),
            "-to", tostring(end_time),
            "-i", path,
            "-c", "copy",          -- Copy all streams directly
            "-map_metadata", "0",  -- Keep all original metadata (Album art, Artist, etc.)
            output_file
        }
        
        mp.command_native_async({
            name = "subprocess",
            args = cmd,
            capture_stderr = true
        }, function(success, res, err)
            stop_progress_osd()
            is_processing = false
            if success and res and res.status == 0 then
                show_osd_message("✅ Audio cut saved successfully: " .. get_clean_filename(output_file), 5, "success")
            else
                show_osd_message("❌ Audio cut failed.", 6, "error")
                if res and res.stderr then msg.error(res.stderr) end
            end
        end)
        return
    end

    -- --- Handling Video Files ---
    local output_file = utils.join_path(output_base_dir, string.format("%s_%02d_%.2f-%.2f.%s", clean_name, cut_counter, start_time, end_time, OUTPUT_FORMAT))
    local sub_info, _ = get_active_track_info("sub")
    
    -- Optimized GIF filter for Telegram and web (Dynamic scaling + Bayer dither)
    local gif_filter = "fps=15,scale='if(gt(iw,ih),500,-2)':'if(gt(iw,ih),-2,500)':flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5"

    if current_quality_mode == "untouched" and not sub_info then
        -- Direct Copy Mode (No re-encoding)
        is_processing = true
        start_progress_osd("Cutting Video (Direct Copy)...")
        
        local cmd = {
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", tostring(start_time),
            "-to", tostring(end_time),
            "-i", path,
            "-c:v", "copy",
            "-c:a", "copy",
            "-map_metadata", "0",
            "-movflags", "+faststart",
            output_file
        }

        if OUTPUT_FORMAT == "gif" then
            show_osd_message("💬 Info: GIF output is video-only. Audio will be ignored.", 5, "info")
            cmd = {
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-ss", tostring(start_time),
                "-to", tostring(end_time),
                "-i", path,
                "-vf", gif_filter,
                "-loop", "0",
                output_file
            }
        end

        mp.command_native_async({
            name = "subprocess",
            args = cmd,
            capture_stderr = true
        }, function(success, res, err)
            stop_progress_osd()
            is_processing = false
            if success and res and res.status == 0 then
                show_osd_message("✅ Video cut saved successfully: " .. get_clean_filename(output_file), 5, "success")
            else 
                show_osd_message("❌ Video cut failed. Check console.", 5, "error")
                if res and res.stderr then msg.error(res.stderr) end
                cut_counter = cut_counter - 1 
            end
        end)
    else
        -- Re-encode Mode (Applying subtitles or changing quality)
        if current_quality_mode == "untouched" and sub_info then
            show_osd_message("💬 Subs are active, fallback to High quality re-encode.", 4, "info")
            VIDEO_QUALITY_CRF = QUALITY_MODES.high.crf
        else
            VIDEO_QUALITY_CRF = QUALITY_MODES[current_quality_mode].crf
        end

        is_processing = true
        start_progress_osd("Rendering Video...")
        local temp_file = get_temp_file_path()
        render_video_async(temp_file, output_file, gif_filter)
    end
end

-- --- Configuration Functions ---

-- Toggles output directory between default and source directory
local function toggle_output_directory()
    local path = mp.get_property("path")
    if path and path:match("^https?://") ~= nil then
        show_osd_message("Cannot change output directory for streams. Always saves to Desktop.", 3, "info")
        return
    end
    
    if current_output_mode == "default_dir" then
        current_output_mode = "source_dir"
        show_osd_message("💬 Output path: Source file directory.", 3, "info")
    else
        current_output_mode = "default_dir"
        show_osd_message("💬 Output path: Desktop/mpvstreamcut.", 3, "info")
    end
end

-- Sets video quality (CRF or untouched)
local function set_video_quality(quality_key)
    current_quality_mode = quality_key
    local quality_info = QUALITY_MODES[quality_key]
    
    if quality_info then
        show_osd_message("💬 Video Quality: " .. quality_info.name .. (quality_info.crf and " (CRF=" .. quality_info.crf .. ")" or ""), 3, "info")
        if quality_key ~= "untouched" then
            VIDEO_QUALITY_CRF = quality_info.crf
        end
    end
end

-- Toggles output format and updates codecs
local function toggle_output_format()
    current_format_index = current_format_index % #OUTPUT_FORMAT_OPTIONS + 1
    local sel = OUTPUT_FORMAT_OPTIONS[current_format_index]
    OUTPUT_FORMAT = sel.format
    VIDEO_CODEC = sel.video_codec
    AUDIO_CODEC = sel.audio_codec
    
    local audio_info_str = AUDIO_CODEC and (", Audio: " .. AUDIO_CODEC) or ""
    show_osd_message("💬 Output Format: " .. OUTPUT_FORMAT .. " (Video: " .. VIDEO_CODEC .. audio_info_str .. ")", 4, "info")
end

-- Auto-set output directory based on stream/local file
mp.observe_property("path", "string", function(_, path)
    if path then
        current_output_mode = (path:match("^https?://") ~= nil) and "default_dir" or "source_dir"
    end
end)

-- --- Help Message Function ---
local function show_help_message()
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
  Ctrl+d: Toggle Output Directory (Default/Source)
  Ctrl+f: Toggle Output Format (MP4/MKV/WebM/GIF)
  Ctrl+Alt+0: Set Quality: Original/Untouched
  Ctrl+Alt+1: Set Quality: High
  Ctrl+Alt+2: Set Quality: Medium
  Ctrl+Alt+3: Set Quality: Low
  Ctrl+h: Show this Help Message
]], start_str, end_str, quality_str, format_str)
    mp.osd_message(help_text, 10, "info")
end

-- --- Key Bindings ---
mp.add_key_binding("Ctrl+s", "set_start_time", set_start_time)
mp.add_key_binding("Ctrl+e", "set_end_time", set_end_time)
mp.add_key_binding("Ctrl+x", "cut_video", cut_video)
mp.add_key_binding("Ctrl+d", "toggle_output_dir", toggle_output_directory)
mp.add_key_binding("Ctrl+f", "toggle_output_format", toggle_output_format)

-- Quality settings key bindings
mp.add_key_binding("Ctrl+Alt+0", "set_quality_untouched", function() set_video_quality("untouched") end)
mp.add_key_binding("Ctrl+Alt+1", "set_quality_high", function() set_video_quality("high") end)
mp.add_key_binding("Ctrl+Alt+2", "set_quality_medium", function() set_video_quality("medium") end)
mp.add_key_binding("Ctrl+Alt+3", "set_quality_low", function() set_video_quality("low") end)

mp.add_key_binding("Ctrl+h", "show_help", show_help_message)

-- --- MPV Menu Integration ---
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
create_menu_entry("cutter_toggle_output_dir", toggle_output_directory, "Toggle Output Directory (Ctrl+d)")
create_menu_entry("cutter_toggle_output_format", toggle_output_format, "Toggle Output Format (Ctrl+f)")
create_menu_entry("cutter_set_quality_untouched", function() set_video_quality("untouched") end, "Set Quality: Original/Untouched (Ctrl+Alt+0)")
create_menu_entry("cutter_set_quality_high", function() set_video_quality("high") end, "Set Quality: High (Ctrl+Alt+1)")
create_menu_entry("cutter_set_quality_medium", function() set_video_quality("medium") end, "Set Quality: Medium (Ctrl+Alt+2)")
create_menu_entry("cutter_set_quality_low", function() set_video_quality("low") end, "Set Quality: Low (Ctrl+Alt+3)")
create_menu_entry("cutter_show_help", show_help_message, "Show Help Message (Ctrl+h)")
