# JumpSkip

A powerful, lightweight Lua script for **MPV** that detects and skips media segments (intros, recaps, outros/credits, and previews) using crowdsourced timestamp data from **TheIntroDB**, **IntroDB**, and **SkipDB**.

<img width="1920" height="1080" alt="Screenshot (123)" src="https://github.com/user-attachments/assets/56985e56-e17a-4786-a118-e9de9c653bee" />


OSC by [ModernZ](https://github.com/Samillion/ModernZ)

## Features

- **Multi Provider Integration**:
  - **TheIntroDB** (`https://api.theintrodb.org/v3/media`) — supports TV episodes and movies with weighted average consensus times.
  - **IntroDB** (`https://api.introdb.app/segments`) — public community timestamps for TV show episodes.
  - **SkipDB** (`https://api.skipdb.tv/api/segments`) — crowd-sourced intro, recap, outro & preview timestamps for TV and movies.
- **Intelligent Fallback & Merging**:
  - Configurable provider priority (`theintrodb,introdb,skipdb` or in any order).
  - Seamless fallback: if the primary provider has no match or encounters a network error, the script automatically queries the next provider.
  - **Segment Merging**: If the primary provider has an intro but lacks an outro or recap, the script queries subsequent providers to fill in missing segment types.
- **Non-Blocking Asynchronous HTTP**:
  - HTTP requests are performed asynchronously in the background using mpv's native `mp.command_native_async` with system `curl`.
  - Zero UI freezing, stuttering, or playback interruptions.
- **Interactive On-Screen Clickable Button**:
  - Netflix-style semi-transparent vector card (ASS overlay), vibrant glow accent, and clear labels (`Skip Intro ▶`, `Skip Outro ▶`, etc.).
  - **Non-Intrusive Click Capture**: Left mouse button (`MBTN_LEFT`) is dynamically hooked **only** while the cursor hovers directly over the button, ensuring normal mpv click interactions across the rest of the player window remain completely undisturbed.
- **Keyboard Shortcut**:
  - Instant skipping via configurable keybind (default: `Tab`).
- **Configurable Auto-Skip**:
  - Option to automatically skip segments when playback enters them (enabled in jumpskip.conf).
  - Optional countdown timer before auto-skipping, with on-screen visual feedback.
- **Smart Media Identification**:
  - Reads embedded file metadata tags (`IMDB`, `TMDB_ID`, `TVDB_ID`, `SEASON`, `EPISODE`, etc.).
  - Parses filenames and folder paths for IMDb IDs (`tt0903747`), TMDb/TVDb tags (`{tmdb-12345}`), season/episode notation (`S01E02`, `1x02`, `Season 1 Episode 2`), and movie release years.
  - Zero-config title-to-ID fallback lookup via Cinemeta or optional TMDb API.
- **Fully Configurable**:
  - Fine-tune timing offsets, segment toggles, provider priorities, timeouts, colors, and button positions via `script-opts/jumpskip.conf`.

---

## Dependencies

- **mpv**: v0.29.0 or newer (tested with mpv v0.41.0).
- **curl**: Used for asynchronous HTTP requests.
  - **Windows 10/11**: Built-in system tool (preinstalled in `System32`).
  - **Linux / macOS**: Standard package (`sudo apt install curl` or `brew install curl`).

---

## Installation

### For Portable mpv:
1. Copy `jumpskip.lua` into your mpv `scripts` directory:

   `mpv/portable_config/scripts/jumpskip.lua`
   
2. Copy `jumpskip.conf` into your mpv `script-opts` directory:

   `mpv/portable_config/script-opts/jumpskip.conf`
   

### For Standard System mpv:
- **Windows**:
  - Script: `%APPDATA%\mpv\scripts\jumpskip.lua`
  - Config: `%APPDATA%\mpv\script-opts\jumpskip.conf`
- **Linux / macOS**:
  - Script: `~/.config/mpv/scripts/jumpskip.lua`
  - Config: `~/.config/mpv/script-opts/jumpskip.conf`

---

## Configuration (`jumpskip.conf`)

Create or edit `~~/script-opts/jumpskip.conf`:

```ini
# Master toggle
enabled=yes

# Auto-skip behavior:
# Set to 'yes' to automatically skip segments when entering them without clicking.
# Set to 'no' to display the on-screen button and wait for click or keybind.
auto_skip=no

# Countdown before auto-skipping (in seconds, 0 = instant):
auto_skip_countdown=0

# Segment types to detect:
skip_intro=yes
skip_recap=yes
skip_outro=yes
skip_preview=no

# Timing offsets (in seconds):
# - start_offset: negative (e.g. -0.5) triggers button earlier; positive triggers later.
# - end_offset: seconds added or subtracted to the jump target timestamp.
start_offset=0.0
end_offset=0.0

# Provider priority order ('theintrodb,introdb,skipdb' or any subset/order):
provider_priority=theintrodb,introdb,skipdb

# Merge providers (yes/no):
# If yes, supplements missing segments from secondary provider.
merge_providers=yes

# Optional API Keys:
theintrodb_api_key=
introdb_api_key=
skipdb_api_key=
tmdb_api_key=

# Network timeout (seconds):
request_timeout=8

# Keybinding:
keybind=Tab

# Minimum segment duration to consider valid (seconds):
min_segment_duration=3.0

# Button position: 'bottom-right', 'bottom-left', 'top-right', 'top-left'
button_position=bottom-right
button_margin_x=60
button_margin_y=80

# Visual Colors (Hex BGR format for ASS styling):
accent_color=E75C6C
bg_color=0A0A0A
text_color=FFFFFF
hint_color=AAAAAA

# OSD notification on skip:
show_osd_message=yes
osd_message_duration=2.0

# Debug logging to mpv terminal:
debug_mode=no
```
---

## API Reference & Alignment

### 1. TheIntroDB (`theintrodb.org`)
- **Endpoint**: `GET https://api.theintrodb.org/v3/media`
- **Parameters**: `tmdb_id`, `imdb_id`, `tvdb_id`, `season`, `episode`, `duration_ms`
- **Response Format**:
  - `intro`: array of `{ start_ms, end_ms }`
  - `recap`: array of `{ start_ms, end_ms }`
  - `credits`: array of `{ start_ms, end_ms }` (mapped to Outro/Credits)
  - `preview`: array of `{ start_ms, end_ms }`
- **Auth**: Optional `Authorization: Bearer <token>`

### 2. IntroDB (`introdb.app`)
- **Endpoint**: `GET https://api.introdb.app/segments`
- **Parameters**: `imdb_id` (`^tt[0-9]{7,8}`), `season`, `episode`
- **Response Format**:
  - `intro`: `{ start_ms, end_ms, start_sec, end_sec, confidence }`
  - `recap`: `{ start_ms, end_ms, start_sec, end_sec, confidence }`
  - `outro`: `{ start_ms, end_ms, start_sec, end_sec, confidence }`
- **Auth**: Optional `X-API-Key: idb_...`

### 3. SkipDB (`skipdb.tv`)
- **Endpoint**: `GET https://api.skipdb.tv/api/segments`
- **Parameters**: `imdb_id` (required), `season`, `episode`, `duration` (stream length in seconds)
- **Response Format**: `segments` object with keys `intro`, `recap`, `outro`, `preview`:
  - Each: `{ start_ms, end_ms, confidence, match, adjusted, offset_ms }` or `null`
  - `start_ms: 0, end_ms: 0` = sentinel for "confirmed: no segment of this type"
- **Auth**: Open for reading (120 req/min). Optional `Authorization: Bearer skdb_...` or `X-API-Key: skdb_...` for writing.

---

## Script Messages

You can trigger actions externally via `mpv --input-ipc-server` or input bindings:
- `script-message skip-segment`: Trigger skip for the active segment.
- `script-message reload-segments`: Re-fetch segment timestamps for current media.

## Contributing

Suggestions and contributions are welcome. Feel free to open an [issue](https://github.com/ElectricArdvark/jumpskip/issues) or submit a [pull request](https://github.com/ElectricArdvark/jumpskip/pulls).
