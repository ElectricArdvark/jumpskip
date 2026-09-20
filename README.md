# JumpSkip

A powerful, lightweight Lua script for **MPV** that detects and skips media segments (intros, recaps, outros/credits, and previews) using crowdsourced timestamp data from **TheIntroDB**, **IntroDB**, and **SkipDB**.

OSC by [ModernZ](https://github.com/Samillion/ModernZ).

<img width="1920" height="1080" alt="Screenshot (123)" src="https://github.com/user-attachments/assets/56985e56-e17a-4786-a118-e9de9c653bee" />
<img width="1920" height="1080" alt="Screenshot (127)" src="https://github.com/user-attachments/assets/409d74c4-fcfe-4b03-8c02-0f42351268c1" />

> [!IMPORTANT]
> **Colored Segments work only using a modified ModernZ or uosc** [Guide](https://github.com/ElectricArdvark/jumpskip/wiki/Colored-Segments).
 
<img width="24" height="24" alt="output-onlinepngtools" src="https://github.com/user-attachments/assets/7455cd12-811c-4446-b1d9-640f4ef13a61" /> Intro

<img width="24" height="24" alt="output-onlinepngtools (1)" src="https://github.com/user-attachments/assets/3b07a45b-72b1-488e-8510-b062d23b442b" /> Recap

<img width="24" height="24" alt="output-onlinepngtools (2)" src="https://github.com/user-attachments/assets/423b4958-3686-4795-b721-a6bcc3c322b9" /> Outro/Credits

<img width="24" height="24" alt="output-onlinepngtools (3)" src="https://github.com/user-attachments/assets/8e9ba2fd-bceb-4426-a26c-b0c3bbe367bc" /> Preview/Post-Credits


All colors changeable in **modernz.conf** or **uosc.conf**

---
> [!NOTE]
> ### You can check quarried segments in **Console**.

### My [MPV Config](https://github.com/ElectricArdvark/jumpskip/wiki/MPV-Config)

---

## Features

- **Multi Provider Integration**:
  - **TheIntroDB** TV and movies.
  - **IntroDB** TV and movies.
  - **SkipDB** TV and movies.
- **Intelligent Fallback & Merging**:
  - Configurable provider priority (`theintrodb,introdb,skipdb` or in any order).
  - Seamless fallback: if the primary provider has no match or encounters a network error, the script automatically queries the next provider.
  - **Segment Merging**: If the primary provider has an intro but lacks an outro or recap, the script queries subsequent providers to fill in missing segment types.
- **Colored Segments**:
  - Show skippable segments types directly in the seekbar with diffrent customizable colors `script-opts/modernz.conf` or `script-opts/uosc.conf`.
  - Requires modified [ModernZ](https://github.com/ElectricArdvark/jumpskip/wiki/Colored-Segments) or [uosc](https://github.com/ElectricArdvark/jumpskip/wiki/Colored-Segments)
- **Interactive On-Screen Clickable Button**:
  - Semi-transparent vector card (ASS overlay) (`Skip Intro ▶`, `Skip Outro ▶`, etc.).
- **Chapter-based skipping**:
  - Automatically skips chapters based on title (eg. "OP" or "Outro", "Recap" etc.).
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
# Master toggle for the script
enabled=yes
# Directory filter (inclusion & exclusion)
filter_directories=
# Auto-skip segments
auto_skip=no
# Countdown to auto-skip triggering
auto_skip_countdown=0
# Segment types to auto-skip(intro, outro, recap, preview, post_credits)
autoskip_types=
# Countdown to Skip button hiding
skip_button_timeout=3
# Keybinding to trigger skip:
keybind=Tab
# Minimum segment duration to consider valid:
min_segment_duration=3.0

# Segment types to detect and allow skipping:
skip_intro=yes
skip_recap=yes
skip_outro=yes
skip_preview=yes
skip_post_credits=yes

# Provider options:
# Per-media-type provider priority
provider_priority_tvshow=introdb,theintrodb,skipdb
provider_priority_movie=introdb,theintrodb,skipdb
# Per-provider, per-segment-type toggles
#TheIntroDB
theintrodb_intro_segment=yes
theintrodb_recap_segment=yes
theintrodb_outro_segment=yes
theintrodb_preview_segment=yes
#IntroDB
introdb_intro_segment=yes
introdb_recap_segment=yes
introdb_outro_segment=yes
introdb_preview_segment=yes
introdb_post_credits_segment=yes
#SkipDB
skipdb_intro_segment=yes
skipdb_recap_segment=yes
skipdb_outro_segment=yes
skipdb_preview_segment=yes

# Timing offsets (in seconds):
start_offset=0.0
end_offset=0.0
# Merge providers:
merge_providers=yes

# Optional API Keys:
# TheIntroDB API key
theintrodb_api_key=
# IntroDB API key
introdb_api_key=
# SkipDB API key 
skipdb_api_key=
# TMDb API key:
tmdb_api_key=

# OSD Button Settings:
# Button Position:
button_position=bottom-right
# Button Margins:
button_margin_x=60
button_margin_y=120
# Button Dimensions & Font:
button_width=220
button_height=56
button_font_size=24
button_font=mpv-osd
# Button Visual Colors:
accent_color=5ba3f0
bg_color=0A0A0A
text_color=FFFFFF
hint_color=AAAAAA

# OSD message upon skipping:
show_osd_message=yes
osd_message_duration=2.0

# Colored segments:
# Master toggle for coloured seekbar segment markers
show_colored_segments=yes
# Per-type marker toggles
show_colored_intro_segments=yes
show_colored_recap_segments=yes
show_colored_outro_segments=yes
show_colored_preview_segments=yes
show_colored_post_credits_segments=yes

# Insert segment type as a chapter:
mark_chapters=yes
# Name for chapter created:
default_chapter_title=Chapter

# Chapter-based skipping:
# Master toggle 
chapter_skip_enabled=yes
# Per-category toggles
chapter_skip_intro=yes
chapter_skip_outro=yes
chapter_skip_recap=yes
chapter_skip_preview=yes
# Keyword lists
chapter_skip_keywords_intro=intro,introduction,opening,op,theme,title sequence
chapter_skip_keywords_outro=ed,ending,outro,credits,end credits,closing
chapter_skip_keywords_recap=recap,previously
chapter_skip_keywords_preview=preview,next episode
# Sanity bounds for chapter duration
chapter_skip_min_duration=10.0
chapter_skip_max_duration=600.0
# Overlap threshold
chapter_skip_overlap_threshold=0.5

# HTTP network request timeout:
request_timeout=8
# Enable debug logging in mpv terminal:
debug_mode=no
```
---

## TO-DO
- [x] Add IntroDB movies.
- [x] Add Per-media type, provider priority.
- [x] Diifrent osc support.
  - [x] uosc
- [ ] Add AniSkip.
- [ ] Add Colored segments support to other osc.

## Changelog

Click [Here](https://github.com/ElectricArdvark/jumpskip/wiki/Changelog)

## Contributing

Suggestions and contributions are welcome. Feel free to open an [issue](https://github.com/ElectricArdvark/jumpskip/issues) or submit a [pull request](https://github.com/ElectricArdvark/jumpskip/pulls).
