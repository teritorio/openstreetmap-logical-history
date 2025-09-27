# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'net/http'
require 'uri'
require 'json'
require 'active_support/all'
require './logical_history/conflation'


Conflation = LogicalHistory::Conflation

class OSMSource
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
      _selector: String,
      date_start: String,
      date_end: String
    ).void
  }
  def self.check_params!(bbox, _selector, date_start, date_end)
    raise 'Date range too large (max 90 days)' if Date.parse(date_end) - Date.parse(date_start) > 90
    raise 'Bounding box too large (max 0.2 degrees wide)' if bbox[2] - bbox[0] > 0.2
    raise 'Bounding box too large (max 0.2 degrees wide)' if bbox[3] - bbox[1] > 0.2
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

  sig {
    params(
      data_start: T::Array[LogicalHistory::OSMObject],
      data_end: T::Array[LogicalHistory::OSMObject],
      demi_distance: Float,
    ).returns(T::Array[[
      T::Hash[Integer, LogicalHistory::OSMObject],
      T::Array[T::Hash[Symbol, T.untyped]]
    ]])
  }
  def self.cluster(data_start, data_end, demi_distance)
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
end
