# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'net/http'
require 'uri'
require 'json'
require 'active_support/all'
require_relative '../osm_logical_history/conflation'
require_relative 'osm_source'


class Overpass < OSMSource
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
    bbox = bbox.each_slice(2).collect(&:reverse).flatten.join(',')

    overpass_query = <<-QUERY
    [timeout:120][adiff:"#{date_start}","#{date_end}"];
    (
      node#{selector}(#{bbox});
      way#{selector}(#{bbox});
    );
    out meta geom;
    relation#{selector}(#{bbox});
    out meta geom(#{bbox});
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
      node: T.nilable(T::Hash[String, T.untyped])
    ).returns(T.nilable([Float, Float]))
  }
  def self.overpass_node_to_coordinate(node)
    return if node.nil? || node['lat'].nil? || node['lon'].nil?

    [node['lon'].to_f, node['lat'].to_f]
  end

  sig {
    params(
      way: T::Hash[String, T.untyped]
    ).returns(T.nilable(T::Array[[Float, Float]]))
  }
  def self.overpass_way_to_coordinates(way)
    return if !way['nd'].is_a?(Array)

    coords = way['nd'].collect{ |node| overpass_node_to_coordinate(node) }.compact
    coords if coords.size >= 2
  end

  sig {
    params(
      relation: T::Hash[String, T.untyped]
    ).returns(T.nilable(T::Array[T::Array[[Float, Float]]]))
  }
  def self.overpass_relation_to_coordinates(relation)
    return if !relation['member'].is_a?(Array)

    relation['member'].select{ |member| member['type'] == 'way' }.collect{ |way|
      overpass_way_to_coordinates(way)
    }.compact.presence
  end

  sig {
    params(
      osm_data: T::Array[T::Hash[String, T.untyped]],
      geos_factory: T.proc.params(geojson_geometry: String).returns(T.nilable(RGeo::Feature::Geometry)),
    ).returns(
      T::Array[OSMLogicalHistory::OSMObject]
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
      geojson_geometry = (
        case element['type']
        when 'node'
          coords = overpass_node_to_coordinate(element)
          { 'type' => 'Point', 'coordinates' => coords } if !coords.nil?

        when 'way'
          coords = overpass_way_to_coordinates(element)
          if coords.nil?
            nil
          elsif element['nd'][0] == element['nd'][-1]
            coords << T.must(coords[0]) if coords.size >= 3 && coords[0] != coords[-1]
            { 'type' => 'Polygon', 'coordinates' => [coords] }
          elsif coords.size
            { 'type' => 'LineString', 'coordinates' => coords }
          end

        when 'relation'
          coords = overpass_relation_to_coordinates(element)
          if coords.nil?
            nil
          elsif coords.size == 1
            { 'type' => 'LineString', 'coordinates' => coords[0] }
          else
            { 'type' => 'MultiLineString', 'coordinates' => coords }
          end
        end
      )
      puts geojson_geometry.to_json
      [element, geojson_geometry] if element['type'] != 'relation' || !geojson_geometry.nil?
    }.compact.collect{ |element, geojson_geometry|
      OSMObject.new(
        objtype: element['type'],
        id: element['id'].to_i,
        geojson_geometry: geojson_geometry.to_json,
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
      T::Hash[Integer, OSMLogicalHistory::OSMObject],
      T::Array[T::Hash[Symbol, T.untyped]]
    ]])
  }
  def self.struct(bbox, selector, date_start, date_end, srid, demi_distance)
    xml = fetch_osm_at_date(bbox, selector, date_start, date_end)
    raise 'Empty response from Overpass API' if xml.nil? || xml.empty?

    data_start, data_end = parse_xml(xml)

    geos_factory = OSMLogicalHistory.build_geos_factory(srid)

    data_start = overpass_to_geojson(data_start, geos_factory)
    data_end = overpass_to_geojson(data_end, geos_factory)

    geos_bbox = build_geos_bbox(geos_factory, bbox)
    data_start, data_end = filter_clip(data_start, data_end, geos_bbox)

    cluster(data_start, data_end, demi_distance)
  end
end
