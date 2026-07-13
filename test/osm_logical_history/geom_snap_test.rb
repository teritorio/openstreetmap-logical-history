# frozen_string_literal: true
# typed: false

require 'sorbet-runtime'
require 'test/unit'
require_relative '../../lib/osm_logical_history/geom_snap'

FACTORY = T.let(RGeo::Cartesian.factory, RGeo::Feature::Factory::Instance)

class LineStringSnapperTest < Test::Unit::TestCase
  extend T::Sig

  LineStringSnapper = OSMLogicalHistory::Geom::LineStringSnapper

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

# --- Tests for the modules extracted during the modularity refactor ---
# These exercise SegmentMath, SegmentIndex, NodeInserter, and SnapMatcher
# directly, independent of the LineStringSnapper orchestrator above.

class SegmentMathTest < Test::Unit::TestCase
  SegmentMath = OSMLogicalHistory::Geom::SegmentMath

  def test_closest_on_segment_projects_onto_interior
    point = FACTORY.point(5.0, 3.0)
    cp = SegmentMath.closest_on_segment(FACTORY, point, FACTORY.point(0.0, 0.0), FACTORY.point(10.0, 0.0))
    assert_in_delta 5.0, cp.x, 1e-9
    assert_in_delta 0.0, cp.y, 1e-9
  end

  def test_closest_on_segment_clamps_to_start_endpoint
    point = FACTORY.point(-5.0, 1.0)
    cp = SegmentMath.closest_on_segment(FACTORY, point, FACTORY.point(0.0, 0.0), FACTORY.point(10.0, 0.0))
    assert_in_delta 0.0, cp.x, 1e-9
    assert_in_delta 0.0, cp.y, 1e-9
  end

  def test_closest_on_segment_clamps_to_end_endpoint
    point = FACTORY.point(15.0, 1.0)
    cp = SegmentMath.closest_on_segment(FACTORY, point, FACTORY.point(0.0, 0.0), FACTORY.point(10.0, 0.0))
    assert_in_delta 10.0, cp.x, 1e-9
    assert_in_delta 0.0, cp.y, 1e-9
  end

  def test_closest_on_segment_zero_length_segment_returns_the_point
    snap1 = FACTORY.point(3.0, 4.0)
    cp = SegmentMath.closest_on_segment(FACTORY, FACTORY.point(0.0, 0.0), snap1, snap1)
    assert_equal snap1, cp
  end

  def test_segment_param_midpoint_is_one_half
    param = SegmentMath.segment_param(FACTORY.point(0.0, 0.0), FACTORY.point(10.0, 0.0), FACTORY.point(5.0, 0.0))
    assert_in_delta 0.5, param, 1e-9
  end

  def test_segment_param_zero_length_segment_returns_zero
    snap1 = FACTORY.point(3.0, 4.0)
    param = SegmentMath.segment_param(snap1, snap1, FACTORY.point(0.0, 0.0))
    assert_equal 0.0, param
  end

  def test_significant_vertex_true_for_endpoints
    pts = [FACTORY.point(0.0, 0.0), FACTORY.point(1.0, 0.0), FACTORY.point(2.0, 0.0)]
    assert_true SegmentMath.significant_vertex?(pts, 0)
    assert_true SegmentMath.significant_vertex?(pts, 2)
  end

  def test_significant_vertex_false_for_colinear_midpoint
    pts = [FACTORY.point(0.0, 0.0), FACTORY.point(1.0, 0.0), FACTORY.point(2.0, 0.0)]
    assert_false SegmentMath.significant_vertex?(pts, 1)
  end

  def test_significant_vertex_true_for_direction_change
    pts = [FACTORY.point(0.0, 0.0), FACTORY.point(1.0, 0.0), FACTORY.point(1.0, 1.0)]
    assert_true SegmentMath.significant_vertex?(pts, 1)
  end
end

class SegmentIndexTest < Test::Unit::TestCase
  SegmentIndex = OSMLogicalHistory::Geom::SegmentIndex

  def line_pts(coords)
    coords.map { |x, y| FACTORY.point(x, y) }
  end

  def test_candidate_segments_finds_nearby_segment
    pts = line_pts((0..10).map { |x| [x.to_f, 0.0] })
    index = SegmentIndex.build(pts, 0.05)
    candidates = index.candidate_segments(FACTORY.point(5.02, 0.0), 0.05)
    assert_include candidates, 5
  end

  def test_candidate_segments_empty_when_far_away
    pts = line_pts([[0.0, 0.0], [10.0, 0.0]])
    index = SegmentIndex.build(pts, 0.05)
    candidates = index.candidate_segments(FACTORY.point(100.0, 100.0), 0.05)
    assert_empty candidates
  end

  def test_candidate_segments_never_misses_the_matching_segment
    # Regression check for the grid traversal used to bucket each segment:
    # a long, roughly-diagonal segment must still register in the cell
    # nearest a point that sits right on it.
    pts = line_pts([[0.0, 0.0], [97.0, 101.0]])
    index = SegmentIndex.build(pts, 0.05)
    midpoint = FACTORY.point(48.5, 50.5)
    assert_include index.candidate_segments(midpoint, 0.05), 0
  end

  def test_cell_size_for_is_never_smaller_than_tolerance
    pts = line_pts([[0.0, 0.0], [100.0, 100.0]])
    assert_operator SegmentIndex.cell_size_for(pts, 1.0), :>=, 1.0
  end

  def test_cell_size_for_degenerate_single_point_falls_back_to_tolerance
    pts = line_pts([[0.0, 0.0]])
    assert_equal 0.05, SegmentIndex.cell_size_for(pts, 0.05)
  end
