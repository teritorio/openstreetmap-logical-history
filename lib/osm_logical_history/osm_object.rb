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
        username: T.nilable(String),
        created: String,
        tags: T::Hash[String, String]
      ).void
    }
    def initialize(objtype:, id:, geojson_geometry:, geos_factory:, deleted:, members:, version:, username:, created:, tags:)
      @objtype = objtype
      @id = id
      @geojson_geometry = geojson_geometry
      @geos_factory = geos_factory
      @deleted = deleted
      @members = members
      @version = version
      @username = username
      @created = created
      @tags = tags

      @geos_internal = T.let(nil, T.nilable(RGeo::Feature::Geometry))
      @has_geos = T.let(false, T::Boolean)
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

    sig { overridable.params(other: OSMObject).returns(T::Boolean) }
    def eql?(other)
      objtype == other.objtype && id == other.id && version == other.version && geojson_geometry == other.geojson_geometry
    end
    alias == eql?

    sig { overridable.returns(Integer) }
    def hash
      [objtype, id, version, geojson_geometry].hash
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
