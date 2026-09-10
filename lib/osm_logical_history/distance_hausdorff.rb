# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'rgeo/geo_json'

# Compute the discrete Hausdorff distance between vertices as an initial lower bound.
# For each segment, calculate an upper bound for the maximum possible distance.
# Ignore segments whose upper bound cannot improve the result by more than epsilon.
# Subdivide only promising segments and repeat.
# Stop when no segment can improve the result significantly or MAX_DEPTH is reached.
# Skip the computation entirely if either geometry has more than MAX_NODES nodes.

module DistanceHausdorff
  extend T::Sig

  EPSILON = 1.0
  MAX_NODES = 20
  MAX_DEPTH = 32

  Segment = T.type_alias {
    [RGeo::Feature::Point, RGeo::Feature::Point]
  }

  StackItem = T.type_alias {
    [RGeo::Feature::Point, RGeo::Feature::Point, Integer]
  }

  class GeometryData
    extend T::Sig

    sig { returns(T::Array[RGeo::Feature::Point]) }
    attr_reader :points

    sig { returns(T::Array[Segment]) }
    attr_reader :segments

    sig {
      params(
        points: T::Array[RGeo::Feature::Point],
        segments: T::Array[Segment],
      ).void
    }
    def initialize(points, segments)
      @points = points
      @segments = segments
    end
  end

  sig {
    params(
      geom1: RGeo::Feature::Geometry,
      geom2: RGeo::Feature::Geometry,
    ).returns(Float)
  }
  def self.distance(geom1, geom2)
    data1 = GeometryData.new(points(geom1), segments(geom1))
    data2 = GeometryData.new(points(geom2), segments(geom2))

    return 0.0 if data1.points.size > MAX_NODES || data2.points.size > MAX_NODES

    return 0.0 if data1.points.empty? || data2.points.empty?

    lower_bound = [
      directed_vertex_distance(data1.points, geom2),
      directed_vertex_distance(data2.points, geom1),
    ].max

    result1 = directed_distance(data1.segments, geom2, lower_bound)
    result2 = directed_distance(data2.segments, geom1, [lower_bound, result1].max)

    [result1, result2].max
  end

  sig {
    params(
      source: T::Array[RGeo::Feature::Point],
      target: RGeo::Feature::Geometry,
    ).returns(Float)
  }
  def self.directed_vertex_distance(source, target)
    max = 0.0
    source.each { |point|
      distance = T.let(point.distance(target), Float)
      max = distance if distance > max
    }
    max
  end

  sig {
    params(
      source: T::Array[Segment],
      target: RGeo::Feature::Geometry,
      current_max: Float,
    ).returns(Float)
  }
  def self.directed_distance(source, target, current_max)
    max = current_max
    stack = T::Array[StackItem].new

    source.each { |segment|
      a, b = segment
      next if T.unsafe(a).nil? || T.unsafe(b).nil?

      stack << [a, b, 0]
    }

    until stack.empty?
      item = T.must(stack.pop)
      a, b, depth = item

      da = T.let(a.distance(target), Float)
      db = T.let(b.distance(target), Float)

      max = da if da > max
      max = db if db > max

      length = T.let(a.distance(b), Float)

      upper_bound = (da + db + length) / 2.0

      next if upper_bound <= max + EPSILON
      next if depth >= MAX_DEPTH

      midpoint = T.let(a.factory.point((a.x + b.x) / 2.0, (a.y + b.y) / 2.0), RGeo::Feature::Point)
      dm = T.let(midpoint.distance(target), Float)

      max = dm if dm > max

      left_length = T.let(a.distance(midpoint), Float)
      right_length = T.let(midpoint.distance(b), Float)

      left_upper_bound = (da + dm + left_length) / 2.0
      right_upper_bound = (dm + db + right_length) / 2.0

      if left_upper_bound < right_upper_bound
        stack << [a, midpoint, depth + 1]
        stack << [midpoint, b, depth + 1]
      else
        stack << [midpoint, b, depth + 1]
        stack << [a, midpoint, depth + 1]
      end
    end

    max
  end

  sig {
    params(
      geom: RGeo::Feature::Geometry,
    ).returns(T::Array[RGeo::Feature::Point])
  }
  def self.points(geom)
    type_name = geom.geometry_type.type_name

    if type_name.start_with?('Multi') || type_name == 'GeometryCollection'
      T.unsafe(geom).collect { |sub_geom| points(sub_geom) }.flatten
    elsif type_name == 'Point'
      [T.cast(geom, RGeo::Feature::Point)]
    elsif %w[LineString LinearRing].include?(type_name)
      T.cast(geom, RGeo::Feature::LineString).points
    elsif type_name == 'Polygon'
      polygon = T.cast(geom, RGeo::Feature::Polygon)

      polygon.exterior_ring.points + polygon.interior_rings.collect(&:points).flatten
    else
      raise "Unsupported geometry type: #{type_name}"
    end
  end

  sig {
    params(
      geom: RGeo::Feature::Geometry,
    ).returns(T::Array[Segment])
  }
  def self.segments(geom)
    type_name = geom.geometry_type.type_name

    if type_name == 'Point'
      []
    elsif type_name.start_with?('Multi') || type_name == 'GeometryCollection'
      T.unsafe(geom).collect { |sub_geom| segments(sub_geom) }.flatten
    elsif %w[LineString LinearRing].include?(type_name)
      line = T.cast(geom, RGeo::Feature::LineString)
      line.points.each_cons(2).map { |a, b| [a, b] }
    elsif type_name == 'Polygon'
      polygon = T.cast(geom, RGeo::Feature::Polygon)
      ring_segments(polygon.exterior_ring) + polygon.interior_rings.collect { |ring| ring_segments(ring) }.flatten
    else
      raise "Unsupported geometry type: #{type_name}"
    end
  end

  sig {
    params(
      ring: RGeo::Feature::LineString,
    ).returns(T::Array[Segment])
  }
  def self.ring_segments(ring)
    ring.points.each_cons(2).map { |a, b| [a, b] }
  end
end
