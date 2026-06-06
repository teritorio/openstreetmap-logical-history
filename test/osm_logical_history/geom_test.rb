# frozen_string_literal: true
# typed: false

require 'sorbet-runtime'
require 'test/unit'
require_relative '../../lib/osm_logical_history/geom'


class TestGeom < Test::Unit::TestCase
  extend T::Sig

  Geom = OSMLogicalHistory::Geom

  sig { void }
  def test_concat_multilinestring_connected
    geo_factory = RGeo::Geos.factory(srid: 4326)
    geo_src = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[[1, 0], [2, 0]]] }, geo_factory: geo_factory)
    assert_equal(geo_src, Geom.concat_multilinestring(geo_src))

    geo_src = RGeo::GeoJSON.decode({ 'type' => 'MultiLineString', 'coordinates' => [
      [[2, 0], [3, 0]],
      [[1, 0], [2, 0]],
    ] }, geo_factory: geo_factory)
    assert_equal(geo_src, Geom.concat_multilinestring(geo_src))

    geo_src = RGeo::GeoJSON.decode({ 'type' => 'MultiLineString', 'coordinates' => [
      [[1, 0], [2, 0]],
      [[2, 0], [3, 0]],
    ] }, geo_factory: geo_factory)
    geo_target = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[1, 0], [2, 0], [3, 0]] }, geo_factory: geo_factory)
    assert_equal(geo_target, Geom.concat_multilinestring(geo_src))
  end

  sig { void }
  def test_geom_score
    srid = 2154
    demi_distance = 200.0 # m

    geo_factory = RGeo::Geos.factory(srid: 4326)
    projection = RGeo::Geos.factory(srid: srid)

    before = RGeo::Feature.cast(
      RGeo::GeoJSON.decode({ 'type' => 'Point', 'coordinates' => [-1.4865344, 43.5357032] }, geo_factory: geo_factory),
      project: true,
      factory: projection,
    )
    after = RGeo::Feature.cast(
      RGeo::GeoJSON.decode({ 'type' => 'Point', 'coordinates' => [-1.4864637, 43.5359501] }, geo_factory: geo_factory),
      project: true,
      factory: projection,
    )
    d = Geom.geom_score(before, after, 0.0, 0.0, demi_distance)

    assert(T.must(d&.first) < 0.5)
    assert(T.must(d&.first) > 0.0)
  end
end
