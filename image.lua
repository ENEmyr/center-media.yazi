--- @since 26.9.1

local M = {}
local const = require(".const")
local utils = require(".utils")

function M:peek(job)
	return utils.peek(self, job, ya.file_cache({ skip = 0, args = job.args, file = job.file, area = job.area }))
end

function M:preload(job)
	local err_msg = ""
	local is_valid_utf8_path = utils.is_valid_utf8(tostring(utils.path(job)))

	-- NOTE: Preload image

	local mime = job.mime:match(".*/(.*)$")
	local is_svg = mime == "svg+xml"
	local is_magick = const.magick_image_mimes[mime]
	local no_skip_job = { skip = 0, file = job.file, args = job.args, area = job.area }
	local cache_img_url = ya.file_cache(no_skip_job)
	local cache_img_url_cha = cache_img_url and fs.cha(cache_img_url)

	-- NOTE: Only generate preview image when cache image is not exist
	if not cache_img_url_cha or cache_img_url_cha.len <= 0 then
		local cache_img_status, image_preload_err
		if not is_valid_utf8_path then
			-- NOTE: Case not valid utf8 path, use trick to generate preview image
			if is_svg then
				local cache_img_url_tmp = Url(cache_img_url .. ".tmp")
				if fs.cha(cache_img_url_tmp) then
					fs.remove("file", cache_img_url_tmp)
				end
				local tmp_file_path, _ = type(fs.unique) == "function" and fs.unique("file", cache_img_url_tmp)
					or fs.unique_name(cache_img_url_tmp)
				-- svg under invalid utf8 path
				cache_img_status, image_preload_err = require("magick")
					.with_limit()
					:arg({
						"-background",
						"none",
						tostring(utils.path(job)),
						"-auto-orient",
						"-strip",
						string.format("%dx%d>", rt.preview.max_width, rt.preview.max_height),
						"-quality",
						rt.preview.image_quality,
						string.format("PNG32:%s", tostring(tmp_file_path)),
					})
					:status()
				if cache_img_status then
					os.rename(tostring(tmp_file_path), tostring(cache_img_url))
				end
			end
		else
			-- NOTE: Case valid utf8 path, use image, svg, or magick module
			local image_module = is_svg and "svg" or (is_magick and "magick" or "image")
			cache_img_status, image_preload_err = require(image_module):preload(no_skip_job)
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
