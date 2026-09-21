--- @since 26.9.1
--- center-media.yazi
---
--- Centers what a media previewer draws inside the preview pane: the image
--- horizontally, the image and its metadata as one block vertically, and the
--- metadata block horizontally.
---
--- The previewer it centers by default is bundled in mediainfo.lua and the
--- modules next to it, derived from the no longer maintained mediainfo.yazi.
--- Any other previewer can be named as the target instead.
---
--- Yazi anchors `ya.image_show()` to the top-left corner of the rect it is
--- handed and has no alignment option (sxyazi/yazi#1141), so the only way to
--- center an image is to know its rendered size in cells before drawing it.
--- This plugin predicts that size from the cached image's pixel size and a cell
--- size it learns at runtime, then compares the prediction with the rect
--- `ya.image_show()` returns and redraws once if it was off.
---
--- Three Yazi details shape the implementation:
---   * `init.lua` runs only in the sync Lua state while previewers run in the
---     async one, so the patching has to happen inside `peek`.
---   * A yield across a `pcall` boundary silently kills the task, so the call
---     into the wrapped previewer must not be wrapped in `pcall`, and the
---     patched functions only ever yield while this plugin's own peek is running.
---   * `ui.Text(lines)` consumes the Lines it is given, so their widths have to
---     be measured in the constructor, before they are destructed.

local M = {}

local mediainfo = require(".mediainfo")

-- The target name that stands for the bundled previewer rather than a plugin.
local BUNDLED = "mediainfo"

local DEFAULTS = {
	target = BUNDLED, -- previewer to wrap; a previewer argument overrides it
	horizontal = true, -- center the image left to right
	vertical = true, -- center image and metadata together, top to bottom
	text = "block", -- "block" centers the metadata block, "center" centers each line, "off" leaves it alone
}

local get_opts = ya.sync(function(state)
	local o = {}
	for k, v in pairs(DEFAULTS) do
		o[k] = v
	end
	for k, v in pairs(state.opts or {}) do
		o[k] = v
	end
	return o
end)

local set_opts = ya.sync(function(state, opts)
	state.opts = opts
end)

local get_cell = ya.sync(function(state)
	return state.cell
end)

local set_cell = ya.sync(function(state, cell)
	state.cell = cell
end)

-- Whether the mediainfo CLI can be started, or nil until a peek or preload has
-- checked, which happens once per session.
local get_found = ya.sync(function(state)
	return state.mediainfo_found
end)

local set_found = ya.sync(function(state, found)
	state.mediainfo_found = found
end)

-- `active` is true only while this plugin's peek is running, which keeps the
-- patched globals away from every other previewer. `current` additionally pins
-- metadata centering to the file being previewed. Both are overwritten by each
-- peek, so an aborted peek cannot leave stale state behind.
local active, current = false, {}
local opts, cell = nil, nil
local widths = setmetatable({}, { __mode = "k" })
local heights = setmetatable({}, { __mode = "k" })
local patched = false

local function line_width(l)
	local ok, w = pcall(function()
		return (type(l) == "string" and ui.Line(l) or l):width()
	end)
	return ok and w or nil
end

local function block_width(lines)
	if type(lines) ~= "table" then
		return line_width(lines)
	end
	local max = 0
	for _, l in ipairs(lines) do
		local w = line_width(l)
		if w and w > max then
			max = w
		end
	end
	return max > 0 and max or nil
end

--- Rows the lines take up: a string counts its line breaks, a table its Lines.
local function block_height(lines)
	if type(lines) == "string" then
		return select(2, lines:gsub("\n", "")) + 1
	end
	return type(lines) == "table" and #lines or nil
end

--- Size in cells `url` will take up once Yazi has fit it into `rect`. Mirrors
--- Yazi's own downscale: preserve the aspect ratio, fit inside, never upscale.
local function predict(url, rect)
	local ok, info = pcall(ya.image_info, url)
	info = ok and info or nil
	if not info or not info.w or info.w <= 0 or info.h <= 0 then
		return nil, nil, nil
	end
	cell = cell or get_cell()
	if not cell then
		return nil, nil, info
	end
	local scale = math.min(1, rect.w * cell.x / info.w, rect.h * cell.y / info.h)
	return math.ceil(info.w * scale / cell.x), math.ceil(info.h * scale / cell.y), info
end

--- Learn the cell size from a draw the rect did not clip: the image kept the
--- pixel size it was cached at, so pixels / cells is the size of one cell.
--- `drawn` is ceil(px / cell), so the true value lies in [px/drawn, px/(drawn-1));
--- take the middle of that interval.
local function learn(info, rect, drawn)
	if not info or drawn.w < 2 or drawn.h < 2 then
		return false
	elseif drawn.w >= rect.w or drawn.h >= rect.h then
		return false -- clipped by the rect, so the pixel size it was scaled to is unknown
	end
	cell = { x = info.w / (drawn.w - 0.5), y = info.h / (drawn.h - 0.5) }
	set_cell(cell)
	return true
end

local function patch()
	if patched then
		return
	end
	patched = true

	local show, widget, text = ya.image_show, ya.preview_widget, ui.Text

	ui.Text = function(lines)
		local w = (active and opts.text == "block") and block_width(lines) or nil
		local h = (active and opts.vertical) and block_height(lines) or nil
		local t = text(lines)
		widths[t], heights[t] = w, h
		return t
	end

	ya.image_show = function(url, rect)
		if not active then
			return show(url, rect)
		end

		local pw, ph, info = predict(url, rect)
		local dx = (opts.horizontal and pw) and math.max(0, (rect.w - pw) // 2) or 0
		local dy = (opts.vertical and ph) and math.max(0, (rect.h - ph) // 2) or 0

		local function at(x, y)
			return ui.Rect({ x = rect.x + x, y = rect.y + y, w = rect.w - x, h = rect.h - y })
		end

		local drawn, err = show(url, at(dx, dy))
		if not drawn then
			return drawn, err
		end
		local learned = learn(info, at(dx, dy), drawn)

		-- Check the prediction, and redraw once if it was off by more than a cell.
		local wx = opts.horizontal and math.max(0, (rect.w - drawn.w) // 2) or 0
		local wy = opts.vertical and math.max(0, (rect.h - drawn.h) // 2) or 0
		if math.abs(wx - dx) > 1 or math.abs(wy - dy) > 1 then
			if not learned then
				-- Missed with a cell size this draw could not correct, so it is
				-- stale (a font size change, say); drop it and learn it again.
				cell = nil
				set_cell(nil)
			end
			local again = show(url, at(wx, wy))
			if again then
				drawn, dx, dy = again, wx, wy
			end
		end
		ya.dbg(string.format(
			"center-media: rect %dx%d, predicted %sx%s, drawn %dx%d, offset %d,%d",
			rect.w, rect.h, tostring(pw), tostring(ph), drawn.w, drawn.h, dx, dy
		))

		-- Report the image as if it had started at the top of the rect, so the
		-- caller lays its metadata out directly below the shifted image. The gap
		-- that leaves at the bottom equals the gap added at the top, which is
		-- what centers the image and the metadata together.
		return ui.Rect({ x = rect.x, y = rect.y, w = rect.w, h = dy + drawn.h }), err
	end

	ya.preview_widget = function(job, widgets)
		local url = job and job.file and tostring(job.file.url)
		if active and url and url ~= current.url then
			-- Yazi aborts a peek by dropping its coroutine, which can leave
			-- `active` set. A draw for another file proves that happened.
			active = false
		end
		local mine = active and url and url == current.url
		if not mine or opts.text == "off" or type(widgets) ~= "table" then
			return widget(job, widgets)
		end
		for _, w in ipairs(widgets) do
			pcall(function()
				if opts.text == "center" then
					w:align(ui.Align.CENTER)
				end
				local area = w:area()
				local x, y, width, height = area.x, area.y, area.w, area.h
				local bw, bh = widths[w], heights[w]
				if bw and bw < width then
					x, width = x + (width - bw) // 2, bw
				end
				-- Text that starts at the top of the pane has no image above it to
				-- center it, as when the image is switched off, so it is centered
				-- top to bottom by itself.
				if bh and bh < height and y == job.area.y then
					local dy = (height - bh) // 2
					y, height = y + dy, height - dy
				end
				if x ~= area.x or y ~= area.y then
					w:area(ui.Rect({ x = x, y = y, w = width, h = height }))
				end
			end)
		end
		return widget(job, widgets)
	end
end

--- What Yazi previews these with when no target previewer is installed, taken
--- from Yazi's own previewer rules. Ordered, first match wins.
local BUILTIN = {
	{ "^image/avif", "magick" },
	{ "^image/hei", "magick" },
	{ "^image/jxl", "magick" },
	{ "^image/svg%+xml", "svg" },
	{ "^image/", "image" },
	{ "^video/", "video" },
	{ "^application/pdf", "pdf" },
}

local function builtin(job)
	local mime = job and job.mime or ""
	for _, rule in ipairs(BUILTIN) do
		if mime:find(rule[1]) then
			return rule[2]
		end
	end
end

--- Whether the mediainfo CLI is installed. Only `check` callers, which run in
--- the async context, may start it to find out; the rest take unknown as yes.
local function mediainfo_found(check)
	local found = get_found()
	if found == nil and check then
		local _, err = Command("mediainfo"):arg({ "--version" }):output()
		found = err == nil
		set_found(found)
	end
	return found ~= false
end

local missing = {}

--- The previewer to delegate to. Only peek and preload jobs carry a previewer's
--- arguments, so only they can name a target; Yazi gives seek no arguments, and
--- for a keymap's entry the first argument is the action, so `positional` is
--- false there. Both use the configured target.
local function target(job, positional, check)
	opts = opts or get_opts()
	local name = positional and job and job.args and job.args[1]
	name = type(name) == "string" and name or opts.target

	-- Without the mediainfo CLI the bundled previewer has no metadata to show,
	-- so the file goes to the previewer Yazi itself would have used, silently,
	-- as with a missing target below. Audio has none, and keeps the bundled
	-- previewer for its cover art.
	if name == BUNDLED then
		local fallback = not mediainfo_found(check) and builtin(job)
		return fallback and require(fallback) or mediainfo
	end

	if not missing[name] then
		local ok, mod = pcall(require, name)
		if ok then
			return mod
		end
		missing[name] = mod
	end

	-- The configured previewer is not installed. Use the one Yazi itself would
	-- have used, so the file is still previewed and still centered, just without
	-- whatever the missing previewer would have added to it. Silently: this is a
	-- working setup, not a fault to report on every file.
	local fallback = builtin(job)
	if fallback then
		return require(fallback)
	end
	error(missing[name])
end

--- Previewers only have to implement `peek`, so anything else may be missing.
--- `seek` runs in the sync context, where the mediainfo CLI cannot be checked.
local function call(method, job, positional)
	local t = target(job, positional, method == "preload")
	local f = t[method]
	if type(f) ~= "function" then
		return
	end
	return f(t, job) -- keep every return value: `preload` returns (done, err)
end

function M:peek(job)
	local t = target(job, true, true)
	patch()
	current.url = job and job.file and tostring(job.file.url)
	active = true
	-- No pcall around this: `peek` yields, and a yield across a pcall boundary
	-- silently kills the task.
	local ret = t:peek(job)
	active = false
	return ret
end

function M:seek(job)
	return call("seek", job, false)
end

function M:preload(job)
	return call("preload", job, true)
end

function M:entry(job)
	return call("entry", job, false)
end

function M:setup(o)
	o = type(o) == "table" and o or {}
	local own = {}
	for k in pairs(DEFAULTS) do
		own[k] = o[k]
	end
	set_opts(own)
	-- The other options (skip_labels, skip_section_labels, sections) belong to
	-- the bundled previewer.
	mediainfo:setup(o)
end

return M
