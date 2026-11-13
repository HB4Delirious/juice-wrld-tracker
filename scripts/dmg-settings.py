# dmgbuild layout for the Juice Tracker DMG window. Used by scripts/make-dmg.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=... -D background=... "Juice Tracker" dist/JuiceTracker.dmg
# Positions match design/dmg-background.svg (660x420): app on the left, Applications on the right, arrow between.
app = defines["app"]  # noqa: F821  (dmgbuild provides `defines`)
background = defines["background"]  # noqa: F821

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = app + "/Contents/Resources/AppIcon.icns"  # volume icon in Finder's sidebar
icon_locations = {"JuiceTracker.app": (165, 220), "Applications": (495, 220)}

window_rect = ((200, 140), (660, 448))  # 420 of background + the title bar
default_view = "icon-view"
icon_size = 112
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
