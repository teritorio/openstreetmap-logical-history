# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'rgeo'
require_relative 'geom_snap'
require_relative 'distance_hausdorff'


module OSMLogicalHistory
  module Geom
    extend T::Sig

    DistanceMeusure = T.type_alias {
      [
        Float, # Meusure of difference
        Float, # Distance of Hausdorff
        T.nilable(RGeo::Feature::Geometry),
        T.nilable(RGeo::Feature::Geometry),
        String, # Reason
      ]
    }

    sig {
      params(
        diam: Float,
        x_min: Float,
        y_min: Float,
        x_max: Float,
        y_max: Float,
      ).returns(Float)
    }
    def self.buffer_size(diam, x_min, y_min, x_max, y_max)
      if diam < x_min
        y_min
      elsif diam > x_max
        y_max
      else
        # linerar interporlation
        (diam - x_min) * (y_max - y_min) / (x_max - x_min) + y_min
      end
    end

    sig {
      params(
        geom_a: RGeo::Feature::Geometry,
        geom_b: RGeo::Feature::Geometry,
        demi_distance: Float,
      ).returns(Float)
    }
    def self.log_distance(geom_a, geom_b, demi_distance)
      distance = geom_a.distance(geom_b)
      # 0.0 -> 0.0
      # demi_distance -> 0.5
      # infinite -> 1.0
      1.0 - 1.0 / (distance / demi_distance + 1.0)
    end

    sig {
      params(
        multilinestring: RGeo::Feature::Geometry
      ).returns(RGeo::Feature::Geometry)
    }
    def self.concat_multilinestring(multilinestring)
      if multilinestring.geometry_type.type_name == 'MultiLineString'
        multilinestring = T.cast(multilinestring, RGeo::Feature::MultiLineString)
        if multilinestring.num_geometries > 1
          multilinestring = multilinestring.factory.multi_line_string(multilinestring.each.reduce([]) { |acc, geom|
            if !acc.empty? && acc[-1].end_point.equals?(geom.start_point)
              acc[-1] = multilinestring.factory.line_string(acc[-1].points + geom.points[1..])
              acc
            else
              acc + [geom]
            end
          })
        end

        if multilinestring.num_geometries == 1
          multilinestring = multilinestring.geometry_n(0)
        end
      end

      multilinestring
    end

    sig {
      params(
        r_geom_a: RGeo::Feature::Geometry,
        r_geom_b: RGeo::Feature::Geometry,
        a_over_b: RGeo::Feature::Geometry,
        b_over_a: RGeo::Feature::Geometry,
        r_geom_a_buffer: RGeo::Feature::Geometry,
        r_geom_b_buffer: RGeo::Feature::Geometry,
        union: RGeo::Feature::Geometry,
        _block: T.proc.params(arg0: RGeo::Feature::Geometry).returns(Float),
      ).returns([T::Boolean, DistanceMeusure])
    }
    def self.exact_or_buffered_sym_diff_over_union(r_geom_a, r_geom_b, a_over_b, b_over_a, r_geom_a_buffer, r_geom_b_buffer, union, &_block)
      buffered_distance = (yield(a_over_b) + yield(b_over_a)) / yield(union) / 2

      distance_hausdorff = DistanceHausdorff.distance(
        r_geom_b_buffer.intersection(r_geom_a),
        r_geom_a_buffer.intersection(r_geom_b)
      )

      if r_geom_a.intersection(r_geom_b).dimension < r_geom_a.dimension
        # Excact distance give a lower dimension geom, use buffered distance
        return [true, [buffered_distance, distance_hausdorff, a_over_b.empty? ? nil : a_over_b, b_over_a.empty? ? nil : b_over_a, 'buffered intersection over union, distance to lower dimension']]
      end

      exact_a_over_b = r_geom_a - r_geom_b
      exact_b_over_a = r_geom_b - r_geom_a
      exact_distance = (yield(exact_a_over_b) + yield(exact_b_over_a)) / yield(union) / 2

      # Prefer exact distance if it's more than 60% of the buffered distance
      if exact_distance / buffered_distance > 0.6
        exact_a_over_b = concat_multilinestring(exact_a_over_b)
        exact_b_over_a = concat_multilinestring(exact_b_over_a)
        [false, [exact_distance, distance_hausdorff, exact_a_over_b.empty? ? nil : exact_a_over_b, exact_b_over_a.empty? ? nil : exact_b_over_a, 'exact intersection over union']]
      else
        [true, [buffered_distance, distance_hausdorff, a_over_b.empty? ? nil : a_over_b, b_over_a.empty? ? nil : b_over_a, 'buffered intersection over union, distance intersection']]
      end
    end

    sig {
      params(
        r_geom_a: RGeo::Feature::Geometry,
        r_geom_b: RGeo::Feature::Geometry,
        diameter_a: Float,
        diameter_b: Float,
        demi_distance: Float,
      ).returns(T.nilable(DistanceMeusure))
    }
    def self.geom_score(r_geom_a, r_geom_b, diameter_a, diameter_b, demi_distance)
      return [0.0, 0.0, nil, nil, 'same'] if r_geom_a.equals?(r_geom_b)

      if r_geom_a.dimension == 0 && r_geom_b.dimension == 0
        # Point never intersects, unless they are the same
        d = log_distance(r_geom_a, r_geom_b, demi_distance)
        return d <= 0.5 ? [d * 2, r_geom_a.distance(r_geom_b), nil, nil, 'point distance'] : nil
      end

      if r_geom_a.geometry_type == RGeo::Feature::LineString && r_geom_b.geometry_type == RGeo::Feature::LineString
        distance = r_geom_a.distance(r_geom_b)
        snap_distance = 1.0 # m
        if distance <= snap_distance
          # Snap lines to each other to avoid small misalignement
          r_geom_a, r_geom_b = LineStringSnapper.snap(
            T.cast(r_geom_a, RGeo::Feature::LineString),
            T.cast(r_geom_b, RGeo::Feature::LineString),
            snap_distance
          )
        end
      end

      intersection = r_geom_a.intersection(r_geom_b)

      # Ensure inner intersection (crossing) not just touching
      if !intersection.empty? && intersection.dimension == r_geom_a.dimension && intersection.dimension == r_geom_b.dimension
        # Compute: 1 - intersection / union
        # Compute buffered symetrical difference
        buffer_size_b = buffer_size(diameter_b, 3.0, 3.0, 40.0, 20.0)
        buffer_size_a = buffer_size(diameter_a, 3.0, 3.0, 40.0, 20.0)
        r_geom_b_buffer = r_geom_b.buffer(buffer_size_b)
        r_geom_a_buffer = r_geom_a.buffer(buffer_size_a)
        a_over_b = T.let(r_geom_a - r_geom_b_buffer, RGeo::Feature::Geometry)
        b_over_a = T.let(r_geom_b - r_geom_a_buffer, RGeo::Feature::Geometry)

        if a_over_b.empty? && b_over_a.empty?
          # Equality
          distance_hausdorff = DistanceHausdorff.distance(r_geom_a, r_geom_b)
          [0.0, distance_hausdorff, nil, nil, 'symetrical buffered inclusion']
        elsif a_over_b.empty? || b_over_a.empty?
          # One subpart of the other
          union = r_geom_a.union(r_geom_b)
          buffered, parts = exact_or_buffered_sym_diff_over_union(r_geom_a, r_geom_b, a_over_b, b_over_a, r_geom_a_buffer, r_geom_b_buffer, union) { |geos|
            intersection.dimension == 1 ? T.unsafe(geos).length : T.unsafe(geos).area
          }
          [0.0, parts[1], parts[2], parts[3], buffered ? 'buffered subpart' : 'exact subpart']
        else
          dim_a = a_over_b.dimension
          dim_b = b_over_a.dimension
          union = r_geom_a.union(r_geom_b)
          dim_union = union.dimension
          if dim_a == 0 && dim_b == 0 && dim_union == 0
            # Points
            raise 'Non equal intersecting points, should never happen.'
          elsif dim_a == 1 && dim_b == 1 && dim_union == 1
            # Lines
            _buffered, dm = exact_or_buffered_sym_diff_over_union(r_geom_a, r_geom_b, a_over_b, b_over_a, r_geom_a_buffer, r_geom_b_buffer, union) { |geos| T.unsafe(geos).length }
            dm
          elsif dim_a == 2 && dim_b == 2 && dim_union == 2
            _buffered, dm = exact_or_buffered_sym_diff_over_union(r_geom_a, r_geom_b, a_over_b, b_over_a, r_geom_a_buffer, r_geom_b_buffer, union) { |geos| T.unsafe(geos).area }
            dm
          else
            raise 'Diff dimension geom should not happen.'
          end
        end
      else
        # Else, use real distance + bias because no intersection
        d = log_distance(r_geom_a, r_geom_b, demi_distance)
        return nil if d > 0.5

        d = 0.5 + d
        distance_hausdorff = DistanceHausdorff.distance(r_geom_a, r_geom_b)
        [d, distance_hausdorff, nil, nil, 'log euclidean distance + bias']
      end
    rescue RGeo::Error::InvalidGeometry
      nil
    end
  end
end
