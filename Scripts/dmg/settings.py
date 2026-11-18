# dmgbuild settings for the release disk image (Scripts/release.sh): PixelLoupe.app and an Applications
# shortcut over background.tiff, each in one of its rounded squares, with the arrow between them.
#
#   dmgbuild -s Scripts/dmg/settings.py -D app=<PixelLoupe.app> -D background=Scripts/dmg/background.tiff \
#     "<volume name>" <output.dmg>
#
# Coordinates are Finder points from the window's top left. background.tiff is 600 × 400 points, with a
# 1200 × 800 pixel image for Retina displays; its source is Design/DMG background.pxd. The rounded squares
# are 154 points wide, centered at (116, 200) and (501, 200). Icon positions are the icons' centers, so they
# sit a little above the squares' centers to leave room for the names underneath.
app = defines["app"]

# APFS with LZFSE compression (ULFO), which Sparkle recommends: quicker to open than zlib's UDZO.
filesystem = "APFS"
format = "ULFO"
size = None

files = [(app, "PixelLoupe.app")]
symlinks = {"Applications": "/Applications"}

background = defines["background"]

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
window_rect = ((200, 120), (600, 432))

icon_size = 96
text_size = 13
icon_locations = {
    "PixelLoupe.app": (116, 188),
    "Applications": (501, 188),
}
