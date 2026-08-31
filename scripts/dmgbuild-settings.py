# dmgbuild settings for the OpenNOW release DMG.

volume_name = 'OpenNOW'
format = 'UDZO'

files = [defines['app_path']]
symlinks = {'Applications': '/Applications'}

background = defines['background']

icon_locations = {
    'OpenNOW.app': (180, 238),
    'Applications': (620, 238),
}

window_rect = ((100, 100), (800, 560))
default_view = 'icon-view'
arrange_by = None
label_pos = 'bottom'
icon_size = 96
text_size = 16.0

show_toolbar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
