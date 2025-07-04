# Advanced MPV Video Cutter

An advanced Lua script for [mpv media player](https://mpv.io/) that allows you to easily cut video clips from local files or streams, change the output format, adjust quality, and more.

## Features

* **Precise Cutting:** Set start (`Ctrl+s`) and end (`Ctrl+e`) times for your clip.
* **Quick Save:** Save the selected portion by pressing `Ctrl+x`.
* **Multiple Formats:** Switch between MP4, MKV, WebM, and GIF formats (`Ctrl+f`).
* **Quality Control:** Choose the output quality between untouched, high, medium, and low modes (`Ctrl+Alt+0/1/2/3`).
* **Screenshots:** Take screenshots of the start and end frames of the clip (`Ctrl+p`).
* **Changeable Output Path:** Toggle the save location between the source file's directory and a default folder on the Desktop (`Ctrl+d`).
* **Full Subtitle Support:** Active subtitles (internal or external) are automatically hardcoded into the video.
* **Preserves Video Filters:** Your active video filters (like crop, rotate) are applied to the output.
* **Stream Support:** Easily create clips from online streams.
* **Built-in Help:** Display a help message with all shortcuts (`Ctrl+h`).

## Requirements

* [mpv](https://mpv.io/) media player
* [FFmpeg](https://ffmpeg.org/) installed (must be accessible in your system's PATH)

## Installation

1.  Place the script file (`.lua`) in mpv's scripts directory:
    * **Linux/macOS:** `~/.config/mpv/scripts/`
    * **Windows:** `%APPDATA%\mpv\scripts\`
2.  Ensure FFmpeg is correctly installed and accessible from the command line.

## Hotkeys and Usage

| Hotkey           | Action                                        |
| ---------------- | --------------------------------------------- |
| `Ctrl+s`         | Set the **start** time for the cut            |
| `Ctrl+e`         | Set the **end** time for the cut              |
| `Ctrl+x`         | **Cut and save** the video clip               |
| `Ctrl+p`         | Take **screenshots** of start/end frames      |
| `Ctrl+f`         | Change the output **format** (MP4/MKV/WebM/GIF) |
| `Ctrl+d`         | Change the output **directory** (Source/Desktop) |
| `Ctrl+Alt+0`     | Set Quality: **Untouched** |
| `Ctrl+Alt+1`     | Set Quality: **High** |
| `Ctrl+Alt+2`     | Set Quality: **Medium** (Default)             |
| `Ctrl+Alt+3`     | Set Quality: **Low** |
| `Ctrl+h`         | Show **Help** |

> **Note:** For frame-by-frame accuracy, you can use this script alongside scripts like [mpv-frame-stepper](https://github.com/OHIOXOIHO/mpv-frame-stepper).

## Additional Notes

* **Untouched Quality:** This mode copies the video and audio streams without any re-compression (very fast). This mode only works when **no** subtitles are active. If subtitles are enabled, the script will automatically switch to High quality.
* **GIF Output:** This format is video-only; audio will be discarded.
* **Temporary Files:** Temporary files created during the process are automatically cleaned up afterward.
* **File Naming:** The output file is named with the pattern `[filename]_[counter]_[start]-[end].[format]`.

## License

MIT License
