# frozen_string_literal: true
# typed: false

require 'sorbet-runtime'
require 'test/unit'
require_relative '../../lib/osm_logical_history/geom_snap'


class LineStringSnapperTest < Test::Unit::TestCase
  extend T::Sig

  LineStringSnapper = OSMLogicalHistory::Geom::LineStringSnapper

  FACTORY = T.let(RGeo::Cartesian.factory, RGeo::Feature::Factory::Instance)
  TOLERANCE = T.let(0.05, Float)

  sig { params(coords: T::Array[[Float, Float]]).returns(RGeo::Feature::LineString) }
  def make_line(coords)
    points = coords.map { |x, y| FACTORY.point(x, y) }
    T.cast(FACTORY.line_string(points), RGeo::Feature::LineString)
  end

  sig { params(l_a: RGeo::Feature::LineString, l_b: RGeo::Feature::LineString, tol: Float).returns([RGeo::Feature::LineString, RGeo::Feature::LineString]) }
  def snap(l_a, l_b, tol = TOLERANCE)
    LineStringSnapper.snap(l_a, l_b, tol)
  end

  sig { params(a_result: RGeo::Feature::LineString, b_result: RGeo::Feature::LineString).void }
  def assert_shared_nodes(a_result, b_result)
    a_set = a_result.points.to_set{ |p| [p.x.round(10), p.y.round(10)] }
    b_set = b_result.points.to_set{ |p| [p.x.round(10), p.y.round(10)] }
    shared = a_set & b_set
    assert_false shared.empty?, "Expected shared nodes, got none.\nA: #{a_result}\nB: #{b_result}"
  end

  def test_vertex_snaps_to_nearby_vertex
    a = make_line([[0.0, 0.0], [1.0, 0.0]])
    b = make_line([[0.0, 0.01], [1.0, 0.01]])
    ra, rb = snap(a, b)
    assert_equal ra.points[0], rb.points[0]
    assert_equal ra.points[1], rb.points[1]
  end

  def test_no_snap_beyond_tolerance
    a = make_line([[0.0, 0.0], [1.0, 0.0]])
    b = make_line([[0.0, 1.0], [1.0, 1.0]])
    ra, rb = snap(a, b)
    assert_equal a, ra
    assert_equal b, rb
  end

  def test_vertex_snaps_onto_segment
    a = make_line([[0.0, 0.0], [2.0, 0.0], [4.0, 0.0]])
    b = make_line([[1.0, 0.01], [3.0, 0.01]])
    _ra, rb = snap(a, b)
    assert_equal FACTORY.point(1.0, 0.0), rb.points[0]
    assert_equal FACTORY.point(3.0, 0.0), rb.points[1]
  end

  def test_node_inserted_in_target_segment
    a = make_line([[0.0, 0.0], [4.0, 0.0]])
    b = make_line([[2.0, 0.01], [2.0, 2.0]])
    ra, _rb = snap(a, b)
    assert_include ra.points.map { |p| p.x.round(5) }, 2.0
  end

  def test_shared_nodes_are_identical
    a = make_line([[0.0, 0.0], [4.0, 0.0]])
    b = make_line([[2.0, 0.01], [2.0, 2.0]])
    ra, rb = snap(a, b)
    assert_shared_nodes ra, rb
  end

  def test_symmetric_result_regardless_of_input_order
    a = make_line([[0.0, 0.0], [4.0, 0.0]])
    b = make_line([[2.0, 0.01], [2.0, 2.0]])
    ra, rb   = snap(a, b)
    rb2, ra2 = snap(b, a)
    assert_equal(
      ra.points.map  { |p| [p.x.round(10), p.y.round(10)] },
      ra2.points.map { |p| [p.x.round(10), p.y.round(10)] }
    )
    assert_equal(
      rb.points.map  { |p| [p.x.round(10), p.y.round(10)] },
      rb2.points.map { |p| [p.x.round(10), p.y.round(10)] }
    )
  end

  def test_already_coincident_linestrings
    a = make_line([[0.0, 0.0], [1.0, 0.0], [2.0, 0.0]])
    b = make_line([[0.0, 0.0], [1.0, 0.0], [2.0, 0.0]])
    ra, rb = snap(a, b)
    assert_equal a, ra
    assert_equal b, rb
  end

  def test_single_segment_each
    a = make_line([[0.0, 0.0], [2.0, 0.0]])
    b = make_line([[1.0, 0.01], [1.0, 2.0]])
    ra, rb = snap(a, b)
    assert_shared_nodes ra, rb
  end

  def test_tolerance_zero_no_snap
    a = make_line([[0.0, 0.0], [1.0, 0.0]])
    b = make_line([[0.0, 0.01], [1.0, 0.01]])
    ra, rb = snap(a, b, 0.0)
    assert_equal a, ra
    assert_equal b, rb
  end

  def test_multiple_insertions_preserve_order
    a = make_line([[0.0, 0.0], [10.0, 0.0]])
    b = make_line([[2.0, 0.01], [5.0, 0.01], [8.0, 0.01]])
    ra, _rb = snap(a, b)
    x_coords = ra.points.map(&:x)
    assert_equal x_coords, x_coords.sort, "A nodes should remain in order: #{x_coords}"
  end
end
