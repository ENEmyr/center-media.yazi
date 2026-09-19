--- @since 26.9.1
--- center-media.yazi
---
--- Centers what a media previewer draws inside the preview pane: the image
--- horizontally, the image and its metadata as one block vertically, and the
--- metadata block horizontally.
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

local DEFAULTS = {
	target = "mediainfo", -- previewer to wrap; a previewer argument overrides it
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

--- True the first time it is asked about a name. Preload tasks each get their
--- own Lua state, so a plain local would report a missing previewer once per
--- file in the directory.
local first_time = ya.sync(function(state, name)
	state.warned = state.warned or {}
	if state.warned[name] then
		return false
	end
	state.warned[name] = true
	return true
end)

-- `active` is true only while this plugin's peek is running, which keeps the
-- patched globals away from every other previewer. `current` additionally pins
-- metadata centering to the file being previewed. Both are overwritten by each
-- peek, so an aborted peek cannot leave stale state behind.
local active, current = false, {}
local opts, cell = nil, nil
local widths = setmetatable({}, { __mode = "k" })
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
		local t = text(lines)
		if w then
			widths[t] = w
		end
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
					return w:align(ui.Align.CENTER)
				end
				local bw, area = widths[w], w:area()
				if bw and area and bw < area.w then
					w:area(ui.Rect({ x = area.x + (area.w - bw) // 2, y = area.y, w = bw, h = area.h }))
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

local missing = {}

local function target(job)
	opts = opts or get_opts()
	local name = job and job.args and job.args[1]
	name = type(name) == "string" and name or opts.target

	if not missing[name] then
		local ok, mod = pcall(require, name)
		if ok then
			return mod
		end
		missing[name] = mod
		if first_time(name) then
			ya.dbg(string.format("center-media: `%s` is not installed, using Yazi's own previewers", name))
		end
	end

	-- The configured previewer is not installed. Fall back to the one Yazi
	-- itself would use, so the file is still previewed and still centered, just
	-- without whatever the missing previewer would have added to it.
	local mime = job and job.mime or ""
	for _, rule in ipairs(BUILTIN) do
		if mime:find(rule[1]) then
			return require(rule[2])
		end
	end
	error(missing[name])
end

--- Previewers only have to implement `peek`, so anything else may be missing.
local function call(method, job)
	local t = target(job)
	local f = t[method]
	if type(f) ~= "function" then
		return
	end
	return f(t, job) -- keep every return value: `preload` returns (done, err)
end

function M:peek(job)
	local t = target(job)
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
	return call("seek", job)
end

function M:preload(job)
	return call("preload", job)
end

function M:entry(job)
	return call("entry", job)
end

function M:setup(o)
	local merged = {}
	for k, v in pairs(DEFAULTS) do
		merged[k] = v
	end
	for k, v in pairs(type(o) == "table" and o or {}) do
		merged[k] = v
	end
	set_opts(merged)
end

return M
