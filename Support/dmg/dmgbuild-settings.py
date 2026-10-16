# Layout of HorizonNotch.dmg for dmgbuild (https://dmgbuild.readthedocs.io).
# scripts/make-dmg.sh passes: -D app=<path to .app> -D background=<tiff> -D icon=<icns>
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

icon = defines.get("icon")
background = defines["background"]

# Window: 640 × 420 points, matching the background picture.
window_rect = ((200, 160), (640, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
label_pos = "bottom"
arrange_by = None
# Left and right of the arrow in the background.
icon_locations = {
    app_name: (170, 205),
    "Applications": (470, 205),
}
