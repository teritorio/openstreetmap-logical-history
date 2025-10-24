# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'rgeo'
require 'rgeo/geo_json'
require 'rgeo/proj4'

module LogicalHistory
  class OSMObject < T::InexactStruct
    extend T::Sig

    const :objtype, String
    const :id, Integer
    const :geojson_geometry, String
    prop :geos, T.nilable(RGeo::Feature::Geometry)
    const :geos_factory, T.proc.params(geom: String).returns(T.nilable(RGeo::Feature::Geometry))
    const :deleted, T::Boolean
    const :members, T.nilable(T::Array[Integer])
    const :version, Integer
    const :username, T.nilable(String)
    const :created, String
    const :tags, T::Hash[String, String]

    prop :has_geos, T::Boolean, default: false

    sig { returns(T.nilable(RGeo::Feature::Geometry)) }
    def geos
      if T.unsafe(@geos).nil? && !@has_geos
        @has_geos = true
        @geos = geos_factory.call(geojson_geometry)
      end

      @geos
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
end
