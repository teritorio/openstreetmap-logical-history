# frozen_string_literal: true

source 'https://rubygems.org'

# git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '>= 3'

gem 'activesupport'
gem 'levenshtein-ffi'
gem 'rego'
gem 'rgeo-geojson'
gem 'rgeo-proj4'
gem 'rgl'
gem 'sorbet-runtime'
gem 'sorted_set', '~> 1.1'

group :server, optional: true do
  gem 'async', '~> 2.33'
  gem 'hanami-api'
  gem 'moneta', '~> 1.6'
  gem 'puma', '~> 6.0'
  gem 'rackup', '~> 2.3'
  gem 'sentry-ruby', '~> 5.27'
end

group :development do
  gem 'json'
  gem 'rake'
  gem 'rexml'
  gem 'rubocop', require: false
  gem 'ruby-lsp', require: false
  gem 'sorbet'
  gem 'sorbet-rails'
  gem 'tapioca', require: false
  gem 'test-unit'

  # # Only for sorbet typechecker
  # gem 'psych'
  # gem 'racc'
  # gem 'rbi'
end
