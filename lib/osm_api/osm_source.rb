# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'net/http'
require 'uri'
require 'json'
require 'active_support/all'
require_relative '../osm_logical_history/conflation'


Conflation = OSMLogicalHistory::Conflation

class OSMSource
  extend T::Sig

  class OSMObject < OSMLogicalHistory::OSMObject
    extend T::Sig

    sig { returns(T::Hash[T.any(String, Symbol), T.untyped]) }
    def to_geojson
      geojson_geometry_ = geojson_geometry
      {
        type: 'Feature',
        properties: {
          objtype: objtype[0],
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
        geometry: (JSON.parse(geojson_geometry_) if !geojson_geometry_.nil?)
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
    raise 'Date range too large (max 1 year)' if Date.parse(date_end) - Date.parse(date_start) > 365
    raise 'Bounding box too large (max 0.2 degrees wide)' if bbox[2] - bbox[0] > 0.2
    raise 'Bounding box too large (max 0.2 degrees wide)' if bbox[3] - bbox[1] > 0.2
  end

  ID_CACHE = T.let(Hash.new { |h, k| h[k] = h.size }, T::Hash[String, Integer])

  sig { params(object: T.nilable(OSMLogicalHistory::OSMObject), is_before: T::Boolean).returns(T.nilable(Integer)) }
  def self.id(object, is_before)
    return nil if object.nil?

    ID_CACHE["#{is_before ? 'b' : 'a'}#{object.objtype[0]}#{object.id}_#{object.version}"]
  end

  sig { params(object: OSMLogicalHistory::OSMObject).returns(String) }
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
        links: objects_links_groups.collect(&:last),
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
      geos_factory: T.proc.params(geojson_geometry: String).returns(T.nilable(RGeo::Feature::Geometry)),
      bbox: [Float, Float, Float, Float],
    ).returns(RGeo::Feature::Polygon)
  }
  def self.build_geos_bbox(geos_factory, bbox)
    g = { type: 'Polygon', coordinates: [[
      [bbox[0], bbox[1]],
      [bbox[2], bbox[1]],
      [bbox[2], bbox[3]],
      [bbox[0], bbox[3]],
      [bbox[0], bbox[1]]
    ]] }.to_json
    puts g
    T.cast(geos_factory.call(g), RGeo::Feature::Polygon)
  end

  sig {
    params(
      data_start: T::Array[OSMLogicalHistory::OSMObject],
      data_end: T::Array[OSMLogicalHistory::OSMObject],
      clip_polygon: T.nilable(RGeo::Feature::Polygon),
    ).returns([T::Array[OSMLogicalHistory::OSMObject], T::Array[OSMLogicalHistory::OSMObject]])
  }
  def self.filter_clip(data_start, data_end, clip_polygon)
    data_start_index = data_start.index_by{ |e| [e.objtype, e.id] }
    data_end = data_end.select{ |e|
      start = data_start_index[[e.objtype, e.id]]

      next(true) if start.nil?

      next(true) if start.tags != e.tags

      next(true) if start.deleted != e.deleted

      start_geos = T.unsafe(start.geos)
      end_geos = T.unsafe(e.geos)
      next(true) if start_geos.nil? || end_geos.nil?

      geom_clip_start = start_geos.intersection(clip_polygon)
      geom_clip_end = end_geos.intersection(clip_polygon)

      next(true) if !geom_clip_start.equals?(geom_clip_end)

      # No diff found, exclude this object
      data_start_index.delete([e.objtype, e.id])
      false
    }

    data_start = data_start_index.values
    [data_start, data_end]
  end

  sig {
    params(
      data_start: T::Array[OSMLogicalHistory::OSMObject],
      data_end: T::Array[OSMLogicalHistory::OSMObject],
      demi_distance: Float,
    ).returns(T::Array[[
      T::Hash[Integer, OSMLogicalHistory::OSMObject],
      T::Array[T::Hash[Symbol, T.untyped]]
    ]])
  }
  def self.cluster(data_start, data_end, demi_distance)
    # Remove objects without tags, unless they exist in the other side
    data_start_with_tags_ids = Set.new(data_start.select{ |e| !e.tags.empty? }.collect{ |e| [e.objtype, e.id] })
    data_end_with_tags_ids = Set.new(data_end.select{ |e| !e.tags.empty? }.collect{ |e| [e.objtype, e.id] })
    data_start = data_start.select{ |e| !e.tags.empty? || data_end_with_tags_ids.include?([e.objtype, e.id]) }
    data_end = data_end.select{ |e| !e.tags.empty? || data_start_with_tags_ids.include?([e.objtype, e.id]) }

    conf_group = Conflation[OSMLogicalHistory::OSMObject].new.conflate_cluster(data_start, data_end, demi_distance)

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
          conflation_reason: c.conflation_reason,
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
