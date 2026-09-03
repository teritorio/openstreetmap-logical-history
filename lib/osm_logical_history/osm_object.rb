# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'rgeo'
require 'rgeo/geo_json'
require 'rgeo/proj4'

module OSMLogicalHistory
  extend T::Sig

  class OSMObject
    extend T::Sig

    include Comparable

    sig { returns(String) }
    attr_reader :objtype

    sig { returns(Integer) }
    attr_reader :id

    sig { returns(T.nilable(String)) }
    attr_reader :geojson_geometry

    sig { returns(T.proc.params(geom: String).returns(T.nilable(RGeo::Feature::Geometry))) }
    attr_reader :geos_factory

    sig { returns(T::Boolean) }
    attr_reader :deleted

    sig { returns(T.nilable(T::Array[Integer])) }
    attr_reader :members

    sig { returns(Integer) }
    attr_reader :version

    sig { returns(T.nilable(Integer)) }
    attr_reader :uid

    sig { returns(T.nilable(String)) }
    attr_reader :username

    sig { returns(String) }
    attr_reader :created

    sig { returns(T::Hash[String, String]) }
    attr_accessor :tags

    sig {
      params(
        objtype: String,
        id: Integer,
        geojson_geometry: T.nilable(String),
        geos_factory: T.proc.params(geom: String).returns(T.nilable(RGeo::Feature::Geometry)),
        deleted: T::Boolean,
        members: T.nilable(T::Array[Integer]),
        version: Integer,
        uid: T.nilable(Integer),
        username: T.nilable(String),
        created: String,
        tags: T::Hash[String, String]
      ).void
    }
    def initialize(objtype:, id:, geojson_geometry:, geos_factory:, deleted:, members:, version:, uid:, username:, created:, tags:)
      @objtype = objtype
      @id = id
      @geojson_geometry = geojson_geometry
      @geos_factory = geos_factory
      @deleted = deleted
      @members = members
      @version = version
      @uid = uid
      @username = username
      @created = created
      @tags = tags

      @geos_internal = T.let(nil, T.nilable(RGeo::Feature::Geometry))
      @has_geos = T.let(false, T::Boolean)

      @diameter = T.let(nil, T.nilable(Float))
      @has_diameter = T.let(false, T::Boolean)
    end

    sig { returns(T.nilable(RGeo::Feature::Geometry)) }
    def geos
      geojson_geometry_ = geojson_geometry
      return if geojson_geometry_.nil?

      if T.unsafe(@geos_internal).nil? && !@has_geos
        @has_geos = true
        @geos_internal = geos_factory.call(geojson_geometry_)
      end

      @geos_internal
    end

    sig { params(value: T.nilable(RGeo::Feature::Geometry)).returns(T.nilable(RGeo::Feature::Geometry)) }
    def geos=(value)
      @has_geos = true
      @geos_internal = value
    end

    sig { returns(T.nilable(Float)) }
    def diameter
      if @has_diameter
        @diameter
      else
        @has_diameter = true
        g = T.unsafe(geos)
        return @diameter = nil if g.nil?
        return @diameter = 0.0 if g.empty? || g.dimension == 0

        ring = g.envelope.exterior_ring
        @diameter = ring.point_n(0).distance(ring.point_n(2))
      end
    end

    sig {
      params(
        geom: RGeo::Feature::Geometry,
      ).returns(Float)
    }
    def self.geom_diameter(geom)
      return 0.0 if geom.empty? || geom.dimension == 0

      ring = geom.envelope.exterior_ring
      ring.point_n(0).distance(ring.point_n(2))
    end


    sig { overridable.params(other: OSMObject).returns(T::Boolean) }
    def eql?(other)
      objtype == other.objtype && id == other.id && version == other.version && geojson_geometry == other.geojson_geometry && geos == other.geos
    end
    alias == eql?

    sig { overridable.returns(Integer) }
    def hash
      [objtype, id, version, geojson_geometry, geos].hash
    end

    sig { overridable.params(other: OSMObject).returns(Integer) }
    def <=>(other)
      [objtype, id, version, geojson_geometry, object_id] <=> [other.objtype, other.id, other.version, other.geojson_geometry, object_id]
    end
  end

  sig {
    params(
    local_srid: Integer
  ).returns(
      T.proc.params(geojson_geometry: String).returns(T.nilable(RGeo::Feature::Geometry))
    )
  }
  def self.build_geos_factory(local_srid)
    geo_factory = RGeo::Geos.factory(srid: 4326)
    projection = RGeo::Geos.factory(srid: local_srid)

    proc do |geojson_geometry|
      decode = RGeo::GeoJSON.decode(geojson_geometry, geo_factory: geo_factory)
      RGeo::Feature.cast(decode, project: true, factory: projection) if !decode.nil?
    rescue RGeo::Error::InvalidGeometry
      nil
    end
  end
end
