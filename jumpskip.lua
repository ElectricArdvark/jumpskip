--[[
    mpv-skip-segment
    Version 1.7
    ================
    A Lua script for mpv that detects and skips segments (intros, recaps, outros/credits, previews,
    and movie end-credits/post-credits) using crowdsourced data from TheIntroDB (api.theintrodb.org),
    IntroDB (introdb.app), and SkipDB (skipdb.tv).

    Features:
    - Triple provider support: TheIntroDB (v3 OpenAPI), IntroDB (OpenAPI), and SkipDB (openAPI)
    - Movie support: IntroDB end-credits (outro) and post-credits segments (is_movie=true)
    - Automatic provider fallback and intelligent segment merging
    - Fully non-blocking asynchronous HTTP requests using curl via mp.command_native_async
    - Interactive on-screen clickable button (Netflix-style) with cursor hover feedback
    - Dynamic mouse click capture (MBTN_LEFT) only while hovering over the button
    - Keybindable action (default: Tab)
    - Automatic media identification via file metadata tags, filename regex (SxxExx, movie years, IDs),
      and fallback title lookup
    - Configurable auto-skip with optional countdown
    - Fully configurable via ~~/script-opts/jumpskip.conf

    License: MIT
--]]

local mp      = require 'mp'
local utils   = require 'mp.utils'
local assdraw = require 'mp.assdraw'
local options = require 'mp.options'

local user_opts = {
    enabled              = true,
    auto_skip            = false,
    auto_skip_countdown  = 0,
    autoskip_types       = "",
    skip_button_timeout  = 0,

    filter_directories      = "",
    show_colored_segments         = true,
    show_colored_intro_segments   = true,
    show_colored_recap_segments   = true,
    show_colored_outro_segments   = true,
    show_colored_preview_segments = true,
    show_colored_post_credits_segments = true,
    skip_intro           = true,
    skip_recap           = true,
    skip_outro           = true,
    skip_preview         = false,
    skip_post_credits    = false,

    theintrodb_intro_segment   = true,
    theintrodb_recap_segment   = true,
    theintrodb_outro_segment   = true,
    theintrodb_preview_segment = true,
    introdb_intro_segment      = true,
    introdb_recap_segment      = true,
    introdb_outro_segment      = true,
    introdb_preview_segment    = true,
    introdb_post_credits_segment = true,
    skipdb_intro_segment       = true,
    skipdb_recap_segment       = true,
    skipdb_outro_segment       = true,
    skipdb_preview_segment     = true,
    mark_chapters        = true,
    default_chapter_title = "Chapter",
    start_offset         = 0.0,
    end_offset           = 0.0,
    provider_priority_tvshow = "",
    provider_priority_movie = "",
    merge_providers      = true,
    theintrodb_api_key   = "",
    introdb_api_key      = "",
    skipdb_api_key       = "",
    tmdb_api_key         = "",
    request_timeout      = 8,
    keybind              = "Tab",
    min_segment_duration = 3.0,
    button_position      = "bottom-right",
    button_margin_x      = 60,
    button_margin_y      = 80,
    button_width         = 220,
    button_height        = 56,
    button_font_size     = 24,
    button_font          = "mpv-osd",
    accent_color         = "E75C6C",
    bg_color             = "0A0A0A",
    text_color           = "FFFFFF",
    hint_color           = "AAAAAA",
    show_osd_message     = true,
    osd_message_duration = 2.0,
    debug_mode           = false,

    -- Chapter-based skipping options
    chapter_skip_enabled        = true,
    chapter_skip_intro          = true,
    chapter_skip_outro          = true,
    chapter_skip_recap          = true,
    chapter_skip_preview        = true,
    chapter_skip_keywords_intro = "intro,introduction,opening,op,theme,title sequence",
    chapter_skip_keywords_outro = "ed,ending,outro,credits,end credits,closing",
    chapter_skip_keywords_recap = "recap,previously",
    chapter_skip_keywords_preview = "preview,next episode",
    chapter_skip_min_duration   = 10.0,
    chapter_skip_max_duration   = 300.0,
    chapter_skip_overlap_threshold = 0.5,
}

local function log_info(msg, ...)
    mp.msg.info(string.format(msg, ...))
end

local function log_warn(msg, ...)
    mp.msg.warn(string.format(msg, ...))
end

local function log_debug(msg, ...)
    if user_opts.debug_mode then
        mp.msg.info("[DEBUG] " .. string.format(msg, ...))
    end
end

local current_bound_key = nil
local perform_skip

local function update_keybind()
    if current_bound_key then
        mp.remove_key_binding("jumpskip")
    end
    if user_opts.keybind and #user_opts.keybind > 0 then
        mp.add_key_binding(user_opts.keybind, "jumpskip", function()
            if perform_skip then perform_skip() end
        end)
        current_bound_key = user_opts.keybind
    end
end

local VALID_SEGMENT_TYPES = { intro = true, recap = true, outro = true, preview = true, post_credits = true }

local autoskip_type_set     = {}
local autoskip_types_active = false

local VALID_PROVIDERS = { theintrodb = true, introdb = true, skipdb = true }

local function parse_provider_priority(priority_str)
    local providers = {}
    if not priority_str or #priority_str == 0 then
        return providers
    end
    for token in string.gmatch(priority_str, "([^,%s]+)") do
        local p = token:match("^%s*(.-)%s*$"):lower()
        if #p > 0 then
            if VALID_PROVIDERS[p] then
                table.insert(providers, p)
            else
                log_warn("Ignoring unknown provider '%s' in priority list (valid: theintrodb, introdb, skipdb)", p)
            end
        end
    end
    return providers
end

local function validate_options()
    autoskip_type_set     = {}
    autoskip_types_active = false
    for token in string.gmatch(tostring(user_opts.autoskip_types or ""), "([^,]+)") do
        local t = token:match("^%s*(.-)%s*$"):lower():gsub("%-", "_")
        if #t > 0 then
            if VALID_SEGMENT_TYPES[t] then
                autoskip_type_set[t]  = true
                autoskip_types_active = true
            else
                log_warn("Ignoring invalid autoskip_types entry '%s' (valid values: intro, recap, outro, preview, post_credits)", t)
            end
        end
    end

    local timeout = tonumber(user_opts.skip_button_timeout)
    if timeout == nil then
        log_warn("Invalid skip_button_timeout value '%s'; using 0 (button stays visible for entire segment)",
            tostring(user_opts.skip_button_timeout))
        timeout = 0
    end
    if timeout < 0 then timeout = 0 end
    user_opts.skip_button_timeout = timeout
end

local function load_configuration()
    options.read_options(user_opts, "jumpskip")

    local script_dir = debug.getinfo(1, 'S').source:match("@?(.*[/\\])")
    local candidates = {
        script_dir and (script_dir .. "jumpskip.conf") or nil,
        script_dir and (script_dir .. "../jumpskip.conf") or nil,
        script_dir and (script_dir .. "../script-opts/jumpskip.conf") or nil,
        script_dir and (script_dir .. "../scripts-opts/jumpskip.conf") or nil,
        "./jumpskip.conf",
        "./script-opts/jumpskip.conf",
    }

    local loaded_from = nil
    for _, path in ipairs(candidates) do
        if path then
            local f = io.open(path, "r")
            if f then
                for line in f:lines() do
                    line = line:match("^%s*(.-)%s*$")
                    if line ~= "" and not line:match("^[#;]") then
                        local k, v = line:match("^([%w_%-]+)%s*=%s*(.*)$")
                        if k and v then
                            k = k:gsub("%-", "_")
                            if user_opts[k] ~= nil then
                                if type(user_opts[k]) == "boolean" then
                                    local low = v:lower()
                                    user_opts[k] = (low == "yes" or low == "true" or low == "1" or low == "on")
                                elseif type(user_opts[k]) == "number" then
                                    local num = tonumber(v)
                                    if num then user_opts[k] = num end
                                else
                                    user_opts[k] = v
                                end
                            end
                        end
                    end
                end
                f:close()
                loaded_from = path
                break
            end
        end
    end

    validate_options()
    update_keybind()
    log_info("Configuration active (keybind: %s, auto_skip: %s, tv_priority: %s, movie_priority: %s)%s",
        tostring(user_opts.keybind), tostring(user_opts.auto_skip),
        tostring(user_opts.provider_priority_tvshow), tostring(user_opts.provider_priority_movie),
        loaded_from and (" [source: " .. loaded_from .. "]") or "")
