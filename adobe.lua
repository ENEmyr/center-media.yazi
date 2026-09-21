--- @since 26.9.1

local M = {}
local const = require(".const")
local utils = require(".utils")

local function image_layer_count(job)
	local cache = ya.file_cache({ file = job.file, skip = 0 })
	if not cache then
		return 0
	end
	local layer_count = utils.get_states(const.STATE_KEY.layers, tostring(cache))
	if layer_count then
		return layer_count
	end
	local output, err = Command("identify")
		:arg({ tostring(utils.path(job)) })
		:output()
	if err or not output then
		return 0
	end
	layer_count = 0
	for line in output.stdout:gmatch("[^\r\n]+") do
		if line:match("%S") then
			layer_count = layer_count + 1
		end
	end
	utils.set_states(const.STATE_KEY.layers, tostring(cache), layer_count)
	return layer_count
end

function M:peek(job)
	-- Past the end of the metadata, scrolling steps through the layers.
	return utils.peek(self, job, ya.file_cache(job), function()
		return image_layer_count(job) >= 1 + utils.step(job)
	end)
end

function M:preload(job)
	local err_msg = ""

	-- NOTE: Preload image

	local cache_img_url = ya.file_cache(job)
	local cache_img_url_cha = cache_img_url and fs.cha(cache_img_url)

	-- NOTE: Only generate preview image when cache image is not exist
	if not cache_img_url_cha or cache_img_url_cha.len <= 0 then
		local cache_img_status, image_preload_err
		local layer_index = utils.step(job)
		if layer_index > 0 then
			layer_index = math.min(layer_index, math.max(0, image_layer_count(job) - 1))
		end
		local cache_img_url_tmp = Url(cache_img_url .. ".tmp")
		if fs.cha(cache_img_url_tmp) then
			fs.remove("file", cache_img_url_tmp)
		end
		local tmp_file_path, _ = type(fs.unique) == "function" and fs.unique("file", cache_img_url_tmp)
			or fs.unique_name(cache_img_url_tmp)
		cache_img_status, image_preload_err = require("magick")
			.with_limit()
			:arg({
				"-background",
				"none",
				tostring(utils.path(job)) .. "[" .. tostring(
					layer_index
				) .. "]",
				"-auto-orient",
				"-strip",
				"-resize",
				string.format("%dx%d>", rt.preview.max_width, rt.preview.max_height),
				"-quality",
				rt.preview.image_quality,
				string.format("PNG32:%s", tostring(tmp_file_path)),
			})
			:status()
		if cache_img_status then
			os.rename(tostring(tmp_file_path), tostring(cache_img_url))
		end

		if not cache_img_status and image_preload_err then
			ya.dbg("center-media", image_preload_err)
			err_msg = err_msg .. (image_preload_err and (tostring(image_preload_err)) or "")
		end
	end

	-- NOTE: Get mediainfo and save to cache folder
	return utils.cache_mediainfo(job, err_msg)
end

return M
