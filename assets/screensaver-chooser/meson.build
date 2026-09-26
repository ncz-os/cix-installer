project('ncz-screensaver-chooser', 'vala', version: '0.2.0')

gtk = dependency('gtk4', version: '>=4.10')
gee = dependency('gee-0.8')
peas = dependency('libpeas-2')
json = dependency('json-glib-1.0')
singularity = dependency('singularity-1.0')

shared_module(
  'screensaver-chooser',
  'src/screensaver_chooser.vala',
  dependencies: [gtk, gee, peas, json, singularity],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/screensaver-chooser',
)

configure_file(
  input: 'screensaver-chooser.plugin',
  output: 'screensaver-chooser.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/screensaver-chooser',
)
