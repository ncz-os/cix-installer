project('ncz-screensaver-chooser', 'vala', version: '0.1.0')

gtk = dependency('gtk4', version: '>=4.10')
gio = dependency('gio-2.0')
gee = dependency('gee-0.8')

executable(
  'ncz-screensaver-chooser',
  'src/main.vala',
  dependencies: [gtk, gio, gee],
  install: true,
)
