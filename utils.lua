local const = require(".const")

local M = {}
local MAX_ITEMS_IN_CACHE = 10

function M.is_valid_utf8(str)
	return utf8.len(str) ~= nil
end

function M.utf8_sub(str, start_char, end_char)
	local start_byte = utf8.offset(str, start_char) -- Expects start_char to be a character index
	local end_byte = end_char and (utf8.offset(str, end_char + 1) or (#str + 1)) - 1 -- Expects end_char
	if not start_byte then
		return ""
	end
	return str:sub(start_byte, end_byte)
end
--- The file on disk, for the tools that are run on it.
function M.path(job)
	return job.file.path or job.file.cache or job.file.url.path or job.file.url
end

function M.is_literal_string(str)
	return str and str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end
function M.path_quote(path)
	if not path or tostring(path) == "" then
		return path
	end
	local result = "'" .. string.gsub(tostring(path), "'", "'\\''") .. "'"
	return result
end

M.force_render = ya.sync(function(_, _)
	(ui.render or ya.render)()
end)

M.set_state = ya.sync(function(state, key, value)
	state[key] = value
end)

M.get_state = ya.sync(function(state, key)
	return state[key]
end)

--- Keeps the last `limit_cached_items` keys of a namespace. The keys are strings,
--- so the order they were added in is tracked in a list next to the namespace.
M.set_states = ya.sync(function(state, namespace, key, value, limit_cached_items)
	if not limit_cached_items then
		limit_cached_items = MAX_ITEMS_IN_CACHE
	end
	local order_key = namespace .. ":order"
	state[namespace] = state[namespace] or {}
	state[order_key] = state[order_key] or {}
	local storage, order = state[namespace], state[order_key]
	if storage[key] == nil then
		order[#order + 1] = key
		while #order > limit_cached_items do
			storage[table.remove(order, 1)] = nil
		end
	end
	storage[key] = value
end)

M.get_states = ya.sync(function(state, namespace, key)
	local storage = state[namespace]
	return storage and storage[key]
end)
function M.read_mediainfo_cached_file(file_path)
	local cached = M.get_states(const.STATE_KEY.cached_mediainfo, file_path)
	if cached then
		return cached
	end
	-- Open the file in read mode
	local file = io.open(file_path, "r")

	if file then
		-- Read the entire file content
		local content = file:read("*all")
		file:close()
		-- An error is not kept, so the reload peek asks for after one reads
		-- what that reload wrote rather than the error again.
		if not content:match("^Error:") then
			M.set_states(const.STATE_KEY.cached_mediainfo, file_path, content)
		end
		return content
	end
end

--- Run mediainfo on the file and write its output to the metadata cache file,
--- after `err_msg`, the errors from making the preview image, if there were any.
--- An existing cache file is kept unless peek asked for a reload.
function M.cache_mediainfo(job, err_msg)
	local cache_mediainfo_url = Url(tostring(ya.file_cache({ file = job.file, skip = 0 })) .. const.suffix)
	-- Case peek function called preload to refetch mediainfo
	if fs.cha(cache_mediainfo_url) and not job.args.force_reload_mediainfo then
		return true, err_msg ~= "" and Err("Error: " .. err_msg) or nil
	end

	local path = M.path(job)
	local output, err
	if M.is_valid_utf8(tostring(path)) then
		output, err = Command("mediainfo"):arg({ tostring(path) }):output()
	else
		-- Reach a file whose path is not valid UTF-8 by name from its directory.
		-- The "./" keeps a name that starts with "-" from being read as an option.
		local script = "cd " .. M.path_quote(tostring(path.parent)) .. " && mediainfo " .. M.path_quote("./" .. tostring(path.name))
		output, err = Command("sh"):arg({ "-c", script }):output()
	end
	if err then
		ya.dbg("center-media", tostring(err))
		err_msg = err_msg .. "Failed to start `mediainfo`. \n Do you have `mediainfo` installed?\n"
	end

	return fs.write(
		cache_mediainfo_url,
		(err_msg ~= "" and ("Error: " .. err_msg) or "") .. (output and output.stdout or "")
	)
end

--- The stream a line of mediainfo output starts, if it starts one. mediainfo
--- puts each stream's kind on a line of its own ("General", "Audio",
--- "Audio #2") above that stream's "Label   : value" lines.
local function section_of(str)
	return str:match("^(%a+) #%d+$") or str:match("^%a+$")
end

--- Turn cached mediainfo output into the lines of the metadata block, starting
--- `skip` lines in and stopping once the preview area is full.
--- Returns the lines, how many lines were walked through including skipped ones
--- (at most skip + area height), and whether the output ended inside the area.
function M.metadata_lines(job, output, skip)
	local skip_labels = M.get_state(const.STATE_KEY.skip_labels) or const.skip_labels
	local skip_section_labels = M.get_state(const.STATE_KEY.skip_section_labels) or {}
	local sections = M.get_state(const.STATE_KEY.sections) or const.sections
	local kind = (job.mime or ""):match("^([^/]+)/") or ""
	local keep = sections[kind]
	-- Trimmed audio also loses the Cover lines under General: like the Image
	-- section, they describe the cover art the preview shows.
	local no_cover = keep and kind == "audio"

	-- Pick the lines to show first, so that dropped sections cost no height.
	local entries, current = {}, nil
	for str in output:gsub("\n+$", ""):gmatch("[^\n]*") do
		local label, value = str:match("(.*[^ ])  +: (.*)")
		current = not label and section_of(str) or current
		if not (keep and current and not keep[current]) then
			if label then
				if not skip_labels[label] and not (no_cover and label:find("^Cover")) then
					entries[#entries + 1] = { label = label, line = label .. ": " .. value }
				end
			elseif not skip_section_labels[str] then
				entries[#entries + 1] = { line = str }
			end
		end
	end
	-- A dropped last section leaves the blank line that preceded it.
	while #entries > 0 and entries[#entries].line == "" do
		entries[#entries] = nil
	end

	local lines = {}
	local limit = job.area.h
	local last_line = 0
	local EOF_mediainfo = true
	local opt = { ansi = true, tab_size = rt.preview.tab_size, wrap = rt.preview.wrap, width = math.max(1, job.area.w) }
	for i, entry in ipairs(entries) do
		local label, line = entry.label, entry.line
		local wrapped = ui.lines(line, opt)
		local line_height = #wrapped
		local from = 1
		local to = math.min(line_height, skip + limit - last_line)

		local total_rendered_text_len = 1
		local total_label_rendered_len = 1
		local label_total_len = label and utf8.len(label .. ": ") or 0
		for j = from, to do
			local current_line_components = {}
			local wrapped_line_len = wrapped[j]:width() or 0
			local wrapped_raw = M.utf8_sub(line, total_rendered_text_len, total_rendered_text_len + wrapped_line_len)
			wrapped_line_len = utf8.len(wrapped_raw)
			total_rendered_text_len = total_rendered_text_len + wrapped_line_len

			if last_line + 1 > skip then
				local label_raw = label_total_len - total_label_rendered_len <= 0 and ""
					or M.utf8_sub(wrapped_raw, 1, label_total_len - total_label_rendered_len)
				local label_raw_len = utf8.len(label_raw)
				if label_raw_len > 0 then
					table.insert(current_line_components, ui.Span(label_raw):style(ui.Style():fg("reset"):bold()))
					total_label_rendered_len = total_label_rendered_len + label_raw_len
					wrapped_raw = wrapped_raw:gsub("^" .. M.is_literal_string(label_raw), "", 1)
				end
				if total_label_rendered_len >= label_total_len then
					local value_raw = wrapped_raw
					table.insert(
						current_line_components,
						ui.Span(value_raw or ""):style(
							label and (th.spot.tbl_col or ui.Style():fg("blue"))
								or (th.spot.title or ui.Style():fg("green"))
						)
					)
				end
				table.insert(lines, ui.Line(current_line_components))
			else
				total_label_rendered_len = total_label_rendered_len + total_rendered_text_len
			end
			last_line = last_line + 1
			if i == #entries and not wrapped[j + 1] then
				EOF_mediainfo = true
			end
			if last_line >= skip + limit then
				last_line = skip + limit
				EOF_mediainfo = false
				break
			end
		end
	end
	return lines, last_line, EOF_mediainfo
end

--- How many seek steps the preview has been scrolled by.
function M.step(job)
	local units = M.get_state(const.STATE_KEY.units)
	return units and math.floor(math.abs(job.skip / units)) or 0
end

local function text(lines, area)
	local wrap = rt.preview.wrap == "yes" or rt.preview.wrap == ui.Wrap.YES
	return ui.Text(lines):area(area):wrap(wrap and ui.Wrap.YES or ui.Wrap.NO)
end

--- Whether `image` is the blank 1x1 picture audio.lua caches in place of
--- missing cover art. It only keeps preload from looking for the cover again,
--- and drawing it would push the metadata down by the rows it takes.
local function blank(image)
	local info = ya.image_info(image)
	return info ~= nil and info.w == 1 and info.h == 1
end

--- The peek every media module shares: the preview image at the top, if the
--- module has one, and the metadata below it.
--- `image` is the cached preview image, nil for a module that only shows
--- metadata. `more(job)` tells whether scrolling past the end of the metadata
--- still has something to show, such as later video frames or further layers.
function M.peek(module, job, image, more)
	local ok, preload_err = module:preload(job)
	if not ok then
		return
	end

	local key = tostring(ya.file_cache({ file = job.file, skip = 0 }))
	local lines, height = {}, 0
	if not job.args.no_metadata then
		local output = M.read_mediainfo_cached_file(key .. const.suffix)
		if output and output:match("^Error:") then
			job.args.force_reload_mediainfo = true
			ok, preload_err = module:preload(job)
			if not ok or preload_err then
				return
			end
			output = M.read_mediainfo_cached_file(key .. const.suffix)
		end
		if output then
			local skip = job.skip
			local last_line, eof
			lines, last_line, eof = M.metadata_lines(job, output, skip)
			if eof and #lines == 0 and skip > 0 then
				local units = M.get_state(const.STATE_KEY.units) or 0
				if not (more and more(job)) then
					ya.emit("peek", { math.max(0, job.skip - units), only_if = job.file.url, upper_bound = true })
					return
				end
				-- Scrolling goes on through the frames or layers, and the metadata
				-- stays at the last position that showed any.
				local last = M.get_state(const.STATE_KEY.last_valid_mediainfo_skip)
				skip = last and last[key] or math.max(0, skip - units)
				lines, last_line = M.metadata_lines(job, output, skip)
				while #lines == 0 and skip > 0 and units > 0 do
					skip = math.max(0, skip - units)
					lines, last_line = M.metadata_lines(job, output, skip)
				end
			end
			if #lines > 0 then
				M.set_state(const.STATE_KEY.last_valid_mediainfo_skip, { [key] = skip })
			end
			height = math.min(job.area.h, last_line)
		end
	end
	if preload_err then
		table.insert(lines, ui.Line(tostring(preload_err)):style(th.spot.title or ui.Style():fg("red")))
	end

	local area = job.area
	if image and blank(image) then
		image = nil
	end
	if not image then
		M.force_render()
		ya.preview_widget(job, { ui.Clear(area), text(lines, area) })
		M.set_state(const.STATE_KEY.prev_metadata_area, {
			x = area.x, y = area.y, w = area.w, h = area.h,
			win_x = area.x, win_y = area.y, win_w = area.w, win_h = area.h,
		})
		return
	end

	-- Clear the metadata the last peek drew in this pane: the image drawn over
	-- that area would otherwise mix with it.
	local old = M.get_state(const.STATE_KEY.prev_metadata_area)
	if old and old.win_x == area.x and old.win_y == area.y and old.win_w == area.w and old.win_h == area.h then
		ya.preview_widget(job, { ui.Clear(ui.Rect({ x = old.x, y = old.y, w = old.w, h = old.h })) })
	end
	M.force_render()

	local drawn = fs.cha(image)
		and ya.image_show(image, ui.Rect({
			x = area.x,
			y = area.y,
			w = area.w,
			h = height > 0 and math.max(area.h - height, area.h / 2) or area.h,
		}))
	-- No image is made for a skip past the end of a video. Keep the room the
	-- last one took, so the metadata does not jump up.
	local heights = M.get_state(const.STATE_KEY.prev_image_height)
	local image_height = drawn and drawn.h or (heights and heights[key]) or 0
	if drawn then
		M.set_state(const.STATE_KEY.prev_image_height, { [key] = image_height })
	end

	local below = ui.Rect({ x = area.x, y = area.y + image_height, w = area.w, h = area.h - image_height })
	ya.preview_widget(job, { text(lines, below) })
	M.set_state(const.STATE_KEY.prev_metadata_area, not job.args.no_metadata and {
		x = below.x, y = below.y, w = below.w, h = below.h,
		win_x = area.x, win_y = area.y, win_w = area.w, win_h = area.h,
	} or nil)
end

M.current_file = ya.sync(function()
	local h = cx.active.current.hovered
	if not h then
		return
	end
	return tostring(h.url)
end)

function M.error(s, ...)
	ya.notify({ title = "center-media", content = string.format(s, ...), timeout = 3, level = "error" })
end

function M.tbl_to_set(t1)
	local set = {}

	for _, v in ipairs(t1) do
		set[v] = true
	end

	return set
end

return M
