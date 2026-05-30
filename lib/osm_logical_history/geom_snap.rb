# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'rgeo'

module OSMLogicalHistory
  module Geom
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

        moving_snapped = snap_to_segments(factory, moving_pts, anchor_pts, tolerance)

        anchor_result = factory.line_string(
          insert_nodes(anchor_pts, collect_nodes(factory, anchor_pts, moving_snapped, moving_pts, tolerance))
        )
        moving_result = factory.line_string(
          insert_nodes(moving_snapped, collect_nodes(factory, moving_snapped, anchor_pts, anchor_pts, tolerance))
        )

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

      sig {
        params(
          factory: T.untyped,
          point: RGeo::Feature::Point,
          snap1: RGeo::Feature::Point,
          snap2: RGeo::Feature::Point
        ).returns(RGeo::Feature::Point)
      }
      def self.closest_on_segment(factory, point, snap1, snap2)
        dx = snap2.x - snap1.x
        dy = snap2.y - snap1.y
        len2 = dx**2 + dy**2
        return snap1 if len2.zero?

        t = (((point.x - snap1.x) * dx) + ((point.y - snap1.y) * dy)) / len2
        factory.point(snap1.x + t.clamp(0.0, 1.0) * dx, snap1.y + t.clamp(0.0, 1.0) * dy)
      end

      sig {
        params(
          factory: T.untyped,
          src: T::Array[RGeo::Feature::Point],
          target: T::Array[RGeo::Feature::Point],
          tolerance: Float
        ).returns(T::Array[RGeo::Feature::Point])
      }
      def self.snap_to_segments(factory, src, target, tolerance)
        src.map { |point|
          nearest = target.each_cons(2).map { |snap1, snap2|
            closest_on_segment(factory, point, T.must(snap1), T.must(snap2))
          }.min_by { |cp| point.distance(cp) }
          T.must(point.distance(nearest) <= tolerance ? nearest : point)
        }
      end

      sig {
        params(
          factory: T.untyped,
          target: T::Array[RGeo::Feature::Point],
          other: T::Array[RGeo::Feature::Point],
          other_original: T::Array[RGeo::Feature::Point], tolerance: Float
        ).returns(T::Array[[Integer, RGeo::Feature::Point]])
      }
      def self.collect_nodes(factory, target, other, other_original, tolerance)
        other.each_with_index.flat_map { |point, idx|
          next [] unless significant_vertex?(other_original, idx)

          target.each_cons(2).with_index.filter_map { |(snap1, snap2), i|
            cp = closest_on_segment(factory, point, T.must(snap1), T.must(snap2))
            next unless point.distance(cp) <= tolerance
            next if cp.distance(snap1) <= 1e-10 || cp.distance(snap2) <= 1e-10

            [i + 1, point]
          }
        }.uniq { |_, p| p }
      end

      sig {
        params(
          pts: T::Array[RGeo::Feature::Point],
          idx: Integer
        ).returns(T::Boolean)
      }
      def self.significant_vertex?(pts, idx)
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

      sig {
        params(
          pts: T::Array[RGeo::Feature::Point],
          nodes: T::Array[[Integer, RGeo::Feature::Point]],
        ).returns(T::Array[RGeo::Feature::Point])
      }
      def self.insert_nodes(pts, nodes)
        nodes.sort_by { |i, point|
          [-i, -segment_param(T.must(pts[i - 1]), T.must(pts[i]), point)]
        }.reduce(pts.dup) { |acc, (i, point)|
          acc.insert(i, point)
        }
      end

      sig {
        params(
          snap: RGeo::Feature::Point,
          edg: RGeo::Feature::Point,
          point: RGeo::Feature::Point,
        ).returns(Float)
      }
      def self.segment_param(snap, edg, point)
        dx = edg.x - snap.x
        dy = edg.y - snap.y
        len2 = dx**2 + dy**2
        return 0.0 if len2.zero?

        (((point.x - snap.x) * dx) + ((point.y - snap.y) * dy)) / len2
      end
    end
  end
end
