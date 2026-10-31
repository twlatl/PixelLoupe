-- Library ▸ Plug-in Extras ▸ Export Fidelity References…
--
-- For each <fixtures>/<family>/<case>/ folder with a settings.xmp, imports the case's source.* (a new catalog photo,
-- never one of yours), applies the XMP's develop settings and exports reference.tif beside it: 16-bit TIFF, Display P3,
-- 2048 px on the long edge, as Scripts/fidelity.sh expects. A case with raw.<ext> and no source yet gets its source
-- first: the raw exported the same way with Color Grading off, so only Color Grading differs between source and
-- reference. Imported photos go in a "PixelLoupe Fidelity" collection, to remove from the catalog when done.

local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrExportSession = import "LrExportSession"
local LrFileUtils = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrPathUtils = import "LrPathUtils"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"

local function readFile(path)
	local file = io.open(path, "r")
	if not file then return nil end
	local contents = file:read("*a")
	file:close()
	return contents
end

-- The crs: attributes of a settings XMP as a develop settings table (numbers as numbers).
local function developSettings(xmp)
	local settings = {}
	for key, value in xmp:gmatch('crs:(%w+)="([^"]*)"') do
		settings[key] = tonumber(value) or value
	end
	-- Bookkeeping, not settings; new photos get the current process version.
	settings.Version = nil
	settings.ProcessVersion = nil
	settings.HasSettings = nil
	settings.RawFileName = nil
	return settings
end

-- The same settings with every Color Grading wheel at zero.
local function withoutColorGrading(settings)
	local copy = {}
	for key, value in pairs(settings) do
		copy[key] = (key:match("^ColorGrade%a+Sat$") or key:match("^ColorGrade%a+Lum$")) and 0 or value
	end
	return copy
end

local function firstFile(folder, base)
	for path in LrFileUtils.directoryEntries(folder) do
		local name = LrPathUtils.leafName(path)
		if LrPathUtils.removeExtension(name) == base and LrFileUtils.exists(path) == "file" then return path end
	end
	return nil
end

local function exportSettings(folder, name)
	return {
		LR_export_destinationType = "specificFolder",
		LR_export_destinationPathPrefix = folder,
		LR_export_useSubfolder = false,
		LR_collisionHandling = "overwrite",
		LR_renamingTokensOn = true,
		LR_tokens = "{{custom_token}}",
		LR_tokenCustomString = name,
		LR_extensionCase = "lowercase",
		LR_format = "TIFF",
		LR_export_bitDepth = 16,
		LR_tiff_compressionMethod = "compressionMethod_None",
		LR_export_colorSpace = "DisplayP3",
		LR_size_doConstrain = true,
		LR_size_doNotEnlarge = false,
		LR_size_resizeType = "longEdge",
		LR_size_maxWidth = 2048,
		LR_size_maxHeight = 2048,
		LR_size_units = "pixels",
		LR_size_resolution = 240,
		LR_outputSharpeningOn = false,
		LR_useWatermark = false,
		LR_minimizeEmbeddedMetadata = true,
		LR_removeLocationMetadata = true,
		LR_reimportExportedPhoto = false,
	}
end

-- Imports `path` (or finds it from an earlier run), applies `settings` and exports `name`.tif into `folder`.
local function render(catalog, collection, path, settings, folder, name)
	local photo = catalog:findPhotoByPath(path)
	catalog:withWriteAccessDo("PixelLoupe Fidelity", function()
		photo = photo or catalog:addPhoto(path)
		collection:addPhotos({ photo })
		photo:applyDevelopSettings(settings, "PixelLoupe Fidelity")
	end, { timeout = 60 })
	local session = LrExportSession { photosToExport = { photo }, exportSettings = exportSettings(folder, name) }
	for _, rendition in session:renditions() do
		local ok, message = rendition:waitForRender()
		if not ok then error(message or "export failed") end
	end
	local exported = LrPathUtils.child(folder, name .. ".tif")
	if LrFileUtils.exists(exported) ~= "file" then error("Lightroom didn't write " .. exported) end
end

local function findCases(root, all)
	local cases = {}
	for family in LrFileUtils.directoryEntries(root) do
		if LrFileUtils.exists(family) == "directory" then
			for folder in LrFileUtils.directoryEntries(family) do
				local settings = LrPathUtils.child(folder, "settings.xmp")
				local reference = LrPathUtils.child(folder, "reference.tif")
				if LrFileUtils.exists(settings) == "file" and (all or LrFileUtils.exists(reference) ~= "file") then
					table.insert(cases, folder)
				end
			end
		end
	end
	table.sort(cases)
	return cases
end

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext("PixelLoupe Fidelity", function(context)
		LrDialogs.attachErrorDialogToFunctionContext(context)
		local chosen = LrDialogs.runOpenPanel {
			title = "Choose the fidelity fixtures folder",
			prompt = "Choose",
			canChooseFiles = false,
			canChooseDirectories = true,
			allowsMultipleSelection = false,
		}
		if not chosen then return end
		local root = chosen[1]

		local missing = #findCases(root, false)
		local answer = LrDialogs.confirm(
			"Export Lightroom references for the fidelity fixtures?",
			string.format("%d of %d cases have no reference.tif yet. Each case's photo is imported into a "
				.. "\"PixelLoupe Fidelity\" collection; your own photos aren't touched.", missing, #findCases(root, true)),
			"Export Missing", "Cancel", "Export All")
		if answer == "cancel" then return end
		local cases = findCases(root, answer == "other")
		if #cases == 0 then return end

		local catalog = LrApplication.activeCatalog()
		local collection
		catalog:withWriteAccessDo("PixelLoupe Fidelity", function()
			collection = catalog:createCollection("PixelLoupe Fidelity", nil, true)
		end)

		local progress = LrProgressScope { title = "Exporting fidelity references", functionContext = context }
		local failures = {}
		for index, folder in ipairs(cases) do
			if progress:isCanceled() then break end
			progress:setCaption(LrPathUtils.leafName(LrPathUtils.parent(folder)) .. "/" .. LrPathUtils.leafName(folder))
			local ok, message = LrTasks.pcall(function()
				local settings = developSettings(readFile(LrPathUtils.child(folder, "settings.xmp")) or "")
				local source = firstFile(folder, "source")
				if not source then
					local raw = firstFile(folder, "raw")
					if not raw then error("no source.* or raw.*") end
					render(catalog, collection, raw, withoutColorGrading(settings), folder, "source")
					source = LrPathUtils.child(folder, "source.tif")
				end
				render(catalog, collection, source, settings, folder, "reference")
			end)
			if not ok then table.insert(failures, LrPathUtils.leafName(folder) .. ": " .. tostring(message)) end
			progress:setPortionComplete(index, #cases)
		end
		progress:done()

		if #failures > 0 then
			LrDialogs.message("Some fidelity references weren't exported", table.concat(failures, "\n"), "warning")
		else
			LrDialogs.message("Fidelity references exported", string.format("%d cases in %s.", #cases, root), "info")
		end
	end)
end)
