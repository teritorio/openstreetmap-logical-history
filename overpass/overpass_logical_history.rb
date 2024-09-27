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
    sig { returns(T::Hash[String, T.untyped]) }
    def to_geojson
      {
        type: 'Feature',
        properties: {
          locha_id: locha_id,
          objtype: objtype,
          id: id,
          geom_distance: geom_distance,
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
        geometry: JSON.parse(geom)
      }
    end
  end

  sig {
    params(
      bbox: String,
      date_start: String,
      date_end: String
    ).returns([
      T::Array[T::Hash[String, T.untyped]],
      T::Array[T::Hash[String, T.untyped]]
    ])
  }
  def self.fetch_osm_at_data(bbox, date_start, date_end)
    overpass_url = 'https://overpass-api.de/api/interpreter'

    overpass_query = <<-QUERY
    [diff:"#{date_start}","#{date_end}"];
    (
      node(#{bbox});
      way(#{bbox});
    );
    out meta geom;
    QUERY

    uri = URI(overpass_url)
    response = Net::HTTP.post_form(uri, 'data' => overpass_query)

    raise response.body if !response.is_a?(Net::HTTPSuccess)

    h = Hash.from_xml(response.body)
    old = []
    new = []
    h['osm']['action'].collect{ |action|
      case action['type']
      when 'delete'
        old << action['old']
      when 'create'
        new << action.except('type')
      when 'modify'
        old << action['old']
        new << action['new']
      end
    }
    [old, new]
  end

  sig {
    params(
      osm_data: T::Array[T::Hash[String, T.untyped]]
    ).returns(
      T::Array[OSMObject]
    )
  }
  def self.overpass_to_geojson(osm_data)
    osm_data = osm_data.collect{ |g|
      g.collect{ |type, element|
        element['type'] = type
        element
      }
    }.flatten(2)

    osm_data.select{ |element| !element['tag'].nil? && %w[node way].include?(element['type']) }.collect{ |element|
      OSMObject.new(
        locha_id: 0,
        objtype: 'node',
        id: element['id'].to_i,
        geom: (
          case element['type']
          when 'node'
            {
              'type' => 'Point',
              'coordinates' => [element['lon'].to_f, element['lat'].to_f]
            }
          when 'way'
            {
              'type' => 'LineString',
              'coordinates' => element['nd'].map{ |node|
                [node['lon'].to_f, node['lat'].to_f]
              }
            }
          end
        ).to_json,
        deleted: false,
        members: nil, ##################### TODO
        version: element['version'].to_i,
        username: element['user'],
        created: element['timestamp'],
        tags: (element['tag'].is_a?(Array) ? element['tag'] : [element['tag']]).to_h{ |p| [p['k'], p['v']] }
      )
    }
  end

  sig { params(object: T.nilable(OSMObject)).returns(T.nilable(String)) }
  def self.id(object)
    return nil if object.nil?

    "#{object.objtype[0]}#{object.id}_#{object.version}"
  end

  sig { params(object: OSMObject).returns(String) }
  def self.node(object)
    tags = object.tags.to_a.sort.collect{ |k, v| "#{k}=#{v[0..20]}" }.join("\n").gsub('"', '')
    "#{object.objtype[0]}#{object.id}_#{object.version} [label=\"#{object.objtype[0]}#{object.id} v#{object.version}\n\n#{tags}\"];"
  end

  sig {
    params(
      bbox: String,
      date_start: String,
      date_end: String,
      srid: Integer,
      demi_distance: Float
    ).returns([
      T::Hash[String, OSMObject],
      T::Array[T::Hash[Symbol, T.nilable(String)]]
    ])
  }
  def self.struct(bbox, date_start, date_end, srid, demi_distance)
    data_start, data_end = OverspassLogicalHistory.fetch_osm_at_data(bbox, date_start, date_end)
    data_start = OverspassLogicalHistory.overpass_to_geojson(data_start)
    data_end = OverspassLogicalHistory.overpass_to_geojson(data_end)

    conf = Conflation.conflate(data_start, data_end, srid, demi_distance)

    objects = (data_start + data_end).index_by{ |e| id(e) }
    links = conf.collect{ |c|
      {
        before: id(c.before),
        after: id(c.after),
      }.compact
    }

    [objects, links]
  end

  sig {
    params(
      objects: T::Hash[String, OSMObject],
      links: T::Array[T::Hash[Symbol, T.nilable(String)]],
    ).returns(T::Hash[String, T.untyped])
  }
  def self.to_geojson(objects, links)
    {
      type: 'FeatureCollection',
      features: objects.collect{ |id, feature|
        geojson = feature.to_geojson
        geojson['id'] = id
        geojson
      },
      metadata: { links: links },
    }
  end

  sig { params(objects: T::Hash[String, OSMObject], links: T::Array[T::Hash[Symbol, T.nilable(String)]], date_start: String, date_end: String).returns(String) }
  def self.graviz(objects, links, date_start, date_end)
    objects_before = links.collect{ |c| c[:before] }.compact.collect{ |c| objects[c] }
    objects_after = links.collect{ |c| c[:after] }.compact.collect{ |c| objects[c] }

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
