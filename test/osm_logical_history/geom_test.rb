# frozen_string_literal: true
# typed: false

require 'sorbet-runtime'
require 'test/unit'
require_relative '../../lib/osm_logical_history/geom'


class TestGeom < Test::Unit::TestCase
  extend T::Sig

  Geom = OSMLogicalHistory::Geom

  def test_exact_or_buffered_sym_diff_over_union_exact
    geo_factory = RGeo::Geos.factory(srid: 4326)

    r_geom_b = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[0, 0], [0, 200]] }, geo_factory: geo_factory)
    r_geom_a = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[0, 0], [0, 100]] }, geo_factory: geo_factory)

    buffer_size = 20
    r_geom_b_buffer = r_geom_b.buffer(buffer_size)
    r_geom_a_buffer = r_geom_a.buffer(buffer_size)
    a_without_b = T.let(r_geom_a - r_geom_b_buffer, RGeo::Feature::Geometry)
    b_without_a = T.let(r_geom_b - r_geom_a_buffer, RGeo::Feature::Geometry)

    buffered, d = Geom.exact_or_buffered_sym_diff_over_union(r_geom_b, r_geom_a, b_without_a, a_without_b, r_geom_b_buffer, r_geom_a_buffer) { |geos| T.unsafe(geos).length }

    assert_equal(false, buffered)
    opp = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[0, 100], [0, 200]] }, geo_factory: geo_factory)
    assert_equal([0.0, opp.to_s, ''], d[1..1] + d[2..3].collect(&:to_s))
  end

  def test_exact_or_buffered_sym_diff_over_union_inexact
    geo_factory = RGeo::Geos.factory(srid: 4326)

    r_geom_b = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[0, 0], [0, 200]] }, geo_factory: geo_factory)
    r_geom_a = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[2, 0], [2, 100]] }, geo_factory: geo_factory)

    buffer_size = 20
    r_geom_b_buffer = r_geom_b.buffer(buffer_size)
    r_geom_a_buffer = r_geom_a.buffer(buffer_size)
    a_without_b = T.let(r_geom_a - r_geom_b_buffer, RGeo::Feature::Geometry)
    b_without_a = T.let(r_geom_b - r_geom_a_buffer, RGeo::Feature::Geometry)

    buffered, d = Geom.exact_or_buffered_sym_diff_over_union(r_geom_b, r_geom_a, b_without_a, a_without_b, r_geom_b_buffer, r_geom_a_buffer) { |geos| T.unsafe(geos).length }

    assert_equal(true, buffered)
    opp = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[0, 118], [0, 200]] }, geo_factory: geo_factory)
    assert_equal([18.110770276274835, opp.to_s, ''], d[1..1] + d[2..3].collect(&:to_s))
  end

  def test_exact_or_buffered_sym_diff_over_union_lower_dimension
    geo_factory = RGeo::Geos.factory(srid: 4326)

    r_geom_b = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[-100, 0], [100, 0]] }, geo_factory: geo_factory)
    r_geom_a = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[0, -100], [0, 100]] }, geo_factory: geo_factory)

    buffer_size = 20
    r_geom_b_buffer = r_geom_b.buffer(buffer_size)
    r_geom_a_buffer = r_geom_a.buffer(buffer_size)
    a_without_b = T.let(r_geom_a - r_geom_b_buffer, RGeo::Feature::Geometry)
    b_without_a = T.let(r_geom_b - r_geom_a_buffer, RGeo::Feature::Geometry)

    buffered, d = Geom.exact_or_buffered_sym_diff_over_union(r_geom_b, r_geom_a, b_without_a, a_without_b, r_geom_b_buffer, r_geom_a_buffer) { |geos| T.unsafe(geos).length }

    assert_equal(true, buffered)
    opp = RGeo::GeoJSON.decode({ 'type' => 'MultiLineString', 'coordinates' => [[[-100, 0], [-20, 0]], [[20, 0], [100, 0]]] }, geo_factory: geo_factory)
    odd = RGeo::GeoJSON.decode({ 'type' => 'MultiLineString', 'coordinates' => [[[0, -100], [0, -20]], [[0, 20], [0, 100]]] }, geo_factory: geo_factory)
    assert_equal([20.0, opp.to_s, odd.to_s], d[1..1] + d[2..3].collect(&:to_s))
  end

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

  def test_geom_add_inline_node
    geo_factory = RGeo::Geos.factory(srid: 4326)

    before = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[0, 0], [0, 200]] }, geo_factory: geo_factory)
    after = RGeo::GeoJSON.decode({ 'type' => 'LineString', 'coordinates' => [[0, 0], [10, 100], [0, 200]] }, geo_factory: geo_factory)
    d = Geom.geom_score(before, after, 0.0, 0.0, 20.0)

    assert_equal([0.5, 10.0, nil, nil, 'log euclidean distance + bias'], d)
  end
end
