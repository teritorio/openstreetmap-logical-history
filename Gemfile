# frozen_string_literal: true

source 'https://rubygems.org'

# git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '>= 3'

gemspec

group :server, optional: true do
  gem 'async', '~> 2.33'
  gem 'hanami-api'
  gem 'moneta', '~> 1.6'
  gem 'puma', '>= 8.0.0'
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
