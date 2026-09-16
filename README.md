# JumpSkip

A powerful, lightweight Lua script for **MPV** that detects and skips media segments (intros, recaps, outros/credits, and previews) using crowdsourced timestamp data from **TheIntroDB**, **IntroDB**, and **SkipDB**.

OSC by [ModernZ](https://github.com/Samillion/ModernZ).

<img width="1920" height="1080" alt="Screenshot (123)" src="https://github.com/user-attachments/assets/56985e56-e17a-4786-a118-e9de9c653bee" />
<img width="1920" height="1080" alt="Screenshot (124)" src="https://github.com/user-attachments/assets/d17be605-5bd0-469b-a948-306f1d72fd32" />

> [!IMPORTANT]
> **Colored Segments work only using a modified ModernZ** [Guide](https://github.com/ElectricArdvark/jumpskip/wiki/Colored-Segments).
 
<img width="24" height="24" alt="output-onlinepngtools" src="https://github.com/user-attachments/assets/7455cd12-811c-4446-b1d9-640f4ef13a61" /> Intro

<img width="24" height="24" alt="output-onlinepngtools (1)" src="https://github.com/user-attachments/assets/3b07a45b-72b1-488e-8510-b062d23b442b" /> Recap

<img width="24" height="24" alt="output-onlinepngtools (2)" src="https://github.com/user-attachments/assets/423b4958-3686-4795-b721-a6bcc3c322b9" /> Outro/Credits

<img width="24" height="24" alt="output-onlinepngtools (3)" src="https://github.com/user-attachments/assets/8e9ba2fd-bceb-4426-a26c-b0c3bbe367bc" /> Preview


All colors changeable in **modernz.conf**

---

### My [MPV Config](https://github.com/ElectricArdvark/jumpskip/wiki/MPV-Config)

---

## Features

- **Multi Provider Integration**:
  - **TheIntroDB** TV and movies.
  - **IntroDB** TV only.
  - **SkipDB** TV and movies.
- **Intelligent Fallback & Merging**:
  - Configurable provider priority (`theintrodb,introdb,skipdb` or in any order).
  - Seamless fallback: if the primary provider has no match or encounters a network error, the script automatically queries the next provider.
  - **Segment Merging**: If the primary provider has an intro but lacks an outro or recap, the script queries subsequent providers to fill in missing segment types.
- **Colored Segments**:
  - Show skippable segments types directly in the seekbar with diffrent customizable colors `script-opts/modernz.conf`.
  - Requires modified [ModernZ](https://github.com/ElectricArdvark/jumpskip/wiki/Colored-Segments)
- **Interactive On-Screen Clickable Button**:
  - Semi-transparent vector card (ASS overlay) (`Skip Intro ▶`, `Skip Outro ▶`, etc.).
- **Keyboard Shortcut**:
  - Instant skipping via configurable keybind (default: `Tab`).
- **Configurable Auto-Skip**:
  - Option to automatically skip segments when playback enters them (enabled in jumpskip.conf).
  - Optional countdown timer before auto-skipping, with on-screen visual feedback.
- **Smart Media Identification**:
  - Title-to-ID fallback lookup via Cinemeta or optional TMDb API
  - Reads embedded file metadata tags and parses filenames and folder paths for IMDb IDs.
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

Download [jumpskip.lua](https://raw.githubusercontent.com/ElectricArdvark/jumpskip/main/jumpskip.lua) and [jumpskip.conf](https://raw.githubusercontent.com/ElectricArdvark/jumpskip/main/jumpskip.conf)

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
# Master toggle for the script (yes/no)
enabled=yes

# Auto-skip behavior:
# Set to 'yes' to automatically skip segments when entering them without clicking.
# Set to 'no' to display the on-screen button and wait for user click or keybind.
auto_skip=no

# Auto-skip countdown (in seconds):
# If auto_skip is enabled and countdown > 0, an on-screen countdown prompt will be
# displayed before skipping, allowing you to cancel by clicking or seeking away.
# If set to 0, auto-skip takes effect immediately upon entering the segment.
auto_skip_countdown=0

# Segment types to auto-skip (comma-separated):
# Accepted values: intro, outro, recap, preview (whitespace around entries is ignored).
# - When left EMPTY (default), the global 'auto_skip' option above governs ALL
#   segment types.
# - When set (e.g. 'intro,recap'), ONLY the listed types are skipped automatically;
#   every other detected type shows the manual skip button / keybind prompt instead,
#   regardless of the 'auto_skip' setting.
# Invalid entries are ignored with a warning in the mpv log.
autoskip_types=

# Skip button timeout (in seconds):
# Automatically hides the on-screen skip button if it has not been clicked (or the
# keybind pressed) within this many seconds after it appears.
# The keybind remains active for the rest of the segment even after the button hides.
# 0 = button stays visible for the entire segment (default).
skip_button_timeout=3

# Segment types to detect and allow skipping:
skip_intro=yes
skip_recap=yes
skip_outro=yes
skip_preview=yes

# Per-provider, per-segment-type toggles:
# Set an entry to 'no' to ignore that segment type from that specific provider,
# while the same type from other providers (and other types from the same
# provider) continue to work normally.
# Example: skipdb_intro_segment=no drops intro segments sourced from SkipDB only.
# Note: these act as an additional filter on top of the global skip_<type>
# options above; a type disabled globally stays disabled for every provider.

theintrodb_intro_segment=yes
theintrodb_recap_segment=yes
theintrodb_outro_segment=yes
theintrodb_preview_segment=yes
introdb_intro_segment=yes
introdb_recap_segment=yes
introdb_outro_segment=yes
introdb_preview_segment=yes
skipdb_intro_segment=yes
skipdb_recap_segment=yes
skipdb_outro_segment=yes
skipdb_preview_segment=no

# Timing offsets (in seconds):
# Adjust segment start and end times to match your media cut.
# - start_offset: negative value (e.g. -0.5) triggers the prompt/button slightly earlier;
#   positive value triggers it later.
# - end_offset: seconds added or subtracted to the jump target timestamp.
start_offset=0.0
end_offset=0.0

# Provider priority order (comma-separated):
# Supported providers: 'theintrodb', 'introdb', 'skipdb'
# e.g., 'theintrodb,introdb,skipdb' queries TheIntroDB first, then IntroDB, then SkipDB.
# Omit any provider to exclude it entirely.
provider_priority=introdb,theintrodb,skipdb

# Merge providers (yes/no):
# When enabled, if the primary provider only has an intro but no outro/recap,
# the script queries the secondary provider to retrieve the missing segment types.
merge_providers=yes

# Optional API Keys:
# TheIntroDB API key (Authorization: Bearer <key>)
# Increases daily rate/usage limits and weights your submissions higher.
theintrodb_api_key=

# IntroDB API key (X-API-Key: idb_...)
# Optional for reading segments.
introdb_api_key=

# SkipDB API key (Authorization: Bearer skdb_... or X-API-Key: skdb_...)
# Reading is open (120 req/min); a key is only needed for submitting segments.
skipdb_api_key=

# Optional TMDb API key:
# Used to resolve media titles to TMDb IDs if the media file lacks an IMDb/TMDb ID.
# If left blank, Cinemeta's free public catalog lookup is used automatically.
tmdb_api_key=

# HTTP network request timeout (in seconds) for curl subprocess:
request_timeout=8

# Keybinding to trigger skip when within an active segment:
# e.g. 'Tab', 'Return', 'ctrl+s', 's'
keybind=Tab

# Minimum segment duration (in seconds) to consider valid:
min_segment_duration=3.0

# On-Screen Display (OSD) Button Position:
# Options: 'bottom-right', 'bottom-left', 'top-right', 'top-left'
button_position=bottom-right

# Button Margins (scaled to 1080p base):
button_margin_x=60
button_margin_y=120

# Button Dimensions & Font:
button_width=220
button_height=56
button_font_size=24
button_font=mpv-osd

# Button Visual Colors (Hex BGR format for ASS styling):
# Default accent: vibrant purple/indigo (#6C5CE7 -> ASS BGR 'E75C6C')
accent_color=5ba3f0
bg_color=0A0A0A
text_color=FFFFFF
hint_color=AAAAAA

# Show brief OSD message upon skipping (yes/no):
show_osd_message=yes
osd_message_duration=2.0

# show_colored_segments: master toggle for coloured seekbar segment markers (yes/no).
# When 'no', no segments are published to the OSC and nothing is drawn on the
# seekbar. Auto-skip, the manual skip button, and chapter markers are NOT affected.
# Change colours using jumpskip_intro_color / jumpskip_outro_color in modernz.conf.
show_colored_segments=yes

# Per-type marker toggles (only consulted while show_colored_segments=yes):
show_colored_intro_segments=yes
show_colored_recap_segments=yes
show_colored_outro_segments=yes
show_colored_preview_segments=yes

# mark_chapters additionally inserts '<type>' chapter
# entries at segment boundaries. Note: chapter navigation
# (PgUp/PgDn) will also stop at these boundaries.
mark_chapters=yes

# Enable debug logging in mpv terminal (yes/no):
debug_mode=no
```
---

## TO-DO
- [ ] Add Colored segments support to other osc.
- [ ] Add AniSkip.
- [ ] Add Per-provider, media type toggles.

## Contributing

Suggestions and contributions are welcome. Feel free to open an [issue](https://github.com/ElectricArdvark/jumpskip/issues) or submit a [pull request](https://github.com/ElectricArdvark/jumpskip/pulls).
