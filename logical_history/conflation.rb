# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'levenshtein'
require 'set'
require 'rgeo'
require 'rgeo/geo_json'
require 'rgeo/proj4'
require 'rgl/implicit'
require 'rgl/connected_components'
require 'active_support/core_ext/enumerable'
require './logical_history/distance_hausdorff'
require './logical_history/refs'
require './logical_history/tags'
require './logical_history/geom'


module LogicalHistory
  class OSMObject < T::InexactStruct
    extend T::Sig

    const :objtype, String
    const :id, Integer
    const :geom, String
    prop :geos, T.nilable(RGeo::Feature::Geometry)
    const :geos_factory, T.proc.params(geom: String).returns(T.nilable(RGeo::Feature::Geometry))
    prop :geom_distance, T.nilable(T.any(Float, Integer))
    const :deleted, T::Boolean
    const :members, T.nilable(T::Array[Integer])
    const :version, Integer
    const :username, String
    const :created, String
    const :tags, T::Hash[String, String]

    @has_geos = T.let(false, T::Boolean)

    sig { returns(T.nilable(RGeo::Feature::Geometry)) }
    def geos
      if @geos.nil? && !@has_geos
        @has_geos = true
        @geos = geos_factory.call(geom)
      end

      @geos
    end

    sig { overridable.params(other: OSMObject).returns(T::Boolean) }
    def eql?(other)
      objtype == other.objtype && id == other.id && geom == other.geom
    end

    sig { overridable.returns(Integer) }
    def hash
      [objtype, id, geom].hash
    end

    sig {
      params(
      local_srid: Integer
    ).returns(
        T.proc.params(geom: String).returns(T.nilable(RGeo::Feature::Geometry))
      )
    }
    def self.build_geos_factory(local_srid)
      geo_factory = RGeo::Geos.factory(srid: 4326)
      projection = RGeo::Geos.factory(srid: local_srid)

      proc do |geom|
        decode = RGeo::GeoJSON.decode(geom, geo_factory: geo_factory)
        RGeo::Feature.cast(decode, project: true, factory: projection) if !decode.nil?
      rescue RGeo::Error::InvalidGeometry
        nil
      end
    end
  end

  module Conflation
    extend T::Sig

    class Conflation < T::InexactStruct
      prop :before, OSMObject
      prop :before_at_now, T.nilable(OSMObject)
      prop :after, OSMObject

      extend T::Sig

      sig { returns([OSMObject, T.nilable(OSMObject), OSMObject]) }
      def to_a
        [before, before_at_now, after]
      end

      sig { returns(T::Hash[String, T::Array[[String, T.nilable(String), T.untyped]]]) }
      def diff_attribs
        # Unchecked attribs
        # - version
        # - changeset
        # - uid
        # - username
        # - nodes
        # - lat
        # - lon
        # - members
        %i[deleted geom_distance].select{ |attrib|
          before.send(attrib) != after.send(attrib)
        }.to_h { |attrib|
          if attrib == :geom_distance
            ['geom', [['reject', nil, after.geom_distance.nil? ? nil : { dist: after.geom_distance }]]]
          else
            [attrib.to_s, [['reject', nil, nil]]]
          end
        }
      end

      sig { returns(T::Hash[String, T::Array[[String, T.nilable(String), NilClass]]]) }
      def diff_tags
        (before.tags.keys + after.tags.keys).uniq.select{ |key|
          before.tags[key] != after.tags[key]
        }.to_h{ |key|
          [key, [['reject', nil, nil]]]
        }
      end
    end

    Conflations = T.type_alias { T::Array[Conflation] }

    class ConflationNilableOnly < T::InexactStruct
      prop :before, T.nilable(OSMObject)
      prop :before_at_now, T.nilable(OSMObject)
      prop :after, T.nilable(OSMObject)

      extend T::Sig

      sig { returns(T::Array[T.nilable(OSMObject)]) }
      def to_a
        [before, before_at_now, after]
      end

      sig { returns(T::Hash[String, T::Array[[String, T.nilable(String), T.untyped]]]) }
      def diff_attribs
        # Unchecked attribs
        # - version
        # - changeset
        # - uid
        # - username
        # - nodes
        # - lat
        # - lon
        # - members
        %i[deleted geom_distance].select{ |attrib|
          before&.send(attrib) == after&.send(attrib)
        }.to_h { |attrib|
          if attrib == :geom_distance
            ['geom', [['reject', nil, after&.geom_distance.nil? ? nil : { dist: after&.geom_distance }]]]
          else
            [attrib.to_s, [['reject', nil, nil]]]
          end
        }
      end

      sig { returns(T::Hash[String, T::Array[[String, T.nilable(String), NilClass]]]) }
      def diff_tags
        ((before&.tags&.keys || []) + (after&.tags&.keys || [])).uniq.select{ |key|
          before&.tags&.[](key) == after&.tags&.[](key)
        }.to_h{ |key|
          [key, [['reject', nil, nil]]]
        }
      end
    end

    ConflationNilable = T.type_alias { T.any(Conflation, ConflationNilableOnly) }

    ConflationsNilable = T.type_alias { T::Array[ConflationNilable] }

    sig {
      params(
        befores: T::Set[OSMObject],
        afters: T::Set[OSMObject],
        afters_index: T::Hash[[String, Integer], OSMObject],
      ).returns([
        Conflations,
        T::Set[OSMObject],
        T::Set[OSMObject],
      ])
    }
    def self.conflate_by_refs(befores, afters, afters_index)
      befores_refs = befores.group_by{ |b| LogicalHistory::Refs.refs(b.tags) }
      befores_refs.delete({})
      befores_refs = befores_refs.select{ |_k, v| v.size == 1 }.transform_values{ |v| T.must(v.first) }
      afters_refs = afters.group_by{ |a| LogicalHistory::Refs.refs(a.tags) }
      afters_refs.delete({})
      afters_refs = afters_refs.select{ |_k, v| v.size == 1 }.transform_values{ |v| T.must(v.first) }

      uniq_befores_refs = befores_refs.keys
      uniq_afters_refs = afters_refs.keys

      conflate = (uniq_befores_refs & uniq_afters_refs).collect{ |ref|
        before = T.must(afters_refs[ref])
        after = T.must(befores_refs[ref])
        befores.delete(after)
        afters.delete(before)

        before_key = [T.must(befores_refs[ref]).objtype, T.must(befores_refs[ref]).id]
        Conflation.new(
          before: after,
          before_at_now: afters_index[before_key],
          after: before,
        )
      }

      [conflate, befores, afters]
    end

    sig {
      params(
        befores: T::Set[OSMObject],
        afters: T::Set[OSMObject],
        demi_distance: Float,
      ).returns(
        T::Hash[
          [OSMObject, OSMObject],
          [LogicalHistory::Tags::DistanceMeusure, LogicalHistory::Geom::DistanceMeusure, Float]
        ],
      )
    }
    def self.conflate_matrix(befores, afters, demi_distance)
      distance_matrix = T.let({}, T::Hash[
        [OSMObject, OSMObject],
        [LogicalHistory::Tags::DistanceMeusure, LogicalHistory::Geom::DistanceMeusure, Float]
      ])

      befores.each{ |b|
        next if T.unsafe(b.geos).nil?

        afters.each{ |a|
          next if a.geom.nil?

          t_dist = LogicalHistory::Tags.tags_distance(b.tags, a.tags)
          next if t_dist.nil?

          next if T.unsafe(a.geos).nil?

          g_dist = (
            if b.geos == a.geos || (b.geos&.dimension == 2 && a.geos&.dimension == 2 && befores.size == 1 && afters.size == 1)
              # Same geom
              # or
              # Geom distance does not matter on 1x1 matrix, fast return
              [0.0, nil, nil]
            else
              LogicalHistory::Geom.geom_distance(T.must(b.geos), T.must(a.geos), demi_distance)
            end
          )
          next if g_dist.nil?

          distance_matrix[[b, a]] = [
            t_dist,
            g_dist,
            (b.objtype == a.objtype && b.id == a.id ? 0.0 : 0.000001),
          ]
        }
      }

      distance_matrix
    end

    sig {
      params(
        key_min: [OSMObject, OSMObject],
        befores: T::Set[OSMObject],
        afters: T::Set[OSMObject],
        dist_geom: LogicalHistory::Geom::DistanceMeusure,
      ).returns(T::Array[[
        T::Enumerable[OSMObject],
        T::Enumerable[OSMObject]
      ]])
    }
    def self.remaining_parts(key_min, befores, afters, dist_geom)
      parts = T.let([], T::Array[[
        T::Enumerable[OSMObject],
        T::Enumerable[OSMObject]
      ]])

      remaning_before_geom = dist_geom[1]
      remaning_after_geom = dist_geom[2]
      remaning_before = T.let(nil, T.nilable(OSMObject))
      remaning_after = T.let(nil, T.nilable(OSMObject))
      if !T.unsafe(remaning_before_geom).nil?
        remaning_before = key_min[0].with(geos: remaning_before_geom)
        parts << [[remaning_before], afters]
      end
      if !T.unsafe(remaning_after_geom).nil?
        remaning_after = key_min[1].with(geos: remaning_after_geom)
        parts << [befores, [remaning_after]]
      end
      if !remaning_before.nil? && !remaning_after.nil?
        parts << [
          [remaning_before],
          [remaning_after]
        ]
      end

      parts
    end

    sig {
      params(
        befores: T::Set[OSMObject],
        afters: T::Set[OSMObject],
        afters_index: T::Hash[[String, Integer], OSMObject],
        demi_distance: Float,
      ).returns([
        Conflations,
        T::Set[OSMObject],
        T::Set[OSMObject],
      ])
    }
    def self.conflate_core(befores, afters, afters_index, demi_distance)
      distance_matrix = conflate_matrix(befores, afters, demi_distance)

      paired = T.let([], Conflations)
      until distance_matrix.empty?
        key_min, dist = T.must(distance_matrix.to_a.min_by{ |_keys, coefs| coefs[0][0] + coefs[1][0] + coefs[2] })
        match = Conflation.new(
          before: key_min[0],
          before_at_now: afters_index[[key_min[0].objtype, key_min[0].id]],
          after: key_min[1]
        )
        paired << match

        befores.delete(key_min[0])
        afters.delete(key_min[1])

        distance_matrix = distance_matrix.select{ |k, _v| k[0] != key_min[0] && k[1] != key_min[1] }

        # Add the remaining geom parts to the matrix
        new_befores = T.let(Set.new, T::Set[OSMObject])
        new_afters = T.let(Set.new, T::Set[OSMObject])
        remaining_parts(key_min, befores, afters, dist[1]).each{ |parts|
          new_befores = new_befores.merge(parts[0])
          new_afters = new_afters.merge(parts[1])
        }

        distance_matrix_nb_na = conflate_matrix(new_befores, new_afters, demi_distance)
        distance_matrix_nb_a = conflate_matrix(new_befores, afters, demi_distance)
        distance_matrix_b_na = conflate_matrix(befores, new_afters, demi_distance)
        distance_matrix = distance_matrix.merge(
          distance_matrix_nb_na,
          distance_matrix_nb_a,
          distance_matrix_b_na,
        )
        befores = befores.merge(new_befores)
        afters = afters.merge(new_afters)
      end

      [paired, befores, afters]
    end

    sig {
      params(
        paired: Conflations,
        befores: T::Set[OSMObject],
        afters: T::Set[OSMObject],
      ).returns([
        Conflations,
        T::Set[OSMObject],
        T::Set[OSMObject],
      ])
    }
    def self.conflate_uniq(paired, befores, afters)
      # Make conflation (before, after) uniq
      r = paired.group_by{ |p|
        [p.before.objtype, p.before.id, p.after.objtype, p.after.id]
      }.values.collect{ |group|
        # Merge geometry parts with same before and after objects
        T.must(group.reduce{ |sum, conflate|
          sum.before = sum.before.with(geos: T.must(sum.before.geos).union(conflate.before.geos))
          sum.after = sum.after.with(geos: T.must(sum.after.geos).union(conflate.after.geos))
          sum
        })
      }

      [r, befores, afters]
    end

    sig {
      params(
        paired: ConflationsNilable,
      ).returns(ConflationsNilable)
    }
    def self.conflate_merge_deleted_created(paired)
      # Conflate of same object, vN -> nil + nil -> vM => vN -> vM
      deleted = paired.select{ |p|
        p.after.nil?
      }.group_by{ |p|
        [p.before&.objtype, p.before&.id]
      }.select { |_key, group|
        group.size == 1
      }.transform_values{ |p| T.must(p.first) }

      created = paired.select{ |p|
        p.before.nil?
      }.group_by{ |p|
        [p.after&.objtype, p.after&.id]
      }.select { |_key, group|
        group.size == 1
      }.transform_values{ |p| T.must(p.first) }

      match = Set.new(deleted.keys & created.keys)

      merged = Set.new
      deleted_created = match.collect{ |key|
        merged << deleted[key]
        merged << created[key]
        T.must(deleted[key]).after = T.must(created[key]&.after)
        T.must(deleted[key])
      }

      paired = paired.select{ |p| !merged.include?(p) }

      paired + deleted_created
    end

    sig {
      params(
        paireds: Conflations,
        remeainings: T::Enumerable[OSMObject],
        key: Symbol,
        block: T.proc.params(c: Conflation).returns(OSMObject)
      ).returns([Conflations, T::Enumerable[OSMObject]])
    }
    def self.conflate_merge_remaning_parts_side(paireds, remeainings, key, &block)
      paired_index = paireds.group_by{ |p|
        o = block.call(p)
        [o.objtype, o.id]
      }.select { |_key, group| group.size == 1 }.transform_values(&:first)
      remeainings = remeainings.select { |b|
        paired = paired_index[[b.objtype, b.id]]
        if paired.nil?
          true
        else
          # Merge remaining geom with already conflated main part
          p = block.call(paired)
          union = p.with(geos: T.must(p.geos).union(b.geos))
          paired.send("#{key}=", union)
          false
        end
      }

      [paireds, remeainings]
    end

    sig {
      params(
        paired: Conflations,
        befores: T::Set[OSMObject],
        afters: T::Set[OSMObject],
      ).returns([
        Conflations,
        T::Enumerable[OSMObject],
        T::Enumerable[OSMObject],
      ])
    }
    def self.conflate_merge_remaning_parts(paired, befores, afters)
      paired, befores = conflate_merge_remaning_parts_side(paired, befores, :before, &:before)
      paired, afters = conflate_merge_remaning_parts_side(paired, afters, :after, &:after)

      [paired, befores, afters]
    end

    sig {
      params(
        befores: T::Enumerable[OSMObject],
        afters: T::Enumerable[OSMObject],
        demi_distance: Float,
      ).returns(ConflationsNilable)
    }
    def self.conflate(befores, afters, demi_distance)
      afters_index = afters.index_by{ |a| [a.objtype, a.id] }
      befores = befores.to_set
      afters = afters.select{ |a| !a.deleted }.to_set

      paired_by_refs, befores, afters = conflate_by_refs(befores, afters, afters_index)
      paired_by_distance, befores, afters = conflate_core(befores, afters, afters_index, demi_distance)

      paired_by_distance, befores, afters = conflate_uniq(paired_by_distance, befores, afters)
      paired_by_distance, befores, afters = conflate_merge_remaning_parts(paired_by_distance, befores, afters)

      (
        paired_by_refs +
        paired_by_distance +
        befores.collect{ |b| ConflationNilableOnly.new(before: b, before_at_now: afters_index[[b.objtype, b.id]]) } +
        afters.collect{ |a| ConflationNilableOnly.new(after: a) }
      ).collect{ |c|
        if !c.before.nil? && !c.after.nil?
          after = T.must(c.after)
          if after.geom_distance.nil?
            before = T.must(c.before)
            after.geom_distance = before.geos&.distance(after.geos)
            after.geom_distance = nil if after.geom_distance == 0
          end
        end
        c
      }
    end

    sig {
      params(
        befores: T::Enumerable[OSMObject],
        afters: T::Enumerable[OSMObject],
        demi_distance: Float,
      ).returns(ConflationsNilable)
    }
    def self.conflate_with_simplification(befores, afters, demi_distance)
      paired = conflate(befores, afters, demi_distance)
      conflate_merge_deleted_created(paired)
    end

    sig {
      params(
        befores: T::Enumerable[OSMObject],
        afters: T::Enumerable[OSMObject],
        demi_distance: Float,
      ).returns(T::Array[ConflationsNilable])
    }
    def self.conflate_cluster(befores, afters, demi_distance)
      links = conflate_with_simplification(befores, afters, demi_distance)

      vertices = T.let(Hash.new { |h, k| h[k] = [] }, T::Hash[[String, Integer], T::Array[ConflationNilable]])
      links.each{ |i|
        if !i.before.nil?
          vertices[[T.must(i.before).objtype, T.must(i.before).id]]
          vertices[[T.must(i.before).objtype, T.must(i.before).id]] << i
        end
        if !i.after.nil?
          vertices[[T.must(i.after).objtype, T.must(i.after).id]]
          vertices[[T.must(i.after).objtype, T.must(i.after).id]] << i
        end
      }

      graph = RGL::ImplicitGraph.new { |g|
        g.vertex_iterator { |b|
          vertices.keys.each(&b)
        }
        g.adjacent_iterator { |x, b|
          T.must(vertices[x]).each { |a|
            b.call([T.must(a.before).objtype, T.must(a.before).id]) if !a.before.nil?
            b.call([T.must(a.after).objtype, T.must(a.after).id]) if !a.after.nil?
          }
        }
        g.directed = false
      }

      links_components = []
      graph.each_connected_component{ |component_vertices|
        links_components << component_vertices.collect{ |vertex|
          vertices[vertex]
        }.flatten(1).uniq
      }

      links_components
    end
  end
end
