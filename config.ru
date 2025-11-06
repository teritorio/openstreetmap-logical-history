# frozen_string_literal: true

require 'sentry-ruby'
require 'bundler/setup'
require 'hanami/api'
require 'moneta'
require 'json'
require_relative 'lib/osm_api/overpass'
require_relative 'lib/osm_api/ohsome'

if ENV['SENTRY_DSN'].present?
  puts ENV['SENTRY_DSN'].inspect
  Sentry.init do |config|
    config.dsn = ENV['SENTRY_DSN']
    # enable performance monitoring
    config.traces_sample_rate = 1.0
    # get breadcrumbs from logs
    config.breadcrumbs_logger = [:http_logger]
  end
end

class App < Hanami::API
  use Sentry::Rack::CaptureExceptions

  remote_api = ENV['REMOTE_API'] == 'ohsome' ? Ohsome : Overpass

  cache = Moneta.build do
    adapter :LRUHash
  end

  def self.best_utm_zone(longitude, latitude)
    zone = (
      if latitude >= 56 && latitude < 64 && longitude >= 3 && longitude < 12
        # Special zone for Norway
        32
      elsif latitude >= 72 && latitude < 84
        # Special zones for Svalbard
        case longitude
        when 0...9 then 31
        when 9...21 then 33
        when 21...33 then 35
        when 33...42 then 37
        else zone
        end
      else
        ((longitude + 180) / 6).floor + 1
      end
    )

    latitude >= 0 ? 32_600 + zone : 32_700 + zone
  end

  get '/up' do
    204
  end

  get '/api/0.1/overpass_logical_history' do
    demi_distance = params[:distance] || 200.0 # m

    if (!params.key?(:bbox) || params[:bbox].empty?) && (!params.key?(:date_start).nil? || params[:date_start].empty?) && (!params.key?(:date_end).nil? || params[:date_end].empty?)
      params[:bbox] = '-1.4865185506147705,43.57582751611194,-1.4857594854635559,43.57668833005737' # Ondres plage
      params[:date_start] = '2023-08-01T00:00:00Z' # format ISO 8601
      params[:date_end] = '2023-09-30T00:00:00Z' # format ISO 8601
    end

    if params[:bbox].empty? || params[:date_start].empty?
      raise 'Missing bbox or date_start parameter'
    end

    bbox = params[:bbox]
    bbox = bbox.split(',').collect{ |c| Float(c, exception: true) }
    raise 'Invalid bbox' if bbox.size != 4 || T.must(bbox[0]) >= T.must(bbox[2]) || T.must(bbox[1]) >= T.must(bbox[3])

    bbox = [T.must(bbox[1]), T.must(bbox[0]), T.must(bbox[3]), T.must(bbox[2])]

    selector = params[:selector] || '' # e.g. "[highway=residential]"
    date_start = params[:date_start]
    date_end = params[:date_end]
    if date_end.nil? || date_end.empty?
      # Now, trunced to minute to allow caching
      n = Time.now.utc
      n -= n.sec
      date_end = n.iso8601
    end

    cache_key = [bbox, selector, date_start, date_end].join('/')
    body = cache.load(cache_key)
    if body.nil?
      lon = (bbox[0] + bbox[2]) / 2.0
      lat = (bbox[1] + bbox[3]) / 2.0
      srid = App.best_utm_zone(lon, lat)
      objects_links_groups = remote_api.struct(bbox, selector, date_start, date_end, srid, demi_distance)

      Moneta.new(:File, dir: 'moneta')
      body = remote_api.to_geojson(objects_links_groups, bbox).to_json

      cache.store(cache_key, body, expires_in: 3600) # 1 hour
    end

    [
      200,
      {
        'Content-Type' => 'application/geo+json',
        'Access-Control-Allow-Origin' => '*',
      },
      body
    ]
  rescue RuntimeError => e
    puts e.message
    puts e.backtrace
    [
      400,
      { 'Access-Control-Allow-Origin' => '*' },
      e.message
    ]
  end
end

run App.new
