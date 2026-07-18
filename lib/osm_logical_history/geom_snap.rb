# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'rgeo'
require 'set'

module OSMLogicalHistory
  module Geom
    module SegmentMath
      class << self
        extend T::Sig

        sig {
          params(
            factory: T.untyped,
            point: RGeo::Feature::Point,
            snap1: RGeo::Feature::Point,
            snap2: RGeo::Feature::Point
          ).returns(RGeo::Feature::Point)
        }
        def closest_on_segment(factory, point, snap1, snap2)
          t, = closest_projection(point, snap1, snap2)
          factory.point(snap1.x + (t * (snap2.x - snap1.x)), snap1.y + (t * (snap2.y - snap1.y)))
        end

        sig {
          params(
            point: RGeo::Feature::Point,
            snap1: RGeo::Feature::Point,
            snap2: RGeo::Feature::Point
          ).returns([Float, Float, Float])
        }
        def closest_projection(point, snap1, snap2)
          dx = snap2.x - snap1.x
          dy = snap2.y - snap1.y
          len2 = (dx**2) + (dy**2)

          t = len2.zero? ? 0.0 : ((((point.x - snap1.x) * dx) + ((point.y - snap1.y) * dy)) / len2).clamp(0.0, 1.0)
          cx = snap1.x + (t * dx)
          cy = snap1.y + (t * dy)
          d2 = ((point.x - cx)**2) + ((point.y - cy)**2)

          [t, d2, len2]
        end

        sig {
          params(
            snap: RGeo::Feature::Point,
            edg: RGeo::Feature::Point,
            point: RGeo::Feature::Point,
          ).returns(Float)
        }
        def segment_param(snap, edg, point)
          dx = edg.x - snap.x
          dy = edg.y - snap.y
          len2 = dx**2 + dy**2
          return 0.0 if len2.zero?

          (((point.x - snap.x) * dx) + ((point.y - snap.y) * dy)) / len2
        end

        sig {
          params(
            pts: T::Array[RGeo::Feature::Point],
            idx: Integer
          ).returns(T::Boolean)
        }
        def significant_vertex?(pts, idx)
          return true if idx <= 0 || idx >= pts.length - 1

          p0 = T.must(pts[idx - 1])
          p1 = T.must(pts[idx])
          p2 = T.must(pts[idx + 1])
          vx1 = p1.x - p0.x
          vy1 = p1.y - p0.y
          vx2 = p2.x - p1.x
          vy2 = p2.y - p1.y
          (vx1 * vy2 - vy1 * vx2).abs > 1e-12
        end
      end
    end

    class SegmentIndex
      extend T::Sig

      sig {
        params(
          pts: T::Array[RGeo::Feature::Point],
          tolerance: Float
        ).returns(Float)
      }
      def self.cell_size_for(pts, tolerance)
        floor = [tolerance, 1e-9].max
        return floor if pts.length < 2

        xs = T.let(pts.map(&:x), T::Array[Float])
        ys = T.let(pts.map(&:y), T::Array[Float])
        width = T.must(xs.max) - T.must(xs.min)
        height = T.must(ys.max) - T.must(ys.min)
        diag = Math.sqrt((width**2) + (height**2))
        return floor if diag.zero?

        [diag / Math.sqrt(pts.length), floor].max
      end

      sig {
        params(
          pts: T::Array[RGeo::Feature::Point],
          tolerance: Float
        ).returns(SegmentIndex)
      }
      def self.build(pts, tolerance)
        new(pts, cell_size_for(pts, tolerance))
      end

      sig { params(pts: T::Array[RGeo::Feature::Point], cell_size: Float).void }
      def initialize(pts, cell_size)
        @cell_size = T.let(cell_size, Float)
        @buckets = T.let({}, T::Hash[[Integer, Integer], T::Array[Integer]])

        pts.each_cons(2).with_index do |(p1, p2), i|
          cells_for_segment(T.must(p1), T.must(p2)).each do |cell|
            (@buckets[cell] ||= []) << i
          end
        end
      end

      sig {
        params(
          point: RGeo::Feature::Point,
          tolerance: Float
        ).returns(T::Array[Integer])
      }
      def candidate_segments(point, tolerance)
        radius = (tolerance / @cell_size).ceil + 1
        cx, cy = cell_for(point.x, point.y)
        result = T.let(Set.new, T::Set[Integer])

        (-radius..radius).each do |dx|
          (-radius..radius).each do |dy|
            bucket = @buckets[[cx + dx, cy + dy]]
            result.merge(bucket) if bucket
          end
        end

        result.to_a
      end

      private

      sig {
        params(
          p_x: Float,
          p_y: Float
        ).returns([Integer, Integer])
      }
      def cell_for(p_x, p_y)
        [(p_x / @cell_size).floor, (p_y / @cell_size).floor]
      end

      sig {
        params(
          pp1: RGeo::Feature::Point,
          pp2: RGeo::Feature::Point
        ).returns(T::Array[[Integer, Integer]])
      }
      def cells_for_segment(pp1, pp2)
        x0, y0 = cell_for(pp1.x, pp1.y)
        x1, y1 = cell_for(pp2.x, pp2.y)

        nx = (x1 - x0).abs
        ny = (y1 - y0).abs
        sign_x = x1 >= x0 ? 1 : -1
        sign_y = y1 >= y0 ? 1 : -1

        cells = T.let([[x0, y0]], T::Array[[Integer, Integer]])
        x = x0
        y = y0
        ix = 0
        iy = 0

        while ix < nx || iy < ny
          lhs = (1 + (2 * ix)) * ny
          rhs = (1 + (2 * iy)) * nx

          if lhs < rhs
            x += sign_x
            ix += 1
          elsif lhs > rhs
            y += sign_y
            iy += 1
          else
            x += sign_x
            y += sign_y
            ix += 1
            iy += 1
          end

          cells << [x, y]
        end

        cells
      end
    end

    class NodeInserter
      extend T::Sig

      sig {
        params(
          pts: T::Array[RGeo::Feature::Point],
          nodes: T::Array[[Integer, RGeo::Feature::Point]],
        ).returns(T::Array[RGeo::Feature::Point])
      }
      def self.call(pts, nodes)
        groups = T.let(
          Hash.new { |h, k| h[k] = [] },
          T::Hash[Integer, T::Array[RGeo::Feature::Point]]
        )
        nodes.each { |i, point| T.must(groups[i]) << point }

        result = T.let([], T::Array[RGeo::Feature::Point])

        pts.each_with_index do |point, idx|
          if idx.positive? && groups.key?(idx)
            prev = T.must(pts[idx - 1])
            sorted = T.must(groups[idx]).sort_by { |p| SegmentMath.segment_param(prev, point, p) }
            result.concat(sorted)
          end

          result << point
        end

        result
      end
    end

    class SnapMatcher
      extend T::Sig

      sig {
        params(
          factory: T.untyped,
          src: T::Array[RGeo::Feature::Point],
          target: T::Array[RGeo::Feature::Point],
          tolerance: Float
        ).returns(T::Array[[RGeo::Feature::Point, T.nilable(Integer)]])
      }
      def self.snap_to_segments(factory, src, target, tolerance)
        tol2 = tolerance**2
        max_i = target.length - 2
        lazy_index = SegmentIndex.build(target, tolerance)
        vertex_lookup = target_vertex_lookup(target)

        src.each_with_index.map { |point, src_idx|
          next [point, nil] if max_i.negative?

          exact_i = vertex_lookup[[point.x, point.y]]
          if exact_i
            next [T.must(target[exact_i]), exact_i.clamp(0, max_i)]
          end

          local_candidates = [src_idx - 1, src_idx].map { |i| i.clamp(0, max_i) }.uniq
          match = best_match(factory, point, target, local_candidates, tol2)
          next match if match

          best_match(factory, point, target, lazy_index.candidate_segments(point, tolerance), tol2) || [point, nil]
        }
      end

      sig {
        params(
          target: T::Array[RGeo::Feature::Point]
        ).returns(T::Hash[[Float, Float], Integer])
      }
      def self.target_vertex_lookup(target)
        lookup = T.let({}, T::Hash[[Float, Float], Integer])
        target.each_with_index { |p, i| lookup[[p.x, p.y]] = i }
        lookup
      end

      sig {
        params(
          factory: T.untyped,
          point: RGeo::Feature::Point,
          target: T::Array[RGeo::Feature::Point],
          candidate_indices: T::Array[Integer],
          tol2: Float
        ).returns(T.nilable([RGeo::Feature::Point, Integer]))
      }
      def self.best_match(factory, point, target, candidate_indices, tol2)
        return nil if candidate_indices.empty?

        best_i, best_t, best_d2 = candidate_indices.map { |i|
          snap1 = T.must(target[i])
          snap2 = T.must(target[i + 1])
          t, d2, = SegmentMath.closest_projection(point, snap1, snap2)
          [i, t, d2]
        }.min_by { |_, _, d2| d2 }
        return nil if best_i.nil? || best_t.nil? || best_d2.nil?

        return nil if best_d2 > tol2

        snap1 = T.must(target[best_i])
        snap2 = T.must(target[best_i + 1])
        nearest = factory.point(
          snap1.x + (best_t * (snap2.x - snap1.x)),
          snap1.y + (best_t * (snap2.y - snap1.y))
        )
        [nearest, best_i]
      end

      sig {
        params(
          target: T::Array[RGeo::Feature::Point],
          other: T::Array[RGeo::Feature::Point],
          other_original: T::Array[RGeo::Feature::Point], tolerance: Float,
        ).returns(T::Array[[Integer, RGeo::Feature::Point]])
      }
      def self.collect_nodes(target, other, other_original, tolerance)
        max_i = target.length - 2
        return [] if max_i.negative?

        tol2 = tolerance**2
        eps2 = 1.0e-20 # squared version of the original 1e-10 endpoint threshold
        vertex_lookup = target_vertex_lookup(target)
        lazy_index = SegmentIndex.build(target, tolerance)

        other.each_with_index.flat_map { |point, idx|
          next [] unless SegmentMath.significant_vertex?(other_original, idx)
          next [] if vertex_lookup.key?([point.x, point.y])

          local_candidates = [idx - 1, idx].map { |i| i.clamp(0, max_i) }.uniq
          nodes = nodes_from_candidates(target, point, local_candidates, tol2, eps2)
          next nodes unless nodes.empty?

          nodes_from_candidates(target, point, lazy_index.candidate_segments(point, tolerance), tol2, eps2)
        }.uniq { |_, p| p }
      end

      sig {
        params(
          target: T::Array[RGeo::Feature::Point],
          point: RGeo::Feature::Point,
          candidate_indices: T::Array[Integer],
          tol2: Float,
          eps2: Float
        ).returns(T::Array[[Integer, RGeo::Feature::Point]])
      }
      def self.nodes_from_candidates(target, point, candidate_indices, tol2, eps2)
        candidate_indices.filter_map { |i|
          snap1 = T.must(target[i])
          snap2 = T.must(target[i + 1])
          t, d2, len2 = SegmentMath.closest_projection(point, snap1, snap2)
          next unless d2 <= tol2
          next if ((t**2) * len2 <= eps2) || (((1 - t)**2) * len2 <= eps2)

          [i + 1, point]
        }
      end

      sig {
        params(
          target: T::Array[RGeo::Feature::Point],
          snap_info: T::Array[[RGeo::Feature::Point, T.nilable(Integer)]],
          other_original: T::Array[RGeo::Feature::Point]
        ).returns(T::Array[[Integer, RGeo::Feature::Point]])
      }
      def self.collect_nodes_from_snap_info(target, snap_info, other_original)
        snap_info.each_with_index.filter_map { |(point, seg_i), idx|
          next nil unless seg_i
          next nil unless SegmentMath.significant_vertex?(other_original, idx)

          snap1 = T.must(target[seg_i])
          snap2 = T.must(target[seg_i + 1])
          next nil if point.distance(snap1) <= 1e-10 || point.distance(snap2) <= 1e-10

          [seg_i + 1, point]
        }.uniq { |_, p| p }
      end
    end

    class LineStringSnapper
      extend T::Sig

      sig {
        params(
          l_a: RGeo::Feature::LineString,
          l_b: RGeo::Feature::LineString,
          tolerance: Float
        ).returns([
          RGeo::Feature::LineString,
          RGeo::Feature::LineString
      ])
      }
      def self.snap(l_a, l_b, tolerance)
        factory = l_a.factory
        a_pts = l_a.points.to_a
        b_pts = l_b.points.to_a

        anchor_is_a = canonical_key(a_pts) <= canonical_key(b_pts)
        anchor_pts, moving_pts = anchor_is_a ? [a_pts, b_pts] : [b_pts, a_pts]

        moving_snap_info = SnapMatcher.snap_to_segments(factory, moving_pts, anchor_pts, tolerance)
        moving_snapped = moving_snap_info.map(&:first)

        anchor_nodes = SnapMatcher.collect_nodes_from_snap_info(anchor_pts, moving_snap_info, moving_pts)
        anchor_result = factory.line_string(NodeInserter.call(anchor_pts, anchor_nodes))

        moving_nodes = SnapMatcher.collect_nodes(moving_snapped, anchor_pts, anchor_pts, tolerance)
        moving_result = factory.line_string(NodeInserter.call(moving_snapped, moving_nodes))

        anchor_is_a ? [anchor_result, moving_result] : [moving_result, anchor_result]
      end

      sig {
        params(
          pts: T::Array[RGeo::Feature::Point]
        ).returns(String)
      }
      def self.canonical_key(pts)
        coords = pts.map { |p| [p.x, p.y] }
        [coords, coords.reverse].min.map { |x, y| "#{x},#{y}" }.join('|')
      end
    end
  end
end
