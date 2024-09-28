# frozen_string_literal: true

require 'bundler/setup'
require 'hanami/api'
require 'json'
require_relative 'overpass/overpass_logical_history'

class App < Hanami::API
  get '/api/0.1/overpass_logical_history' do
    srid = params[:srid] || 2154
    demi_distance = params[:distance] || 200.0 # m

    bbox = params[:bbox] || '43.57582751611194,-1.4865185506147705,43.57668833005737,-1.4857594854635559' # Ondres plage
    date_start = params[:date_start] || '2023-01-01T00:00:00Z' # format ISO 8601
    date_end = params[:date_end] || '2024-09-01T00:00:00Z' # format ISO 8601

    objects, links = OverspassLogicalHistory.struct(bbox, date_start, date_end, srid, demi_distance)

    body = OverspassLogicalHistory.to_geojson(objects, links).to_json

    [
      200,
      { 'Content-Type' => 'application/geo+json' },
      body
    ]
  end
end

run App.new
