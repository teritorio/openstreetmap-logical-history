# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'net/http'
require 'uri'
require 'json'
require 'active_support/all'
require './logical_history/conflation'
require './osm_api/osm_source'


class Overspass < OSMSource
  extend T::Sig

  sig {
    params(
      bbox: [Float, Float, Float, Float],
      selector: String,
      date_start: String,
      date_end: String
    ).returns(T.nilable(String))
  }
  def self.fetch_osm_at_date(bbox, selector, date_start, date_end)
    check_params!(bbox, selector, date_start, date_end)

    overpass_url = 'https://overpass-api.de/api/interpreter'
    bbox = bbox.join(',')

    overpass_query = <<-QUERY
    [adiff:"#{date_start}","#{date_end}"];
    (
      node#{selector}(#{bbox});
      way#{selector}(#{bbox});
    );
    out meta geom;
    QUERY
    puts [overpass_url, overpass_query]

    uri = URI(overpass_url)
    response = Net::HTTP.post_form(uri, 'data' => overpass_query)

    raise response.body if !response.is_a?(Net::HTTPSuccess)

    response.body
  rescue StandardError => e
    raise e.message
  end

  sig {
    params(
      xml: String,
    ).returns([
      T::Array[T::Hash[String, T.untyped]],
      T::Array[T::Hash[String, T.untyped]]
    ])
  }
  def self.parse_xml(xml)
    h = Hash.from_xml(xml)
    old = []
    new = []
    actions = h.dig('osm', 'action')
    actions = [actions] if actions.is_a?(Hash)
    actions&.collect{ |action|
      case action['type']
      when 'delete'
        old << action['old']
        new << action['new'].transform_values!{ |o| o.except!('visible').merge!('deleted' => true) }
      when 'create'
        new << action.except('type')
      when 'modify'
        old << action['old']
        new << action['new']
      else
        raise "Unknown action type: #{action['type']}"
      end
    }
    [old, new]
  end

  sig {
    params(
      osm_data: T::Array[T::Hash[String, T.untyped]],
      geos_factory: T.proc.params(geojson_geometry: String).returns(T.nilable(RGeo::Feature::Geometry)),
    ).returns(
      T::Array[OSMObject]
    )
  }
  def self.overpass_to_geojson(osm_data, geos_factory)
    osm_data = osm_data.collect{ |g|
      g.collect{ |type, element|
        element['type'] = type
        element
      }
    }.flatten(2)

    osm_data.collect{ |element|
      OSMObject.new(
        objtype: element['type'],
        id: element['id'].to_i,
        geojson_geometry: (
          if element['type'] == 'node'
            if !element['lat'].nil? && !element['lon'].nil?
              {
                'type' => 'Point',
                'coordinates' => [element['lon'].to_f, element['lat'].to_f]
              }
            end
          elsif element['type'] == 'way'
            if element['nd'].nil?
              nil
            elsif element['nd'][0] == element['nd'][-1]
              {
                'type' => 'Polygon',
                'coordinates' => [element['nd'].select{ |node|
                  !node['lon'].nil? && !node['lat'].nil?
                }.map{ |node|
                  [node['lon'].to_f, node['lat'].to_f]
                }]
              }
            else
              {
                'type' => 'LineString',
                'coordinates' => element['nd'].select{ |node|
                  !node['lon'].nil? && !node['lat'].nil?
                }.map{ |node|
                  [node['lon'].to_f, node['lat'].to_f]
                }
              }
            end
          end
        ).to_json,
        geos_factory: geos_factory,
        deleted: element['deleted'] || false,
        members: nil, ##################### TODO
        version: element['version'].to_i,
        username: element['user'],
        created: element['timestamp'],
        tags: element['tag'].nil? ? {} : (element['tag'].is_a?(Array) ? element['tag'] : [element['tag']]).to_h{ |p| [p['k'], p['v']] }
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
    xml = fetch_osm_at_date(bbox, selector, date_start, date_end)
    raise 'Empty response from Overpass API' if xml.nil? || xml.empty?

    data_start, data_end = parse_xml(xml)

    geos_factory = OSMObject.build_geos_factory(srid)

    data_start = overpass_to_geojson(data_start, geos_factory)
    data_end = overpass_to_geojson(data_end, geos_factory)

    geos_bbox = build_geos_bbox(geos_factory, bbox)
    data_start, data_end = filter_clip(data_start, data_end, geos_bbox)

    cluster(data_start, data_end, demi_distance)
  end
end