end

local function round(v)
    return math.floor(v + 0.5)
end

local function clamp(val, min, max)
    if val < min then return min end
    if val > max then return max end
    return val
end

local function opacity_to_alpha(opacity)
    local clamped = clamp(opacity, 0.0, 1.0)
    return 255 - round(255 * clamped)
end

local function url_encode(str)
    if not str then return "" end
    return string.gsub(str, "([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function clean_title(raw)
    if not raw then return "" end
    local s = raw
    s = s:gsub("[%._%-]", " ")
    s = s:gsub("%b[]", " ")
    s = s:gsub("%b()", " ")
    s = s:gsub("[12]%d%d%dp", " ")
    s = s:gsub("[48][kK]", " ")
    s = s:gsub("[xX]26[45]", " ")
    s = s:gsub("[hH][eE][vV][cC]", " ")
    s = s:gsub("[aA][vV][cC]", " ")
    s = s:gsub("[bB][lL][uU][rR][aA][yY]", " ")
    s = s:gsub("[wW][eE][bB]%-[dD][lL]", " ")
    s = s:gsub("[wW][eE][bB][rR][iI][pP]", " ")
    s = s:gsub("[hH][dD][tT][vV]", " ")
    s = s:gsub("%d+%s*[mM][bB]", " ")
    s = s:gsub("%d+%s*[gG][bB]", " ")
    s = s:gsub("[dD][dD]%+?%s*5%s*1", " ")
    s = s:gsub("[dD][dD]%+?%s*7%s*1", " ")
    s = s:gsub("[dD][dD]%+?%s*2%s*0", " ")
    s = s:gsub("%s+", " ")
    return s:match("^%s*(.-)%s*$")
end

local function format_hms(sec)
    if type(sec) ~= "number" or sec ~= sec or sec == math.huge or sec < 0 then
        sec = 0
    end
    local total   = math.floor(sec)
    local hours   = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local seconds = total % 60
    return string.format("%d:%02d:%02d", hours, minutes, seconds)
end

local function make_segment(seg_type, label, start_sec, end_sec, provider)
    return {
        type      = seg_type,
        label     = label,
        start_sec = math.max(0, start_sec + user_opts.start_offset),
        end_sec   = end_sec + user_opts.end_offset,
        provider  = provider,
        skipped   = false,
    }
end

-- Chapter-based skipping: keyword matching utilities
local function parse_keywords(keyword_str)
    local keywords = {}
    if not keyword_str or #keyword_str == 0 then return keywords end
    for kw in string.gmatch(keyword_str, "([^,]+)") do
        local trimmed = kw:match("^%s*(.-)%s*$")
        if trimmed and #trimmed > 0 then
            table.insert(keywords, trimmed:lower())
        end
    end
    return keywords
end

local function is_whole_word_match(text, keyword)
    -- For short keywords (<= 3 chars), require whole word match
    if #keyword <= 3 then
        -- Use word boundary pattern: %f[%w]keyword%f[%W] or start/end of string
        local pattern = "%f[%w]" .. keyword:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "%f[%W]"
        return text:lower():match(pattern) ~= nil
    else
        -- For longer keywords, simple substring match is fine
        return text:lower():find(keyword:lower(), 1, true) ~= nil
    end
end

local function chapter_matches_keywords(chapter_title, keywords)
    if not chapter_title or #chapter_title == 0 then return false end
    local normalized = chapter_title:lower()
    -- Normalize punctuation and whitespace
    normalized = normalized:gsub("[%p]", " ")
    normalized = normalized:gsub("%s+", " ")
    normalized = normalized:match("^%s*(.-)%s*$") or ""
    for _, kw in ipairs(keywords) do
        if is_whole_word_match(normalized, kw) then
            return true
        end
    end
    return false
end

-- Check if a chapter-derived segment overlaps with existing provider segments
local function check_overlap(chapter_start, chapter_end, existing_segments, threshold)
    threshold = threshold or user_opts.chapter_skip_overlap_threshold
    local chapter_duration = chapter_end - chapter_start
    if chapter_duration <= 0 then return true end
    
    for _, seg in ipairs(existing_segments) do
        local overlap_start = math.max(chapter_start, seg.start_sec)
        local overlap_end = math.min(chapter_end, seg.end_sec)
        local overlap_duration = math.max(0, overlap_end - overlap_start)
        local overlap_ratio = overlap_duration / chapter_duration
        if overlap_ratio >= threshold then
            return true, overlap_ratio
        end
    end
    return false, 0
end

-- Detect skippable segments from embedded chapters
local function detect_chapter_segments(chapters, duration, existing_segments, media_info)
    local detected = {}
    if not chapters or type(chapters) ~= "table" or #chapters == 0 then
        log_debug("chapter-skip: no chapters")
        return detected
    end
    if not duration or duration <= 0 then
        log_debug("chapter-skip: invalid duration")
        return detected
    end

    -- Parse keyword lists per category
    local keyword_lists = {
        intro    = parse_keywords(user_opts.chapter_skip_keywords_intro),
        outro    = parse_keywords(user_opts.chapter_skip_keywords_outro),
        recap    = parse_keywords(user_opts.chapter_skip_keywords_recap),
        preview  = parse_keywords(user_opts.chapter_skip_keywords_preview),
    }

    -- Per-category enable toggles
    local category_enabled = {
        intro   = user_opts.chapter_skip_intro,
        outro   = user_opts.chapter_skip_outro,
        recap   = user_opts.chapter_skip_recap,
        preview = user_opts.chapter_skip_preview,
    }

    -- Sort chapters by time
    local sorted_chapters = {}
    for _, ch in ipairs(chapters) do
        if ch and ch.time then
            table.insert(sorted_chapters, {
                time  = tonumber(ch.time) or 0,
                title = ch.title or "",
            })
        end
    end
    table.sort(sorted_chapters, function(a, b) return a.time < b.time end)

    if #sorted_chapters == 0 then return detected end

    local min_dur = user_opts.chapter_skip_min_duration
    local max_dur = user_opts.chapter_skip_max_duration

    for i, ch in ipairs(sorted_chapters) do
        local start_time = ch.time
        local end_time = (i < #sorted_chapters) and sorted_chapters[i + 1].time or duration
        local chapter_duration = end_time - start_time

        -- Sanity bounds check
        if chapter_duration < min_dur or chapter_duration > max_dur then
            log_debug("chapter-skip: '%s' @%.2fs skipped (dur %.1fs out of bounds)", ch.title, start_time, chapter_duration)
            goto continue
        end

        -- Check each category
        local matched = false
        for cat, keywords in pairs(keyword_lists) do
            if category_enabled[cat] and #keywords > 0 then
                local normalized = ch.title:lower()
                normalized = normalized:gsub("[%p]", " ")
                normalized = normalized:gsub("%s+", " ")
                normalized = normalized:match("^%s*(.-)%s*$") or ""
                for _, kw in ipairs(keywords) do
                    if is_whole_word_match(normalized, kw) then
                        -- Check overlap with existing provider segments
                        local overlaps, ratio = check_overlap(start_time, end_time, existing_segments)
                        if overlaps then
                            log_debug("chapter-skip: '%s' matches %s but overlaps provider (%.0f%%)", ch.title, cat, ratio * 100)
                        else
                            local label = cat:gsub("^%l", string.upper)
                            if cat == "outro" and media_info and not media_info.is_tv then
                                label = "Credits"
                            end
                            table.insert(detected, make_segment(cat, label, start_time, end_time, "Chapters"))
                            log_info("Detected %s segment from chapter: '%s' at %.2fs-%.2fs",
                                cat, ch.title, start_time, end_time)
                        end
                        matched = true
                        break
                    end
                end
                if matched then break end
            end
        end
        if not matched then
            log_debug("chapter-skip: no match for '%s'", ch.title)
        end

        ::continue::
    end

    return detected
end

local function build_auth_header(key, header_prefix)
    if key and #key > 0 then
        return { header_prefix .. key }
    end
    return {}
end

local state = {
    file_id              = 0,
    path                 = nil,
    filename             = nil,
    duration             = 0,
    media_info           = nil,
    segments             = {},
    segments_loaded      = false,
    query_in_progress    = false,
    active_segment       = nil,
    button_visible       = false,
    mouse_hover          = false,
    mbtn_bound           = false,
    auto_skip_timer      = nil,
    auto_skip_target_time = nil,
    button_timeout_timer = nil,
    last_time            = nil,
    display_w            = 1920,
    display_h            = 1080,
    box                  = { x1 = 0, y1 = 0, x2 = 0, y2 = 0 },
    overlay              = nil,
}

local function extract_media_metadata()
    local path     = mp.get_property("path") or ""
    local filename = mp.get_property("filename") or ""

    local info = {
        is_tv   = false,
        title   = nil,
        season  = nil,
        episode = nil,
        year    = nil,
        imdb_id = nil,
        tmdb_id = nil,
        tvdb_id = nil,
    }

    local metadata = mp.get_property_native("metadata") or {}
    for key, val in pairs(metadata) do
        local k = string.lower(tostring(key))
        local v = tostring(val)
        if k == "imdb" or k == "imdb_id" or k == "imdbid" then
            local id = v:match("tt%d%d%d%d%d%d%d%d?")
            if id then info.imdb_id = id end
        elseif k == "tmdb" or k == "tmdb_id" or k == "tmdbid" then
            local id = tonumber(v:match("%d+"))
            if id then info.tmdb_id = id end
        elseif k == "tvdb" or k == "tvdb_id" or k == "tvdbid" then
            local id = tonumber(v:match("%d+"))
            if id then info.tvdb_id = id end
        elseif k == "season_number" or k == "season" then
            info.season = tonumber(v)
        elseif k == "episode_id" or k == "episode_sort" or k == "episode_number" or k == "episode" then
            info.episode = tonumber(v)
        end
    end

    local raw_media_title = mp.get_property("media-title") or ""
    local target_text = filename .. " " .. path .. " " .. raw_media_title

    if not info.imdb_id then
        local id = target_text:match("tt%d%d%d%d%d%d%d%d?")
        if id then info.imdb_id = id end
    end
    if not info.tmdb_id then
        local id_str = target_text:match("tmdb%-(%d+)") or target_text:match("tmdbid%-(%d+)")
        if id_str then info.tmdb_id = tonumber(id_str) end
    end
    if not info.tvdb_id then
        local id_str = target_text:match("tvdb%-(%d+)") or target_text:match("tvdbid%-(%d+)")
        if id_str then info.tvdb_id = tonumber(id_str) end
    end

    local fn = filename
    if fn and #fn > 0 and not fn:match("^av://") and not fn:match("^lavfi:") then
        local fn_base  = fn:gsub("%.[a-zA-Z0-9]+$", "")
        local fn_clean = fn_base:gsub("%-[%w_]+$", "")

        local s_title, s, e = fn_clean:match("^(.-)[%._%-%s]+[sS](%d%d?)[%._%-%s]*[eE](%d%d?)")
        if not s_title then
            s_title, s, e = fn_clean:match("^(.-)[%._%-%s]+(%d%d?)[xX](%d%d+)")
        end
        if not s_title then
            s_title, s, e = fn_clean:match("^(.-)[%._%-%s]+[sS]eason[%._%-%s]*(%d%d?)[%._%-%s]*[eE]pisode[%._%-%s]*(%d%d?)")
        end
        if not s_title then
            local st, ep = fn_clean:match("^(.-)[%._%-%s]+[eE][pP][%._%-%s]*(%d%d%d?)")
            if not st then
                st, ep = fn_clean:match("^(.-)[%._%-%s]+[eE]pisode[%._%-%s]*(%d%d%d?)")
            end
            if st and ep then s_title, s, e = st, "1", ep end
        end

        if s_title and #s_title > 1 and s and e then
            info.is_tv = true
            if not info.season  then info.season  = tonumber(s) end
            if not info.episode then info.episode = tonumber(e) end
            info.title = clean_title(s_title)
        end

        if not info.title then
            local m_title, y_str = fn_clean:match("^(.-)[%._%-%s%(]+(19%d%d)[%._%-%s%)]")
            if not m_title then m_title, y_str = fn_clean:match("^(.-)[%._%-%s%(]+(20%d%d)[%._%-%s%)]") end
            if not m_title then m_title, y_str = fn_clean:match("^(.-)[%._%-%s%(]+(19%d%d)$") end
            if not m_title then m_title, y_str = fn_clean:match("^(.-)[%._%-%s%(]+(20%d%d)$") end
            if m_title and #m_title > 0 and y_str then
                info.title = clean_title(m_title)
                info.year  = tonumber(y_str)
            end
        end

        if not info.title and #fn_clean > 0 then
            local cleaned = clean_title(fn_clean)
            if cleaned and #cleaned > 0 then info.title = cleaned end
        end
    end

    if not info.title or #info.title == 0 then
        for key, val in pairs(metadata) do
            local k = string.lower(tostring(key))
            if (k == "show" or k == "series") and not info.title then
                info.title = clean_title(tostring(val))
            end
        end
        if not info.title and raw_media_title
                and not raw_media_title:match("^av://")
                and not raw_media_title:match("^lavfi:") then
            info.title = clean_title(raw_media_title)
        end
    end

    log_debug("Media parsed: title='%s', is_tv=%s, S=%s, E=%s, Year=%s, imdb=%s, tmdb=%s, tvdb=%s",
        tostring(info.title), tostring(info.is_tv), tostring(info.season), tostring(info.episode),
        tostring(info.year), tostring(info.imdb_id), tostring(info.tmdb_id), tostring(info.tvdb_id))

    return info
end

local function async_http_get(url, headers, timeout_sec, callback)
    local args = {
        "curl", "-s", "-S",
        "--max-time",        tostring(timeout_sec or user_opts.request_timeout),
        "--connect-timeout", "4",
        "-H", "User-Agent: mpv-skip-segment/1.0",
        "-H", "Accept: application/json",
    }

    if headers then
        for _, h in ipairs(headers) do
            table.insert(args, "-H")
            table.insert(args, h)
        end
    end

    table.insert(args, url)
    log_debug("HTTP GET: %s", url)

    mp.command_native_async({
        name           = "subprocess",
        args           = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only  = false,
    }, function(success, res, err)
        if not success or not res then
            log_debug("curl execution error: %s", tostring(err))
            callback(false, nil, err or "curl execution failed")
            return
        end
        if res.status ~= 0 then
            local err_msg = string.format("curl error (exit code %d): %s", res.status, res.stderr or "")
            log_debug("%s", err_msg)
            callback(false, nil, err_msg)
            return
        end
        local stdout = res.stdout or ""
        local parsed, parse_err = utils.parse_json(stdout)
        if parse_err or not parsed then
            log_debug("JSON parse error from %s: %s", url, tostring(parse_err))
            callback(false, stdout, "invalid JSON: " .. tostring(parse_err))
            return
        end
        callback(true, parsed, nil)
    end)
end

local function resolve_title_to_imdb(media_info, current_file_id, callback)
    if media_info.imdb_id then
        callback(true)
        return
    end

    if not media_info.title or #media_info.title == 0 then
        callback(media_info.tmdb_id ~= nil or media_info.tvdb_id ~= nil)
        return
    end

    if user_opts.tmdb_api_key and #user_opts.tmdb_api_key > 0 then
        local endpoint = media_info.is_tv and "search/tv" or "search/movie"
        local url = string.format("https://api.themoviedb.org/3/%s?api_key=%s&query=%s",
            endpoint, user_opts.tmdb_api_key, url_encode(media_info.title))
        if media_info.year and not media_info.is_tv then
            url = url .. "&year=" .. tostring(media_info.year)
        end

        async_http_get(url, nil, 6, function(success, data, err)
            if state.file_id ~= current_file_id then return end
            if success and data and data.results and #data.results > 0 then
                media_info.tmdb_id = data.results[1].id
                log_info("Resolved title '%s' to TMDb ID %d via TMDb API", media_info.title, media_info.tmdb_id)

                local ext_type = media_info.is_tv and "tv" or "movie"
                local ext_url = string.format("https://api.themoviedb.org/3/%s/%d/external_ids?api_key=%s",
                    ext_type, media_info.tmdb_id, user_opts.tmdb_api_key)
                async_http_get(ext_url, nil, 4, function(ext_ok, ext_data, ext_err)
                    if state.file_id ~= current_file_id then return end
                    if ext_ok and ext_data and ext_data.imdb_id then
                        media_info.imdb_id = ext_data.imdb_id
                        log_info("Resolved TMDb ID %d to IMDb ID %s", media_info.tmdb_id, media_info.imdb_id)
                    end
                    callback(true)
                end)
            else
                callback(media_info.tmdb_id ~= nil or media_info.tvdb_id ~= nil)
            end
        end)
        return
    end

    local catalog_type = media_info.is_tv and "series" or "movie"
    local url = string.format("https://v3-cinemeta.strem.io/catalog/%s/top/search=%s.json",
        catalog_type, url_encode(media_info.title))

    async_http_get(url, nil, 6, function(success, data, err)
        if state.file_id ~= current_file_id then return end
        if success and data and data.metas and #data.metas > 0 then
            local function normalize(s)
                return (s or ""):lower():gsub("[^%a%d]", "")
            end
            local query_norm = normalize(media_info.title)
            local best_meta, best_score = nil, -1
            for rank, m in ipairs(data.metas) do
                local name_norm = normalize(m.name)
                local score = 0
                if name_norm == query_norm then
                    score = 1000
                elseif name_norm:sub(1, #query_norm) == query_norm then
                    score = 500
                elseif query_norm:find(name_norm, 1, true) or name_norm:find(query_norm, 1, true) then
                    score = 300
                else
                    local common, qlen, nlen = 0, #query_norm, #name_norm
                    for ci = 1, math.min(qlen, nlen) do
                        if query_norm:sub(ci, ci) == name_norm:sub(ci, ci) then
                            common = common + 1
                        else break end
                    end
                    score = math.floor(common / math.max(qlen, nlen, 1) * 200)
                end

                local cand_year = tonumber(m.year or m.releaseInfo)
                if media_info.year and cand_year then
                    if cand_year == media_info.year then
                        score = score + 200
                    elseif math.abs(cand_year - media_info.year) == 1 then
                        score = score + 100
                    else
                        score = score - 150
                    end
                end

                local lname = (m.name or ""):lower()
                if lname:find("reaction") or lname:find("re%-edit") or lname:find("re edit") or lname:find("commentary") then
                    score = score - 400
                end
                score = score - (rank - 1) * 0.5
                log_debug("Cinemeta candidate #%d '%s' (year=%s) norm='%s' score=%.1f",
                    rank, m.name or "", tostring(cand_year), name_norm, score)
                if score > best_score then
                    best_score = score
                    best_meta  = m
                end
            end
            local id = best_meta and (best_meta.imdb_id or best_meta.id)
            if id and id:match("^tt%d+") and best_score > 0 then
                media_info.imdb_id = id
                log_info("Resolved title '%s'%s to IMDb ID %s via Cinemeta (score=%.1f, name='%s')",
                    media_info.title,
                    media_info.year and (" (" .. tostring(media_info.year) .. ")") or "",
                    id, best_score, best_meta.name or "?")
                callback(true)
                return
            end
        end
        log_debug("Could not resolve title '%s' to an IMDb ID via Cinemeta", media_info.title)
        callback(media_info.tmdb_id ~= nil or media_info.tvdb_id ~= nil)
    end)
end

local function query_theintrodb(media_info, current_file_id, callback)
    if not media_info.tmdb_id and not media_info.imdb_id and not media_info.tvdb_id then
        callback(false, nil, "Missing ID (tmdb_id, imdb_id, or tvdb_id)")
        return
    end

    local params = {}
    if media_info.tmdb_id then
        table.insert(params, "tmdb_id=" .. tostring(media_info.tmdb_id))
    elseif media_info.tvdb_id then
        table.insert(params, "tvdb_id=" .. tostring(media_info.tvdb_id))
    elseif media_info.imdb_id then
        table.insert(params, "imdb_id=" .. tostring(media_info.imdb_id))
    end
    if media_info.is_tv and media_info.season and media_info.episode then
        table.insert(params, "season="  .. tostring(media_info.season))
        table.insert(params, "episode=" .. tostring(media_info.episode))
    end
    if state.duration and state.duration > 0 then
        table.insert(params, "duration_ms=" .. tostring(round(state.duration * 1000)))
    end

    local url     = "https://api.theintrodb.org/v3/media?" .. table.concat(params, "&")
    local headers = build_auth_header(user_opts.theintrodb_api_key, "Authorization: Bearer ")

    async_http_get(url, headers, user_opts.request_timeout, function(success, data, err)
        if state.file_id ~= current_file_id then return end
        if not success or not data then
            callback(false, nil, err or "TheIntroDB request failed")
            return
        end
        if data.error then
            callback(false, nil, "TheIntroDB API error: " .. tostring(data.error))
            return
        end

        local normalized = {}

        local function add_ranges(list, seg_type, label)
            if not list or type(list) ~= "table" then return end
            for _, item in ipairs(list) do
                local s_ms    = item.start_ms
                local e_ms    = item.end_ms
                local s_sec   = s_ms and (s_ms / 1000.0) or 0.0
                local e_sec   = e_ms and (e_ms / 1000.0) or (state.duration > 0 and state.duration or nil)
                if e_ms ~= 0 and e_sec and (e_sec - s_sec) >= user_opts.min_segment_duration then
                    table.insert(normalized, make_segment(seg_type, label, s_sec, e_sec, "TheIntroDB"))
                end
            end
        end

        if user_opts.skip_intro   then add_ranges(data.intro,    "intro",   "Intro")   end
        if user_opts.skip_recap   then add_ranges(data.recap,    "recap",   "Recap")   end
        if user_opts.skip_outro   then add_ranges(data.credits,  "outro",   "Credits") end
        if user_opts.skip_preview then add_ranges(data.preview,  "preview", "Preview") end

        log_info("TheIntroDB returned %d segment(s)", #normalized)
        callback(true, normalized, nil)
    end)
end

local function query_introdb(media_info, current_file_id, callback)
    if not media_info.imdb_id then
        callback(false, nil, "IntroDB requires imdb_id")
        return
    end

    local is_movie = not media_info.is_tv
    if not is_movie and (not media_info.season or not media_info.episode) then
        callback(false, nil, "IntroDB requires season and episode for TV shows")
        return
    end

    local url
    if is_movie then
        url = string.format("https://api.introdb.app/segments?imdb_id=%s&is_movie=true",
            media_info.imdb_id)
    else
        url = string.format("https://api.introdb.app/segments?imdb_id=%s&season=%d&episode=%d",
            media_info.imdb_id, media_info.season, media_info.episode)
    end
    local headers = build_auth_header(user_opts.introdb_api_key, "X-API-Key: ")

    async_http_get(url, headers, user_opts.request_timeout, function(success, data, err)
        if state.file_id ~= current_file_id then return end
        if not success or not data then
            callback(false, nil, err or "IntroDB request failed")
            return
        end
        if data.error then
            callback(false, nil, "IntroDB API error: " .. tostring(data.error))
            return
        end

        local normalized = {}

        local function add_segment(item, seg_type, label)
            if not item or type(item) ~= "table" then return end
            local s_sec = item.start_sec or (item.start_ms and (item.start_ms / 1000.0)) or 0.0
            local e_sec = item.end_sec   or (item.end_ms   and (item.end_ms   / 1000.0)) or nil
            if e_sec and (e_sec - s_sec) >= user_opts.min_segment_duration then
                table.insert(normalized, make_segment(seg_type, label, s_sec, e_sec, "IntroDB"))
            end
        end

        if user_opts.skip_intro then add_segment(data.intro,  "intro",  "Intro")  end
        if user_opts.skip_recap then add_segment(data.recap,  "recap",  "Recap")  end
        if user_opts.skip_outro then
            add_segment(data.outro, "outro", is_movie and "Credits" or "Outro")
        end
        if user_opts.skip_post_credits then
            add_segment(data.post_credits, "post_credits", "Post-Credits")
        end

        log_info("IntroDB returned %d segment(s)", #normalized)
        callback(true, normalized, nil)
    end)
end

local function query_skipdb(media_info, current_file_id, callback)
    if not media_info.imdb_id then
        callback(false, nil, "SkipDB requires imdb_id")
        return
    end

    local url = "https://api.skipdb.tv/api/segments?imdb_id=" .. media_info.imdb_id
    if media_info.is_tv and media_info.season and media_info.episode then
        url = url .. "&season="  .. tostring(media_info.season)
                  .. "&episode=" .. tostring(media_info.episode)
    end
    if state.duration and state.duration > 0 then
        url = url .. "&duration=" .. tostring(math.floor(state.duration))
    end

    local headers = build_auth_header(user_opts.skipdb_api_key, "Authorization: Bearer ")

    async_http_get(url, headers, user_opts.request_timeout, function(success, data, err)
        if state.file_id ~= current_file_id then return end
        if not success or not data then
            callback(false, nil, err or "SkipDB request failed")
            return
        end
        if data.error then
            callback(false, nil, "SkipDB API error: " .. tostring(data.error))
            return
        end

        local segs = data.segments
        if type(segs) ~= "table" then
            callback(false, nil, "SkipDB: unexpected response format")
            return
        end

        local normalized = {}

        local function add_segment(item, seg_type, label)
            if not item or type(item) ~= "table" then return end
            if item.start_ms == 0 and item.end_ms == 0 then return end
            local s_sec = (item.start_ms or 0) / 1000.0
            local e_sec = item.end_ms and (item.end_ms / 1000.0) or nil
            if e_sec and (e_sec - s_sec) >= user_opts.min_segment_duration then
                table.insert(normalized, make_segment(seg_type, label, s_sec, e_sec, "SkipDB"))
            end
        end

        if user_opts.skip_intro   then add_segment(segs.intro,   "intro",   "Intro")   end
        if user_opts.skip_recap   then add_segment(segs.recap,   "recap",   "Recap")   end
        if user_opts.skip_outro   then add_segment(segs.outro,   "outro",   "Outro")   end
        if user_opts.skip_preview then add_segment(segs.preview, "preview", "Preview") end

        log_info("SkipDB returned %d segment(s)", #normalized)
        callback(true, normalized, nil)
    end)
end

local provider_fns = {
    theintrodb = query_theintrodb,
    introdb    = query_introdb,
    skipdb     = query_skipdb,
}

local function log_segments_summary(segments, providers_raw)
    local sep = string.rep("-", 60)
    if providers_raw and #providers_raw > 0 then
        mp.msg.info("[jumpskip] " .. sep)
        mp.msg.info("[jumpskip] SEGMENT QUERY RESULTS (per provider)")
        mp.msg.info("[jumpskip] " .. sep)
        for _, prov in ipairs(providers_raw) do
            local pname = prov.name
            local psegs = prov.segs
            if not psegs or #psegs == 0 then
                local reason = prov.err and (" (" .. prov.err .. ")") or "  (no segments)"
                mp.msg.info(string.format("[jumpskip]   %-16s%s", pname, reason))
            else
                mp.msg.info(string.format("[jumpskip]   %-16s  %d segment(s):", pname, #psegs))
                for _, s in ipairs(psegs) do
                    mp.msg.info(string.format("[jumpskip]     %-10s  %7.2fs (%s) -> %7.2fs (%s)",
                        s.label,
                        s.start_sec, format_hms(s.start_sec),
                        s.end_sec, format_hms(s.end_sec)))
                end
            end
        end
        mp.msg.info("[jumpskip] " .. sep)
    end
    if not segments or #segments == 0 then
        mp.msg.info("[jumpskip] FINAL SEGMENTS: none")
        mp.msg.info("[jumpskip] " .. sep)
        return
    end
    mp.msg.info(string.format("[jumpskip] FINAL SEGMENTS: %d total", #segments))
    mp.msg.info("[jumpskip] " .. sep)
    mp.msg.info(string.format("[jumpskip]   %-10s  %-16s  %-20s  %-20s", "Type", "Provider", "Start", "End"))
    mp.msg.info("[jumpskip] " .. string.rep("-", 74))
    for _, s in ipairs(segments) do
        mp.msg.info(string.format("[jumpskip]   %-10s  %-16s  %-20s  %-20s",
            s.label, s.provider,
            string.format("%.2fs (%s)", s.start_sec, format_hms(s.start_sec)),
            string.format("%.2fs (%s)", s.end_sec, format_hms(s.end_sec))))
    end
    mp.msg.info("[jumpskip] " .. sep)
end

local function has_segment_type(segments_list, seg_type)
    for _, seg in ipairs(segments_list) do
        if seg.type == seg_type then return true end
    end
    return false
end

local function merge_segment_lists(primary, secondary)
    local result = {}
    for _, s in ipairs(primary) do
        table.insert(result, s)
    end
    for _, s in ipairs(secondary) do
        if not has_segment_type(result, s.type) then
            table.insert(result, s)
            log_info("Merged missing '%s' segment from %s into final segments list", s.label, s.provider)
        end
    end
    table.sort(result, function(a, b) return a.start_sec < b.start_sec end)
    return result
end

local function segment_marker_enabled(seg_type)
    if not user_opts.show_colored_segments then return false end
    local per_type = user_opts["show_colored_" .. tostring(seg_type) .. "_segments"]
    if per_type == nil then return true end
    return per_type
end

local function chapter_title_for_segment(seg_type)
    local title = tostring(seg_type):gsub("_", " "):gsub("^%l", string.upper)
    if seg_type == "outro" then
        local mi = state.media_info
        if mi and not mi.is_tv then
            title = "Credits"
        end
    end
    return title
end

local function build_marked_chapters(base_chapters, segments, duration, default_title)
    local EPSILON = 0.05
    default_title = (default_title and default_title ~= "") and default_title or "Chapter"
    duration = tonumber(duration) or 0

    local original_chapters = {}
    if type(base_chapters) == "table" then
        for _, ch in ipairs(base_chapters) do
            if ch and ch.time then
                table.insert(original_chapters, {
                    time  = tonumber(ch.time) or 0,
                    title = ch.title or "",
                })
            end
        end
    end
    table.sort(original_chapters, function(a, b) return a.time < b.time end)

    local function get_original_chapter_title_at(time_pos)
        if #original_chapters == 0 then return nil end
        local matched = nil
        for _, ch in ipairs(original_chapters) do
            if ch.time <= time_pos + EPSILON then
                matched = ch.title
            else
                break
            end
        end
        return matched
    end

    local active_segs = {}
    if type(segments) == "table" then
        for _, seg in ipairs(segments) do
            if segment_marker_enabled(seg.type) then
                local s = math.max(0, tonumber(seg.start_sec) or 0)
                local e = tonumber(seg.end_sec) or 0
                if duration > 0 and e > duration then
                    e = duration
                end
                if e > s + EPSILON then
                    table.insert(active_segs, {
                        start_sec = s,
                        end_sec   = e,
                        type      = seg.type,
                        title     = chapter_title_for_segment(seg.type),
                    })
                end
            end
        end
    end
    table.sort(active_segs, function(a, b) return a.start_sec < b.start_sec end)

    if #active_segs == 0 then
        return original_chapters, 0
    end

    local function is_inside_any_segment(t)
        for _, s in ipairs(active_segs) do
            if (s.start_sec + EPSILON) <= t and t < (s.end_sec - EPSILON) then
                return true
            end
        end
        return false
    end

    local function another_seg_starts_at(t, current_seg)
        for _, s in ipairs(active_segs) do
            if s ~= current_seg and math.abs(s.start_sec - t) < EPSILON then
                return true
            end
        end
        return false
    end

    local function original_chapter_starts_at(t)
        for _, ch in ipairs(original_chapters) do
            if math.abs(ch.time - t) < EPSILON then
                return true
            end
        end
        return false
    end

    local function segment_starts_at(t)
        for _, s in ipairs(active_segs) do
            if math.abs(s.start_sec - t) < EPSILON then
                return s
            end
        end
        return nil
    end

    local candidate_chapters = {}

    for _, ch in ipairs(original_chapters) do
        local t = ch.time
        if not segment_starts_at(t) and not is_inside_any_segment(t) then
            table.insert(candidate_chapters, {
                time   = t,
                title  = ch.title,
                source = "base",
                prio   = 2,
            })
        end
    end

    for _, seg in ipairs(active_segs) do

        table.insert(candidate_chapters, {
            time   = seg.start_sec,
            title  = seg.title,
            source = "seg_start",
            prio   = 3,
        })

        local e = seg.end_sec
        local skip_closing = false
        if duration > 0 and e >= duration - EPSILON then
            skip_closing = true
        elseif is_inside_any_segment(e) then
            skip_closing = true
        elseif another_seg_starts_at(e, seg) then
            skip_closing = true
        elseif original_chapter_starts_at(e) then
            skip_closing = true
        end

        if not skip_closing then
            local orig_title = get_original_chapter_title_at(e)
            local closing_title = (orig_title and orig_title ~= "") and orig_title or default_title
            table.insert(candidate_chapters, {
                time   = e,
                title  = closing_title,
                source = "seg_end",
                prio   = 1,
            })
        end
    end

    table.sort(candidate_chapters, function(a, b)
        if math.abs(a.time - b.time) < EPSILON then
            return a.prio > b.prio
        end
        return a.time < b.time
    end)

    local deduped = {}
    for _, ch in ipairs(candidate_chapters) do
        local t = math.max(0, ch.time)
        if not (duration > 0 and t >= duration - EPSILON) then
            if #deduped == 0 then
                table.insert(deduped, { time = t, title = ch.title })
            else
                local last = deduped[#deduped]
                if math.abs(t - last.time) < EPSILON then

                else
                    table.insert(deduped, { time = t, title = ch.title })
                end
            end
        end
    end

    return deduped, #active_segs
end

local function publish_segments(segments)
    local published = {}
    for _, seg in ipairs(segments) do
        if segment_marker_enabled(seg.type) then
            table.insert(published, {
                start   = seg.start_sec,
                ["end"] = seg.end_sec,
                kind    = seg.type,
            })
        end
    end
    local ok = pcall(mp.set_property_native, "user-data/jumpskip/segments", published)
    if not ok then
        log_debug("user-data properties unavailable (mpv < 0.36); seekbar highlights disabled")
    end
    if user_opts.mark_chapters then

        if state.base_chapter_list == nil then
            state.base_chapter_list = mp.get_property_native("chapter-list") or {}
        end

        local file_dur = state.duration
        if not file_dur or file_dur <= 0 then
            file_dur = mp.get_property_number("duration") or 0
        end

        local chapters, marked_count = build_marked_chapters(
            state.base_chapter_list,
            segments,
            file_dur,
            user_opts.default_chapter_title
        )

        mp.set_property_native("chapter-list", chapters)
        log_debug("Updated chapter markers (%d segment(s) marked, %d total chapters in chapter-list)",
            marked_count, #chapters)
    end
end

local function provider_segment_allowed(provider, seg_type)
    if not provider or not seg_type then return true end
    local key = tostring(provider):lower() .. '_' .. tostring(seg_type):lower() .. '_segment'
    local enabled = user_opts[key]
    if enabled == nil then
        log_debug('No per-provider toggle %s (unknown provider or segment type); allowing segment', key)
        return true
    end
    return enabled == true
end

local function filter_provider_segments(segs)
    local filtered = {}
    for _, seg in ipairs(segs) do
        if provider_segment_allowed(seg.provider, seg.type) then
            table.insert(filtered, seg)
        else
            log_info('Dropping %s segment from %s (disabled via %s_%s_segment=no)',
                tostring(seg.type), tostring(seg.provider),
                tostring(seg.provider):lower(), tostring(seg.type):lower())
        end
    end
    return filtered
end

local function get_provider_priority(media_info)

    local priority_str
    if media_info.is_tv then
        priority_str = user_opts.provider_priority_tvshow
    else
        priority_str = user_opts.provider_priority_movie
    end

    return parse_provider_priority(priority_str)
end

local function query_segments_pipeline()
    if not user_opts.enabled then return end

    local current_file_id    = state.file_id
    state.query_in_progress  = true
    state.segments_loaded    = false
    state.segments           = {}

    local media_info = state.media_info
    if not media_info then return end

    local providers = get_provider_priority(media_info)

    if #providers == 0 then
        state.segments_loaded    = true
        state.query_in_progress  = false
        log_info("No providers configured for %s; skipping segment query.",
            media_info.is_tv and "tvshow" or "movie")
        return
    end

    local media_type = media_info.is_tv and "tvshow" or "movie"
    mp.commandv("script-message", "jumpskip-provider-order", media_type, table.concat(providers, ","))

    log_info("Querying segment timestamps from %d provider(s) [%s]: %s...", #providers, media_type, table.concat(providers, " -> "))

    resolve_title_to_imdb(media_info, current_file_id, function(id_found)
        if state.file_id ~= current_file_id then return end

        local results = {}
        local pending = #providers

        for idx, pname in ipairs(providers) do
            local query_fn = provider_fns[pname]
            if not query_fn then
                pending     = pending - 1
                results[idx] = { name = pname, ok = false, segs = {}, err = "Unknown provider: " .. pname }
            else
                query_fn(media_info, current_file_id, function(ok, segs, err)
                    if state.file_id ~= current_file_id then return end
                    results[idx] = {
                        name = pname,
                        ok   = ok,

                        segs = (ok and segs) and filter_provider_segments(segs) or {},
                        err  = err,
                    }
                    pending = pending - 1
                    if pending == 0 then
                        local providers_raw = {}
                        for i = 1, #providers do
                            table.insert(providers_raw, results[i])
                        end

                        local final_segs = {}
                        if not user_opts.merge_providers then
                            for i = 1, #providers do
                                if results[i].ok and #results[i].segs > 0 then
                                    final_segs = results[i].segs
                                    break
                                end
                            end
                        else
                            for i = 1, #providers do
                                if results[i].ok and #results[i].segs > 0 then
                                    if #final_segs == 0 then
                                        final_segs = results[i].segs
                                    else
                                        final_segs = merge_segment_lists(final_segs, results[i].segs)
                                    end
                                end
                            end
                        end

                        -- Chapter-based skipping: detect segments from embedded chapters
                        -- to fill gaps where providers returned no data for a category
                        if user_opts.chapter_skip_enabled then
                            local base_chapters = mp.get_property_native("chapter-list") or {}
                            local chapter_segs = detect_chapter_segments(base_chapters, state.duration, final_segs, state.media_info)
                            if #chapter_segs > 0 then
                                log_info("Adding %d chapter-derived segment(s) to fill provider gaps", #chapter_segs)
                                for _, seg in ipairs(chapter_segs) do
                                    table.insert(final_segs, seg)
                                end
                                table.sort(final_segs, function(a, b) return a.start_sec < b.start_sec end)
                            end
                        end

                        state.segments        = final_segs
                        state.segments_loaded = true
                        state.query_in_progress = false
                        log_segments_summary(state.segments, providers_raw)
                        publish_segments(final_segs)
                    end
                end)
            end
        end

        if pending == 0 then
            state.segments_loaded   = true
            state.query_in_progress = false
            log_segments_summary({}, {})
        end
    end)
end

local function update_button_coordinates()
    local w = state.display_w
    local h = state.display_h

    local scale   = h / 1080.0
    local btn_w   = user_opts.button_width    * scale
    local btn_h   = user_opts.button_height   * scale
    local margin_x = user_opts.button_margin_x * scale
    local margin_y = user_opts.button_margin_y * scale

    local x1, y1, x2, y2
    if user_opts.button_position == "bottom-left" then
        x1, y1 = margin_x,           h - margin_y - btn_h
        x2, y2 = margin_x + btn_w,   h - margin_y
    elseif user_opts.button_position == "top-right" then
        x1, y1 = w - margin_x - btn_w, margin_y
        x2, y2 = w - margin_x,         margin_y + btn_h
    elseif user_opts.button_position == "top-left" then
        x1, y1 = margin_x,           margin_y
        x2, y2 = margin_x + btn_w,   margin_y + btn_h
    else
        x1, y1 = w - margin_x - btn_w, h - margin_y - btn_h
        x2, y2 = w - margin_x,         h - margin_y
    end

    state.box.x1 = x1
    state.box.y1 = y1
    state.box.x2 = x2
    state.box.y2 = y2
end

local function render_skip_button()
    if not state.button_visible or not state.active_segment then
        if state.overlay then
            state.overlay.data = ""
            state.overlay:update()
        end
        return
    end

    if not state.overlay then
        state.overlay = mp.create_osd_overlay("ass-events")
    end

    update_button_coordinates()

    local seg      = state.active_segment
    local scale    = state.display_h / 1080.0
    local x1, y1, x2, y2 = state.box.x1, state.box.y1, state.box.x2, state.box.y2
    local center_x = round((x1 + x2) / 2)
    local center_y = round((y1 + y2) / 2)
    local radius   = round(12 * scale)

    local ass = assdraw.ass_new()

    local is_hover     = state.mouse_hover
    local bg_opacity   = is_hover and 0.95 or 0.85
    local border_alpha = is_hover and "00" or "40"
    local border_width = is_hover and round(2.0 * scale) or round(1.2 * scale)
    local glow_opacity = is_hover and 0.35 or 0.15

    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\rDefault\\an7\\blur%d\\bord0\\1c&H%s&\\1a&H%02X&}",
        round(8 * scale), user_opts.accent_color, opacity_to_alpha(glow_opacity)))
    ass:draw_start()
    ass:round_rect_cw(x1 - (3 * scale), y1 - (3 * scale), x2 + (3 * scale), y2 + (3 * scale), radius + (2 * scale))
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\rDefault\\an7\\blur0\\bord%d\\1c&H%s&\\1a&H%02X&\\3c&H%s&\\3a&H%s&}",
        border_width, user_opts.bg_color, opacity_to_alpha(bg_opacity), user_opts.accent_color, border_alpha))
    ass:draw_start()
    ass:round_rect_cw(x1, y1, x2, y2, radius)
    ass:draw_stop()

    local main_label = string.format("Skip %s \xe2\x96\xb6", seg.label or "Segment")
    if state.auto_skip_target_time then
        local remaining = math.max(0, math.ceil(state.auto_skip_target_time - mp.get_time()))
        main_label = string.format("Skip %s (%ds)", seg.label or "Segment", remaining)
    end

    local font_size = round(user_opts.button_font_size * scale)

    ass:new_event()
    ass:append(string.format("{\\pos(%d,%d)\\rDefault\\an5\\fn%s\\fs%d\\b1\\bord0\\shad1\\4c&H000000&\\1c&H%s&}",
        center_x, center_y, user_opts.button_font, font_size, user_opts.text_color))
    ass:append(main_label)

    state.overlay.res_x = state.display_w
    state.overlay.res_y = state.display_h
    state.overlay.data  = ass.text
    state.overlay.z     = 2000
    state.overlay:update()
end

local function show_autoskip_notification(label)
    if not state.overlay then
        state.overlay = mp.create_osd_overlay("ass-events")
    end
    local w        = state.display_w
    local h        = state.display_h
    local scale    = h / 1080.0
    local fs       = math.floor(user_opts.button_font_size * scale)
    local margin_y = math.floor(user_opts.button_margin_y * scale)
    local ay       = h - margin_y - math.floor(user_opts.button_height * scale) - math.floor(8 * scale)
    local ax       = w / 2
    local a_accent = string.format("%02X", 255 - math.floor(0.92 * 255))
    local a_bg     = string.format("%02X", 255 - math.floor(0.85 * 255))
    local ass = string.format(
        "{\\an8}{\\pos(%d,%d)}{\\bord0}{\\shad2}{\\4c&H%s&}{\\1c&H%s&}{\\alpha&H%s&}"
        .. "{\\fn%s}{\\fs%d}{\\b1}Auto-skipped: %s",
        ax, ay,
        user_opts.bg_color, user_opts.accent_color, a_accent,
        user_opts.button_font, fs, label)
    state.overlay.data = ass
    state.overlay:update()
    mp.add_timeout(user_opts.osd_message_duration, function()
        if state.overlay then
            state.overlay.data = ""
            state.overlay:update()
        end
    end)
end

perform_skip = function(is_auto)
    if not state.active_segment then
        log_debug("perform_skip called but no active segment")
        return
    end

    local seg    = state.active_segment
    local target = seg.end_sec
    if not target or target <= 0 then
        log_warn("Cannot skip: segment end time unknown")
        return
    end

    local skip_kind = is_auto and "Auto-skipping" or "Skipping"
    log_info("%s %s from %.2fs to %.2fs (provider: %s)", skip_kind, seg.label, seg.start_sec, target, seg.provider)

    seg.skipped = true
    mp.commandv("seek", target, "absolute", "exact")

    if user_opts.show_osd_message then
        if is_auto then
            show_autoskip_notification(seg.label)
        else
            mp.osd_message(string.format("Skipped %s", seg.label), user_opts.osd_message_duration)
        end
    end

    if state.auto_skip_timer then
        state.auto_skip_timer:kill()
        state.auto_skip_timer      = nil
        state.auto_skip_target_time = nil
    end
    if state.button_timeout_timer then
        state.button_timeout_timer:kill()
        state.button_timeout_timer = nil
    end

    state.button_visible = false
    state.active_segment = nil
    render_skip_button()
end

local function set_mbtn_binding(enable)
    if enable and not state.mbtn_bound then
        mp.add_forced_key_binding("MBTN_LEFT", "jumpskip_click", perform_skip)
        state.mbtn_bound = true
        log_debug("MBTN_LEFT skip binding enabled")
    elseif not enable and state.mbtn_bound then
        mp.remove_key_binding("jumpskip_click")
        state.mbtn_bound = false
        log_debug("MBTN_LEFT skip binding disabled")
    end
end

local function should_autoskip(seg_type)
    if autoskip_types_active then
        return autoskip_type_set[seg_type] == true
    end
    return user_opts.auto_skip
end

local function check_playback_position(current_time)
    if not user_opts.enabled or not current_time or not state.segments_loaded then return end

    local last = state.last_time
    if last and current_time < last - 1.0 then
        for _, seg in ipairs(state.segments) do
            if seg.skipped and current_time < seg.end_sec then
                seg.skipped = false
                log_debug("Reset skipped flag for '%s' (backward seek detected)", seg.label)
            end
        end
    end
    state.last_time = current_time

    local matched_segment = nil
    for _, seg in ipairs(state.segments) do
        if not seg.skipped and current_time >= seg.start_sec and current_time < (seg.end_sec - 0.2) then
            matched_segment = seg
            break
        end
    end

    if matched_segment then
        if state.active_segment ~= matched_segment then
            state.active_segment = matched_segment
            state.button_visible = true
            log_info("Playback entered %s segment (%.2fs (%s) - %.2fs (%s))",
                matched_segment.label,
                matched_segment.start_sec, format_hms(matched_segment.start_sec),
                matched_segment.end_sec, format_hms(matched_segment.end_sec))

            if should_autoskip(matched_segment.type) then
                if user_opts.auto_skip_countdown > 0 then
                    state.auto_skip_target_time = mp.get_time() + user_opts.auto_skip_countdown
                    if state.auto_skip_timer then state.auto_skip_timer:kill() end
                    state.auto_skip_timer = mp.add_periodic_timer(0.25, function()
                        if not state.active_segment then
                            if state.auto_skip_timer then state.auto_skip_timer:kill() end
                            return
                        end
                        if mp.get_time() >= state.auto_skip_target_time then
                            if state.auto_skip_timer then state.auto_skip_timer:kill() end
                            state.auto_skip_timer       = nil
                            state.auto_skip_target_time = nil
                            perform_skip(true)
                        else
                            render_skip_button()
                        end
                    end)
                else
                    perform_skip(true)
                    return
                end
            elseif user_opts.skip_button_timeout > 0 then
                if state.button_timeout_timer then state.button_timeout_timer:kill() end
                state.button_timeout_timer = mp.add_timeout(user_opts.skip_button_timeout, function()
                    state.button_timeout_timer = nil
                    if state.button_visible then
                        state.button_visible = false
                        state.mouse_hover    = false
                        set_mbtn_binding(false)
                        render_skip_button()
                        log_debug("Skip button hidden after %gs timeout (keybind '%s' still active)",
                            user_opts.skip_button_timeout, tostring(user_opts.keybind))
                    end
                end)
            end

            render_skip_button()
        end
    else
        if state.active_segment then
            log_debug("Playback exited %s segment", state.active_segment.label)
            state.active_segment = nil
            state.button_visible = false
            set_mbtn_binding(false)
            if state.auto_skip_timer then
                state.auto_skip_timer:kill()
                state.auto_skip_timer       = nil
                state.auto_skip_target_time = nil
            end
            if state.button_timeout_timer then
                state.button_timeout_timer:kill()
                state.button_timeout_timer = nil
            end
            render_skip_button()
        end
    end
end

local function on_mouse_pos(_, mouse)
    if not state.button_visible or not mouse then
        if state.mouse_hover then
            state.mouse_hover = false
            set_mbtn_binding(false)
            render_skip_button()
        end
        return
    end

    local x, y = mouse.x, mouse.y
    local is_inside = (x >= state.box.x1 and x <= state.box.x2 and
                       y >= state.box.y1 and y <= state.box.y2)
    if is_inside ~= state.mouse_hover then
        state.mouse_hover = is_inside
        set_mbtn_binding(is_inside)
        render_skip_button()
    end
end

local function reset_state()
    state.file_id          = state.file_id + 1
    state.active_segment   = nil
    state.button_visible   = false
    state.mouse_hover      = false
    state.segments_loaded  = false
    state.segments         = {}
    state.base_chapter_list = nil
    set_mbtn_binding(false)
    if state.auto_skip_timer then
        state.auto_skip_timer:kill()
        state.auto_skip_timer = nil
    end
    if state.button_timeout_timer then
        state.button_timeout_timer:kill()
        state.button_timeout_timer = nil
    end
    if state.overlay then
        state.overlay.data = ""
        state.overlay:update()
    end
    pcall(function() mp.del_property("user-data/jumpskip/segments") end)
end

local function url_decode(s)
    if not s then return s end
    return (s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function normalize_absolute_path(path)
    if not path or #path == 0 then
        return nil
    end

    local clean = path:gsub("^file://localhost", ""):gsub("^file://", "")
    clean = url_decode(clean)

    clean = clean:gsub("^/([a-zA-Z]:)", "%1")

    local norm = nil
    pcall(function()
        norm = mp.command_native({"normalize-path", clean})
    end)
    if not norm or #norm == 0 then
        local is_abs = clean:match("^[a-zA-Z]:") or clean:match("^[\\/]")
        if not is_abs then
            local work_dir = mp.get_property("working-directory")
            if not work_dir or #work_dir == 0 then
                pcall(function() work_dir = utils.getcwd() end)
            end
            if work_dir and #work_dir > 0 then
                clean = utils.join_path(work_dir, clean)
            end
        end
        norm = clean
    end

    norm = norm:gsub("\\", "/"):gsub("^/([a-zA-Z]:)", "%1")
    return norm:lower()
end

local function is_directory_allowed(path)
    local filter = user_opts.filter_directories or ""
    if #filter == 0 then
        return true
    end
    if not path or #path == 0 then
        return false, "empty path"
    end

    local norm = normalize_absolute_path(path)
    if not norm then
        return false, "failed to normalize path"
    end

    local dir = norm:match("^(.*)/[^/]*$")
    local folder = nil
    if dir then
        folder = dir:match("([^/]+)/?$")

        if folder and folder:match("^[a-zA-Z]:$") then
            folder = nil
        end
    end

    local wrapped_dir = nil
    if dir and #dir > 0 then
        local trimmed_dir = dir:gsub("^/+", ""):gsub("/+$", "")
        wrapped_dir = "/" .. trimmed_dir .. "/"
    end

    local exclusions = {}
    local inclusions = {}

    for entry in filter:gmatch("[^,]+") do
        local raw = entry:match("^%s*(.-)%s*$")
        if raw and #raw > 0 then
            local is_exclusion = raw:find("%*") ~= nil
            local is_fragment  = raw:find("[\\/]") ~= nil
            local clean        = raw:gsub("%*", "")

            if is_fragment then
                clean = clean:gsub("^[\\/]+", ""):gsub("\\", "/"):gsub("/+$", ""):match("^%s*(.-)%s*$"):lower()
                if #clean > 0 then
                    local rule = { mode = "fragment", pattern = clean, raw = raw }
                    if is_exclusion then
                        exclusions[#exclusions + 1] = rule
                    else
                        inclusions[#inclusions + 1] = rule
                    end
                end
            else
                clean = clean:match("^%s*(.-)%s*$"):lower()
                if #clean > 0 then
                    local rule = { mode = "parent", pattern = clean, raw = raw }
                    if is_exclusion then
                        exclusions[#exclusions + 1] = rule
                    else
                        inclusions[#inclusions + 1] = rule
                    end
                end
            end
        end
    end

    local function rule_matches(rule)
        if rule.mode == "parent" then
            return folder and (folder == rule.pattern)
        elseif rule.mode == "fragment" then
            return wrapped_dir and string.find(wrapped_dir, "/" .. rule.pattern .. "/", 1, true) ~= nil
        end
        return false
    end

    for _, rule in ipairs(exclusions) do
        if rule_matches(rule) then
            log_debug("filter_directories: file '%s' matched exclusion rule '%s' -> skipping", path, rule.raw)
            return false, "matched exclusion rule '" .. rule.raw .. "'"
        end
    end

    if #inclusions == 0 then
        return true
    end

    for _, rule in ipairs(inclusions) do
        if rule_matches(rule) then
            log_debug("filter_directories: file '%s' matched inclusion rule '%s' -> allowed", path, rule.raw)
            return true
        end
    end

    log_debug("filter_directories: file '%s' did not match any inclusion rules -> skipping", path)
    return false, "folder not in filter_directories inclusions"
end

local function on_file_loaded()
    load_configuration()
    reset_state()
    state.path     = mp.get_property("path")
    state.filename = mp.get_property("filename")

    local allowed, reason = is_directory_allowed(state.path)
    if not allowed then
        log_debug("Skipping file (%s): %s", reason or "excluded by filter_directories", state.path or "(none)")
        return
    end

    state.duration   = mp.get_property_number("duration") or 0
    state.media_info = extract_media_metadata()
    query_segments_pipeline()
end

local function on_end_file()
    reset_state()
end

local function on_osd_dimensions_change(_, dim)
    if dim and dim.w and dim.h and dim.w > 0 and dim.h > 0 then
        state.display_w = dim.w
        state.display_h = dim.h
        if state.button_visible then render_skip_button() end
    end
end

mp.register_script_message("skip-segment", perform_skip)
mp.register_script_message("reload-segments", function()
    log_info("Reloading segment timestamps...")
    query_segments_pipeline()
end)
mp.register_script_message("reload-config", function()
    load_configuration()
    if state.path then query_segments_pipeline() end
end)

mp.observe_property("time-pos",       "number", function(_, cur_time) check_playback_position(cur_time) end)
mp.observe_property("osd-dimensions", "native", on_osd_dimensions_change)
mp.observe_property("mouse-pos",      "native", on_mouse_pos)

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file",    on_end_file)

load_configuration()
