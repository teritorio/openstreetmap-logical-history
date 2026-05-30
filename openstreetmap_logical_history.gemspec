# frozen_string_literal: true

require_relative 'lib/osm_logical_history/version'

Gem::Specification.new do |spec|
  spec.name = 'openstreetmap_logical_history'
  spec.version = OSMLogicalHistory::VERSION
  spec.authors = ['Frédéric Rodrigo']
  spec.email = ['fred.rodrigo@gmail.com']

  spec.summary = 'OpenStreetMap Sementic History Recovery'
  spec.description = 'OpenStreetMap Sementic History Recovery.'
  spec.homepage = 'https://github.com/teritorio/openstreetmap-logical-history'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0.0'
  spec.required_rubygems_version = '>= 3.3.11'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)

  spec.require_path = 'lib'
  spec.files = Dir[
    '{lib,spec}/**/*',
    'Gemfile',
    'README.md',
    gemspec,
  ]

  spec.add_dependency 'activesupport', '~> 8.0.3'
  spec.add_dependency 'levenshtein-ffi', '~> 1.1.0'
  spec.add_dependency 'rego', '~> 4.2.2'
  spec.add_dependency 'rgeo-geojson', '~> 2.2.0'
  spec.add_dependency 'rgeo-proj4', '~> 4.0.0'
  spec.add_dependency 'rgl', '~> 0.6.6'
  spec.add_dependency 'sorbet-runtime', '~> 0.6.12586'
  spec.add_dependency 'sorted_set', '~> 1.1'

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
