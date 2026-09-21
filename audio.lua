--- @since 26.9.1

local M = {}
local const = require(".const")
local utils = require(".utils")

local function get_cover_layers(job)
	local cache = ya.file_cache({ file = job.file, skip = 0 })
	if not cache then
		return {}
	end
	local covers = utils.get_states(const.STATE_KEY.layers, tostring(cache))
	if covers and type(covers) == "table" then
		return covers
	end
	local output, err = Command("ffprobe"):arg({
		"-v",
		"error",
		"-select_streams",
		"v",
		"-show_entries",
		"stream=index:stream_disposition=attached_pic",
		"-of",
		"json",
		tostring(utils.path(job)),
	}):output()
	if err or not output then
		return {}
	end
	covers = {}
	local data = ya.json_decode(output.stdout)
	if type(data) == "table" and type(data.streams) == "table" then
		for _, stream in ipairs(data.streams) do
			if stream.disposition and stream.disposition.attached_pic == 1 then
				covers[#covers + 1] = stream.index
			end
		end
	end
	utils.set_states(const.STATE_KEY.layers, tostring(cache), covers)
	return covers
end

--- Which embedded picture the scroll position is on, counted from 1: one
--- further with every seek step, like the layers of an Adobe file.
local function cover_index(job)
	return utils.step(job) + 1
end

function M:peek(job)
	-- Scrolling steps through the embedded pictures, past the end of the
	-- metadata too while there are more.
	return utils.peek(self, job, ya.file_cache(job), function()
		return get_cover_layers(job)[cover_index(job)] ~= nil
	end)
end

function M:preload(job)
	local err_msg = ""

	-- NOTE: Preload image

	local cache_img_url = ya.file_cache(job)
	local cache_img_url_cha = cache_img_url and fs.cha(cache_img_url)

	-- NOTE: Only generate preview image when cache image is not exist
	if cache_img_url and (not cache_img_url_cha or cache_img_url_cha.len <= 0) then
		-- The cover the scroll position is on, or the last one past them. ffprobe
		-- reports streams by their index in the file, which "0:N" picks; without
		-- a cover, "0:v:0?" takes the first video stream if there is one.
		local covers = get_cover_layers(job)
		local position = utils.get_state(const.STATE_KEY.units) and cover_index(job) or 1
		local stream = covers[math.min(position, #covers)]
		local qv = 31 - math.floor(rt.preview.image_quality * 0.3)
		local audio_preload_output, audio_preload_err = Command("ffmpeg"):arg({
			"-v",
			"error",
			"-threads",
			1,
			"-i",
			tostring(utils.path(job)),
			"-map",
			stream and string.format("0:%d", stream) or "0:v:0?",
			"-an",
			"-sn",
			"-dn",
			"-vframes",
			1,
			"-q:v",
			qv,
			"-vf",
			string.format("scale=-1:'min(%d,ih)':flags=fast_bilinear", rt.preview.max_height / 2),
			"-f",
			"image2",
			"-y",
			tostring(cache_img_url),
		}):output()
		-- NOTE: Some audio types doesn't have cover image -> error ""
		if audio_preload_err then
			ya.dbg("center-media", audio_preload_err)
			err_msg = err_msg
				.. string.format(
					"Failed to start `%s`.\n Error: %s\n",
					"ffmpeg",
					tostring(audio_preload_err or (audio_preload_output and audio_preload_output.stderr or ""))
				)
		elseif
			audio_preload_output
			and type(audio_preload_output.stderr) == "string"
			and audio_preload_output.stderr:find("does not contain any stream")
		then
			ya.dbg("center-media", audio_preload_output and audio_preload_output.stderr)
			cache_img_url_cha = fs.cha(cache_img_url)
			if cache_img_url_cha then
				fs.remove("file", Url(cache_img_url))
			end
			-- NOTE: Workaround case audio has no cover image. Prevent regenerate preview image
			audio_preload_output, audio_preload_err = require("magick")
				.with_limit()
				:arg({
					"-size",
					"1x1",
					"canvas:none",
					string.format("PNG32:%s", cache_img_url),
				})
				:output()
			if
				(audio_preload_output and audio_preload_output.stderr ~= nil and audio_preload_output.stderr ~= "")
				or audio_preload_err
			then
				ya.dbg("center-media", audio_preload_err or (audio_preload_output and audio_preload_output.stderr))
				err_msg = err_msg
					.. string.format(
						"Failed to start `%s`.\n Error: %s\n",
						"magick",
						tostring(audio_preload_err or (audio_preload_output and audio_preload_output.stderr or ""))
					)
			end
		end
	end

	-- NOTE: Get mediainfo and save to cache folder
	return utils.cache_mediainfo(job, err_msg)
end

return M
