# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'net/http'
require 'uri'
require 'json'
require 'active_support/all'
require './logical_history/conflation'


Conflation = LogicalHistory::Conflation

module OverspassLogicalHistory
  extend T::Sig

  class OSMObject < LogicalHistory::OSMObject
    sig { returns(T::Hash[T.any(String, Symbol), T.untyped]) }
    def to_geojson
      {
        type: 'Feature',
        properties: {
          objtype: objtype,
          id: id,
          deleted: deleted,
          members: members,
          version: version,
          # changesets: changesets,
          username: username,
          created: created,
          tags: tags,
          # is_change: is_change,
          # group_ids: group_ids
        },
        geometry: JSON.parse(geojson_geometry)
      }
    end
  end

  sig {
    params(
      bbox: [Float, Float, Float, Float],
      selector: String,
      date_start: String,
      date_end: String
    ).returns(T.nilable(String))
  }
  def self.fetch_osm_at_date(bbox, selector, date_start, date_end)
    raise 'Date range too large (max 90 days)' if Date.parse(date_end) - Date.parse(date_start) > 90
    raise 'Bounding box too large (max 0.2 degrees wide)' if bbox[2] - bbox[0] > 0.2
    raise 'Bounding box too large (max 0.2 degrees wide)' if bbox[3] - bbox[1] > 0.2

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
      local_srid: Integer,
    ).returns(
      T::Array[OSMObject]
    )
  }
  def self.overpass_to_geojson(osm_data, local_srid)
    osm_data = osm_data.collect{ |g|
      g.collect{ |type, element|
        element['type'] = type
        element
      }
    }.flatten(2)

    geos_factory = OSMObject.build_geos_factory(local_srid)
    osm_data.select{ |element| %w[node way].include?(element['type']) }.collect{ |element|
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

  ID_CACHE = T.let(Hash.new { |h, k| h[k] = h.size }, T::Hash[String, Integer])

  sig { params(object: T.nilable(LogicalHistory::OSMObject), is_before: T::Boolean).returns(T.nilable(Integer)) }
  def self.id(object, is_before)
    return nil if object.nil?

    ID_CACHE["#{is_before ? 'b' : 'a'}#{object.objtype[0]}#{object.id}_#{object.version}"]
  end

  sig { params(object: LogicalHistory::OSMObject).returns(String) }
  def self.node(object)
    tags = object.tags.to_a.sort.collect{ |k, v| "#{k}=#{v[0..20]}" }.join("\n").gsub('"', '')
    "#{object.objtype[0]}#{object.id}_#{object.version} [label=\"#{object.objtype[0]}#{object.id} v#{object.version}\n\n#{tags}\"];"
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
    xml = OverspassLogicalHistory.fetch_osm_at_date(bbox, selector, date_start, date_end)
    raise 'Empty response from Overpass API' if xml.nil? || xml.empty?

    data_start, data_end = parse_xml(xml)
    data_start = OverspassLogicalHistory.overpass_to_geojson(data_start, srid)
    data_end = OverspassLogicalHistory.overpass_to_geojson(data_end, srid)

    # Remove objects without tags, unless they exist in the other side
    data_start_with_tags_ids = Set.new(data_start.select{ |e| !e.tags.empty? }.collect{ |e| [e.objtype, e.id] })
    data_end_with_tags_ids = Set.new(data_end.select{ |e| !e.tags.empty? }.collect{ |e| [e.objtype, e.id] })
    data_start = data_start.select{ |e| !e.tags.empty? || data_end_with_tags_ids.include?([e.objtype, e.id]) }
    data_end = data_end.select{ |e| !e.tags.empty? || data_start_with_tags_ids.include?([e.objtype, e.id]) }

    conf_group = Conflation.conflate_cluster(data_start, data_end, demi_distance)

    objects = data_start.index_by{ |e| id(e, true) }.merge(data_end.index_by{ |e| id(e, false) })
    conf_group.collect { |conf|
      links = conf.collect{ |c|
        {
          action: 'diff',
          # matches: [],
          before: id(c.before, true),
          after: id(c.after, false),
          diff_attribs: c.diff_attribs.presence,
          diff_tags: c.diff_tags.presence,
          reason: c.reason,
        }.compact
      }
      os = conf.collect { |l|
        [
          ([T.must(id(l.before, true)), T.must(objects[id(l.before, true)])] if !l.before.nil?),
          ([T.must(id(l.after, false)), T.must(objects[id(l.after, false)])] if !l.after.nil?),
        ]
      }.flatten(1).compact.to_h
      [os, links]
    }
  end

  sig {
    params(
      objects_links_groups: T::Array[[
        T::Hash[String, OSMObject],
        T::Array[T::Hash[Symbol, T.nilable(String)]]
      ]],
      bbox: [Float, Float, Float, Float],
    ).returns(T::Hash[String, T.untyped])
  }
  def self.to_geojson(objects_links_groups, bbox)
    {
      type: 'FeatureCollection',
      bbox: bbox,
      features: objects_links_groups.each_with_index.collect{ |objects_links, index|
        objects_links[0].collect{ |id, feature|
          geojson = feature.to_geojson
          geojson[:properties]['links'] = index
          geojson['id'] = id
          geojson
        }
      }.flatten(1),
      metadata: {
        links: objects_links_groups.each_with_index.to_h{ |objects_links, index| [index, objects_links[1]] },
        changesets: [],
      },
    }
  end

  sig { params(objects: T::Hash[String, OSMObject], links: T::Array[T::Hash[Symbol, T.nilable(String)]], date_start: String, date_end: String).returns(String) }
  def self.graviz(objects, links, date_start, date_end)
    objects_before = links.collect{ |c| c[:before] }.compact.collect{ |c| T.must(objects[c]) }
    objects_after = links.collect{ |c| c[:after] }.compact.collect{ |c| T.must(objects[c]) }

    links = links.select{ |c| !c[:before].nil? && !c[:after].nil? }.collect{ |c|
      "#{c[:before]} -> #{c[:after]};"
    }.join("\n  ")

    "
    digraph G {
      rankdir = LR;
      subgraph cluster_0 {
        label=\"#{date_start}\";
        color=gray;
        #{objects_before.collect{ |e| node(e) }.join("\n    ")}
      }

      subgraph cluster_1 {
        label=\"#{date_end}\";
        color=gray;
        #{objects_after.collect{ |e| node(e) }.join("\n    ")}
      }

      #{links}
    }"
  end
end
