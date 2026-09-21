-- Tests for the metadata side of the bundled previewer, run outside Yazi:
--
--     lua5.4 tests/metadata.lua
--
-- Yazi's Lua API is stubbed with just enough to run the plugin's modules. The
-- fixtures are real `mediainfo` output for files with embedded cover art.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = here .. "/../"

local state = {}
ya = {
	sync = function(f)
		return function(...)
			return f(state, ...)
		end
	end,
}
rt = { preview = { tab_size = 2, wrap = "no" } }
th = { spot = {} }
ui = {
	Wrap = { YES = 1 },
	Style = function()
		local s = {}
		function s:fg()
			return s
		end
		function s:bold()
			return s
		end
		return s
	end,
	Span = function(s)
		return { s = s, style = function(self)
			return self
		end }
	end,
	Line = function(spans)
		local t = {}
		for _, span in ipairs(spans) do
			t[#t + 1] = span.s
		end
		return { text = table.concat(t) }
	end,
	-- Wraps by character count, which is what ui.lines does for ASCII text.
	lines = function(line, opt)
		local width = opt.wrap == "yes" and opt.width or math.huge
		local rows, n, i = {}, utf8.len(line), 1
		repeat
			local len = math.min(width, n - i + 1)
			rows[#rows + 1] = { width = function()
				return len
			end }
			i = i + len
		until i > n
		return rows
	end,
}

local loaded, lua_require = {}, require
require = function(name)
	if name:sub(1, 1) ~= "." then
		return lua_require(name)
	end
	local mod = name:sub(2)
	loaded[mod] = loaded[mod] or dofile(root .. mod .. ".lua")
	return loaded[mod]
end

local const = require(".const")
local utils = require(".utils")
local mediainfo = require(".mediainfo")

local function fixture(name)
	local f = assert(io.open(here .. "/fixtures/" .. name .. ".txt"))
	local s = f:read("a")
	f:close()
	return s
end

local function render(output, mime, opts)
	opts = opts or {}
	local job = { mime = mime, area = { w = opts.w or 200, h = opts.h or 200 } }
	local lines, last, eof = utils.metadata_lines(job, output, opts.skip or 0)
	local out = {}
	for _, l in ipairs(lines) do
		out[#out + 1] = l.text
	end
	return out, last, eof
end

local function setup(opts)
	state = {}
	mediainfo:setup(opts)
end

local function has(t, s)
	for _, v in ipairs(t) do
		if v == s then
			return true
		end
	end
	return false
end

local function any(t, pat)
	for _, v in ipairs(t) do
		if v:find(pat) then
			return true
		end
	end
	return false
end

local failed = 0
local function check(name, ok)
	print((ok and "ok   " or "FAIL ") .. name)
	failed = failed + (ok and 0 or 1)
end

-- Audio keeps only General and Audio, without the cover art's lines.
for _, name in ipairs({ "song.mp3", "song.flac", "song.m4a" }) do
	setup({})
	local out = render(fixture(name), "audio/x-test")
	check(name .. ": General and Audio kept", has(out, "General") and has(out, "Audio"))
	check(name .. ": Image section dropped", not has(out, "Image") and not any(out, "^Width:"))
	check(name .. ": Cover lines dropped", not any(out, "^Cover"))
	check(name .. ": default skip_labels applied", not any(out, "^Complete name:") and not any(out, "^File size:"))
	check(name .. ": no trailing blank line", out[#out] ~= "")
end

setup({ skip_labels = { "Complete name" } })
local custom = render(fixture("song.mp3"), "audio/mpeg")
check("custom skip_labels still drops the Cover lines", not any(custom, "^Cover") and any(custom, "^File size:"))

-- Other types keep every section, and their Cover lines.
setup({})
check("video keeps its sections", has(render(fixture("video.mp4"), "video/mp4"), "Video"))
check("image keeps its sections", has(render(fixture("image.png"), "image/png"), "Image"))
local as_video = render(fixture("song.mp3"), "video/x-test")
check("the filter follows the MIME type", has(as_video, "Image") and any(as_video, "^Cover: Yes"))

-- The sections option.
setup({ sections = false })
local all = render(fixture("song.mp3"), "audio/mpeg")
check("sections = false keeps everything", has(all, "Image") and any(all, "^Cover: Yes"))
setup({ sections = { audio = { "Audio" } } })
local only = render(fixture("song.mp3"), "audio/mpeg")
check("sections list keeps only those", has(only, "Audio") and not has(only, "General") and not has(only, "Image"))
setup({ skip_labels = false, sections = false })
check("skip_labels = false hides nothing", any(render(fixture("song.mp3"), "audio/mpeg"), "^Complete name:"))

local opts = { skip_labels = { "Complete name" }, sections = { audio = { "Audio" } } }
setup(opts)
check("setup leaves the caller's table alone", opts.skip_labels[1] == "Complete name" and opts.sections.audio[1] == "Audio")

-- Numbered streams match their kind, and other kinds are dropped.
setup({})
local multi = table.concat({
	"General",
	"Format                                   : Matroska",
	"",
	"Audio #1",
	"Format                                   : AAC",
	"",
	"Audio #2",
	"Format                                   : Opus",
	"",
	"Menu",
	"00:00:00.000                             : Chapter 1",
	"",
}, "\n")
local m = render(multi, "audio/x-matroska")
check("Audio #1 and Audio #2 kept", has(m, "Audio #1") and has(m, "Audio #2") and has(m, "Format: Opus"))
check("Menu dropped", not has(m, "Menu") and not any(m, "Chapter"))

-- An error written before the output stays visible.
local err = render("Error: Failed to start `mediainfo`. \n Do you have `mediainfo` installed?\n" .. fixture("song.mp3"), "audio/mpeg")
check("error line kept", err[1] == "Error: Failed to start `mediainfo`. ")

-- Scrolling and the area limit.
local full, last_full, eof_full = render(fixture("song.mp3"), "audio/mpeg")
check("whole output reaches the end", eof_full and last_full == #full)
local part, last_part, eof_part = render(fixture("song.mp3"), "audio/mpeg", { h = 5 })
check("height limits the lines", #part == 5 and last_part == 5 and not eof_part)
local skipped, last_skipped = render(fixture("song.mp3"), "audio/mpeg", { h = 5, skip = 3 })
check("skip starts further in", skipped[1] == full[4] and #skipped == 5 and last_skipped == 8)
local past, _, eof_past = render(fixture("song.mp3"), "audio/mpeg", { h = 5, skip = #full + 3 })
check("skip past the end shows nothing", #past == 0 and eof_past)
rt.preview.wrap = "yes"
check("narrow pane wraps long lines", #render(fixture("song.mp3"), "audio/mpeg", { w = 12 }) > #full)
rt.preview.wrap = "no"

-- The session caches.
state = {}
for i = 1, 25 do
	utils.set_states("ns", "key" .. i, i)
end
local kept = 0
for _ in pairs(state.ns) do
	kept = kept + 1
end
check("set_states keeps the last 10 keys", kept == 10 and state.ns.key25 == 25 and state.ns.key15 == nil)
utils.set_states("ns", "key20", "again")
check("set_states updates a key in place", state.ns.key20 == "again" and #state["ns:order"] == 10)

local tmp = os.tmpname()
local f = assert(io.open(tmp, "w"))
f:write("Error: Failed to start `mediainfo`.\n")
f:close()
state = {}
utils.read_mediainfo_cached_file(tmp)
f = assert(io.open(tmp, "w"))
f:write("General\n")
f:close()
check("an error is read again from disk", utils.read_mediainfo_cached_file(tmp) == "General\n")
os.remove(tmp)

state = {}
check("step is 0 before any seek", utils.step({ skip = 0 }) == 0)
state[const.STATE_KEY.units] = 5
check("step counts seek units", utils.step({ skip = 15 }) == 3)

-- utils.peek, for a module without an image, with the metadata cached on disk.
local cache = os.tmpname()
f = assert(io.open(cache .. const.suffix, "w"))
f:write(fixture("song.mp3"))
f:close()
local drawn, emitted
ya.file_cache = function()
	return cache
end
ya.preview_widget = function(_, widgets)
	drawn = widgets
end
ya.emit = function(cmd, args)
	emitted = { cmd = cmd, args = args }
end
ui.render = function() end
ui.Clear = function()
	return { clear = true }
end
ui.Text = function(lines)
	local t = { lines = lines }
	function t:area()
		return t
	end
	function t:wrap()
		return t
	end
	return t
end
local module = { preload = function()
	return true
end }
local function peek(skip, more)
	state, drawn, emitted = { [const.STATE_KEY.units] = 5 }, nil, nil
	utils.peek(module, { skip = skip, mime = "audio/mpeg", args = {}, file = { url = "song.mp3" }, area = { x = 0, y = 0, w = 80, h = 10 } }, nil, more)
	return drawn and drawn[2].lines or {}
end
check("peek shows the metadata", peek(0)[1] and peek(0)[1].text == "General")
check("peek past the end with nothing more scrolls back", #peek(200) == 0 and emitted and emitted.args[1] == 195)
local back = peek(200, function()
	return true
end)
check("peek past the end with more to show keeps the last metadata", #back > 0 and not emitted)
os.remove(cache .. const.suffix)
os.remove(cache)

print(failed == 0 and "all passed" or (failed .. " failed"))
os.exit(failed == 0 and 0 or 1)
