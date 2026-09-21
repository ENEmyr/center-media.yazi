-- Tests for the metadata side of the bundled previewer, run outside Yazi:
--
--     lua tests/metadata.lua
--
-- with Lua 5.5, the version Yazi runs plugins with.
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
rt = { preview = { tab_size = 2, wrap = 0 } }
th = { spot = {} }
ui = {
	Wrap = { NO = 0, YES = 1 },
	Align = { CENTER = "center" },
	Style = function()
		local s = {}
		function s:fg()
			return s
		end
		function s:bold()
			return s
		end
		function s:dim()
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
		for _, span in ipairs(type(spans) == "table" and spans or { { s = spans } }) do
			t[#t + 1] = span.s
		end
		return {
			text = table.concat(t),
			width = function(self)
				return ui.width(self.text)
			end,
			align = function(self, align)
				self.alignment = align
				return self
			end,
			style = function(self)
				return self
			end,
		}
	end,
	-- Columns on screen: Thai vowel and tone marks take none, like in Yazi.
	width = function(s)
		local n = 0
		for _, c in utf8.codes(s) do
			local mark = c == 0x0E31 or (c >= 0x0E34 and c <= 0x0E3A) or (c >= 0x0E47 and c <= 0x0E4E)
			n = n + (mark and 0 or 1)
		end
		return n
	end,
	-- Wraps by columns, and drops the space a row breaks at, as Yazi's word
	-- wrapping does at a space. Returns the rows with their widths.
	lines = function(line, opt)
		local width = opt.wrap == ui.Wrap.YES and opt.width or math.huge
		local rows, used, drop = {}, 0, false
		local function row(w)
			rows[#rows + 1] = { width = function()
				return w
			end }
		end
		for _, c in utf8.codes(line) do
			local char = utf8.char(c)
			local w = ui.width(char)
			if drop and char == " " then
				drop = false
			elseif used + w > width then
				row(used)
				used, drop = w, false
			else
				used, drop = used + w, false
			end
			if used == width then
				row(used)
				used, drop = 0, true
			end
		end
		if used > 0 or #rows == 0 then
			row(used)
		end
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
	local lines, last, eof, width = utils.metadata_lines(job, output, opts.skip or 0)
	local out = {}
	for _, l in ipairs(lines) do
		out[#out + 1] = l.text
	end
	return out, last, eof, width
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
rt.preview.wrap = ui.Wrap.YES
check("narrow pane wraps long lines", #render(fixture("song.mp3"), "audio/mpeg", { w = 12 }) > #full)
rt.preview.wrap = ui.Wrap.NO

-- A line wider than the pane gets the width of the widest line that fits.
local long = "General\nFormat                                   : MPEG-4\n"
	.. "Encoding settings                        : cabac=1 / ref=1 / deblock=1:0:0 / analyse=0x3:0x113\n"
local cut = render(long, "video/mp4", { w = 40 })
check("a line wider than the pane is cut to the widest line and ends in an ellipsis",
	#cut == 3 and cut[3] == "Encoding sett…" and utf8.len(cut[3]) == utf8.len(cut[2]))
rt.preview.wrap = ui.Wrap.YES
local wrapped = render(long, "video/mp4", { w = 40 })
local joined, widest = {}, 0
for k = 3, #wrapped do
	joined[#joined + 1] = wrapped[k]
	widest = math.max(widest, utf8.len(wrapped[k]))
end
check("with wrapping on, it wraps at the widest line instead of at the pane",
	#wrapped > 3 and widest == utf8.len(wrapped[2]) and not table.concat(joined):find("…"))
check("wrapping loses no character but the spaces it breaks at",
	table.concat(joined):gsub(" ", "") == ("Encoding settings: cabac=1 / ref=1 / deblock=1:0:0 / analyse=0x3:0x113"):gsub(" ", ""))
rt.preview.wrap = ui.Wrap.NO
local narrow = render(long, "video/mp4", { w = 10 })
check("a pane too narrow for any line cuts at its edge, not at a heading's width",
	narrow[1] == "General" and narrow[2] == "Format: M…" and utf8.len(narrow[3]) == 10)
rt.preview.wrap = ui.Wrap.YES
local short = render("General\nA                                        : b\nLong                                     : "
	.. string.rep("x", 60) .. "\n", "video/mp4", { w = 40 })
check("a heading wider than every other line that fits is not wrapped", short[1] == "General" and utf8.len(short[3]) == 7)
rt.preview.wrap = ui.Wrap.NO
local _, _, _, block = render(long, "video/mp4", { w = 40 })
check("the block width counts the lines not shown", block == utf8.len("Format: MPEG-4"))
local _, _, _, lone = render("General\n", "image/svg+xml", { w = 98 })
check("metadata of a heading alone is as wide as the heading, not the pane", lone == utf8.len("General"))
local thai = render("General\nTitle                                    : สวัสดีครับ ทดสอบภาษาไทย\n", "audio/mpeg")
check("Thai vowel and tone marks do not cost the last characters", thai[2] == "Title: สวัสดีครับ ทดสอบภาษาไทย")
local exact, _, eof_exact = render(fixture("song.mp3"), "audio/mpeg", { h = #full })
check("metadata that ends exactly at the bottom of the area has reached its end", #exact == #full and eof_exact)

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
ui.Rect = function(r)
	return r
end
ui.Text = function(lines)
	local t = { lines = lines }
	function t:area(rect)
		t.rect = rect
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
-- Returns the metadata rows peek drew and the area it drew them in.
local function peek(skip, more, image, rows)
	state, drawn, emitted = { [const.STATE_KEY.units] = 5 }, nil, nil
	local area = { x = 0, y = 0, w = 80, h = rows or 10 }
	utils.peek(module, { skip = skip, mime = "audio/mpeg", args = {}, file = { url = "song.mp3" }, area = area }, image, more)
	local text = drawn and drawn[#drawn]
	return text and text.lines or {}, text and text.rect
end
local function last(lines)
	return lines[#lines] and lines[#lines].text
end
check("peek shows the metadata", peek(0)[1] and peek(0)[1].text == "General")
check("peek past the end with nothing more scrolls back", #peek(200) == 0 and emitted and emitted.args[1] == 195)
local back = peek(200, function()
	return true
end)
check("peek past the end with more to show keeps the last metadata", #back > 0 and not emitted)
local shown
ya.image_info = function(url)
	return url == "blank.png" and { w = 1, h = 1 } or nil
end
ya.image_show = function()
	shown = true
end
local lines = peek(0, nil, "blank.png")
check("peek draws no image for the blank cover, only the metadata", lines[1] and lines[1].text == "General" and not shown)
lines = peek(0)
check("metadata that does not fit ends in an ellipsis", #lines == 10 and last(lines) == "…")
check("the ellipsis is centered", lines[#lines].alignment == ui.Align.CENTER)
lines = peek(0, nil, nil, 100)
check("metadata that fits has no ellipsis", #lines > 10 and last(lines) ~= "…")
fs = { cha = function()
	return {}
end }
-- An image 3 rows tall, moved 2 rows down by the centering.
ya.image_show = function()
	return { h = 5 }, nil, 2
end
local rect
lines, rect = peek(0, nil, "cover.jpg")
check("metadata under an image leaves as much room below it as the image above", rect.h == 3 and #lines == 3 and last(lines) == "…")
local block_width = select(4, utils.metadata_lines({ mime = "audio/mpeg", area = { w = 80, h = 10 } }, fixture("song.mp3"), 0))
check("the block width goes along with the lines", block_width and drawn[#drawn].lines.width == block_width)
module.preload = function()
	return true, "Failed to start `ffmpeg`."
end
lines = peek(0)
check("an error shows first even when the metadata fills the pane", lines[1] and lines[1].text == "Failed to start `ffmpeg`.")
module.preload = function()
	return false, "Permission denied"
end
lines = peek(0)
check("a cache that cannot be written shows why", #lines == 1 and lines[1].text == "Permission denied")
os.remove(cache .. const.suffix)
os.remove(cache)

print(failed == 0 and "all passed" or (failed .. " failed"))
os.exit(failed == 0 and 0 or 1)
