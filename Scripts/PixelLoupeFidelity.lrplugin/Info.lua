-- PixelLoupe Fidelity: makes Lightroom's reference exports for PixelLoupe's fidelity fixtures (see Scripts/fidelity.sh).
-- Add it in File ▸ Plug-in Manager, then run Library ▸ Plug-in Extras ▸ Export Fidelity References…
return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,
	LrToolkitIdentifier = "net.tedlee.pixelloupe.fidelity",
	LrPluginName = "PixelLoupe Fidelity",
	LrPluginInfoUrl = "https://github.com/twlatl/PixelLoupe",
	LrLibraryMenuItems = {
		{ title = "Export Fidelity References…", file = "ExportReferences.lua" },
	},
	VERSION = { major = 1, minor = 0, revision = 0 },
}
