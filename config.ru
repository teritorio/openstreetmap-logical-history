# frozen_string_literal: true

require 'bundler/setup'
require 'hanami/api'
require 'json'
require_relative 'overpass/overpass_logical_history'

class App < Hanami::API
  get '/api/0.1/overpass_logical_history' do
    srid = params[:srid] || 2154
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
    date_end = params[:date_end] || Time.now.utc.iso8601

    objects_links_groups = OverspassLogicalHistory.struct(bbox, selector, date_start, date_end, srid, demi_distance)

    body = OverspassLogicalHistory.to_geojson(objects_links_groups, bbox).to_json

    [
      200,
      {
        'Content-Type' => 'application/geo+json',
        'Access-Control-Allow-Origin' => '*',
      },
      body
    ]
  rescue RuntimeError => e
    [
      400,
      { 'Access-Control-Allow-Origin' => '*' },
      e.message
    ]
  end
end

run App.new
