# frozen_string_literal: true
# typed: strict

require 'async'
require 'sorbet-runtime'
require 'net/http'
require 'uri'
require 'json'
require 'active_support/all'
require './logical_history/conflation'
require './osm_api/osm_source'


class Ohsome < OSMSource
  extend T::Sig

  sig {
    params(
      path: String,
      bbox: [Float, Float, Float, Float],
      _selector: String,
      dates: T::Array[String],
    ).returns(String)
  }
  def self.fetch(path, bbox, _selector, dates)
    ohsome_url = "https://api.ohsome.org/v1/#{path}/geometry"
    data = {
      bboxes: bbox.each_slice(2).collect(&:reverse).flatten.join(','),
      time: dates.join(','),
      # Todo convert selector to ohsome filter syntax
      # Very slow with type filter
      filter: 'type:node or type:way',
      # showMetadata: true,
      properties: 'metadata,tags', # ,contributionTypes',
      clipGeometry: false,
    }
    puts [ohsome_url, data.to_json]

    uri = URI(ohsome_url)
    response = Net::HTTP.post_form(uri, data)

    raise response.body if !response.is_a?(Net::HTTPSuccess)

    T.must(response.body)
  rescue StandardError => e
    raise e.message
  end

  sig {
    params(
      bbox: [Float, Float, Float, Float],
      selector: String,
      date_start: String,
      date_end: String
    ).returns([
        T::Array[T::Hash[String, T.untyped]],
        T::Array[T::Hash[String, T.untyped]]
      ])
  }
  def self.fetch_osm_at_date(bbox, selector, date_start, date_end)
    check_params!(bbox, selector, date_start, date_end)

    start, (changes, changes_ids) = Sync { |task|
      [
        task.async {
          start = fetch('elements', bbox, selector, [date_start])
          JSON.parse(start)['features']
        },
        task.async {
          changes = fetch('contributions/latest', bbox, selector, [date_start, date_end])
          changes = JSON.parse(changes)['features']
          changes_ids = changes.to_set{ |f| f['properties']['@osmId'] }
          [changes, changes_ids]
        }
      ]
    }.map(&:wait)

    start = start.select{ |f| changes_ids.include?(f['properties']['@osmId']) }
    [start, changes]
  end

  sig {
    params(
      osm_data: T::Array[T::Hash[String, T.untyped]],
      local_srid: Integer,
    ).returns(
      T::Array[OSMObject]
    )
  }
  def self.to_osmobject(osm_data, local_srid)
    geos_factory = OSMObject.build_geos_factory(local_srid)
    osm_data.collect{ |f|
      OSMObject.new(
        objtype: f['properties']['@osmType'],
        id: f['properties']['@osmId'].split('/').last.to_i,
        geojson_geometry: f['geometry'].to_json,
        geos_factory: geos_factory,
        deleted: f['properties']['@deletion'] || false,
        members: nil, ##################### TODO
        version: f['properties']['@version'],
        username: nil, # TODO
        created: f['properties']['@timestamp'] || f['properties']['@lastEdit'],
        tags: f['properties'].select{ |k, _v| !k.start_with?('@') }.to_h
      )
    }
  end

  sig {
    params(
      bbox: [Float, Float, Float, Float],
      selector: String,
      date_start: String,
      date_end: String,
      srid: Integer,
      demi_distance: Float
    ).returns(T::Array[[
      T::Hash[Integer, OSMObject],
      T::Array[T::Hash[Symbol, T.untyped]]
    ]])
  }
  def self.struct(bbox, selector, date_start, date_end, srid, demi_distance)
    data_start, data_end = fetch_osm_at_date(bbox, selector, date_start, date_end)

    data_start = to_osmobject(data_start, srid)
    data_end = to_osmobject(data_end, srid)

    cluster(data_start, data_end, demi_distance)
  end
end