end

class NodeInserterTest < Test::Unit::TestCase
  NodeInserter = OSMLogicalHistory::Geom::NodeInserter

  def test_no_nodes_returns_original_points_unchanged
    pts = [FACTORY.point(0.0, 0.0), FACTORY.point(10.0, 0.0)]
    assert_equal pts, NodeInserter.call(pts, [])
  end

  def test_inserts_single_node_at_target_index
    pts = [FACTORY.point(0.0, 0.0), FACTORY.point(10.0, 0.0)]
    inserted = FACTORY.point(5.0, 0.0)
    result = NodeInserter.call(pts, [[1, inserted]])
    assert_equal [pts[0], inserted, pts[1]], result
  end

  def test_inserts_multiple_nodes_on_same_segment_in_positional_order
    pts = [FACTORY.point(0.0, 0.0), FACTORY.point(10.0, 0.0)]
    near = FACTORY.point(3.0, 0.0)
    far  = FACTORY.point(7.0, 0.0)
    # Passed out of order; NodeInserter must still order them by where they
    # fall along the segment.
    result = NodeInserter.call(pts, [[1, far], [1, near]])
    assert_equal [pts[0], near, far, pts[1]], result
  end

  def test_inserts_nodes_on_different_segments
    pts = [FACTORY.point(0.0, 0.0), FACTORY.point(10.0, 0.0), FACTORY.point(20.0, 0.0)]
    a = FACTORY.point(5.0, 0.0)
    b = FACTORY.point(15.0, 0.0)
    result = NodeInserter.call(pts, [[2, b], [1, a]])
    assert_equal [pts[0], a, pts[1], b, pts[2]], result
  end
end

class SnapMatcherTest < Test::Unit::TestCase
  SnapMatcher = OSMLogicalHistory::Geom::SnapMatcher

  def line_pts(coords)
    coords.map { |x, y| FACTORY.point(x, y) }
  end

  def test_snap_to_segments_reports_matched_segment_index
    target = line_pts([[0.0, 0.0], [10.0, 0.0]])
    src = line_pts([[5.0, 0.01]])
    result = SnapMatcher.snap_to_segments(FACTORY, src, target, 0.05)
    point, seg_i = result.first
    assert_equal 0, seg_i
    assert_in_delta 5.0, point.x, 1e-9
    assert_in_delta 0.0, point.y, 1e-9
  end

  def test_snap_to_segments_returns_nil_index_when_out_of_tolerance
    target = line_pts([[0.0, 0.0], [10.0, 0.0]])
    src = line_pts([[5.0, 5.0]])
    result = SnapMatcher.snap_to_segments(FACTORY, src, target, 0.05)
    point, seg_i = result.first
    assert_nil seg_i
    assert_equal src.first, point
  end

  def test_collect_nodes_from_snap_info_matches_generic_collect_nodes
    anchor = line_pts([[0.0, 0.0], [4.0, 0.0]])
    moving = line_pts([[2.0, 0.01], [2.0, 2.0]])

    snap_info = SnapMatcher.snap_to_segments(FACTORY, moving, anchor, 0.05)
    moving_snapped = snap_info.map(&:first)

    fast_nodes = SnapMatcher.collect_nodes_from_snap_info(anchor, snap_info, moving)
    generic_nodes = SnapMatcher.collect_nodes(anchor, moving_snapped, moving, 0.05)

    normalize = ->(nodes) { nodes.map { |i, p| [i, p.x.round(10), p.y.round(10)] }.sort }
    assert_equal normalize.call(generic_nodes), normalize.call(fast_nodes)
  end

  def test_collect_nodes_ignores_non_significant_vertices
    target = line_pts([[0.0, 0.0], [10.0, 0.0]])
    # Middle point is colinear (not significant), so it shouldn't produce a node.
    other = line_pts([[0.0, 0.0], [5.0, 0.0], [10.0, 0.0]])
    nodes = SnapMatcher.collect_nodes(target, other, other, 0.05)
    assert_empty nodes
  end
end
