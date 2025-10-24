# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'set'
require 'rgl/implicit'
require 'rgl/connected_components'
require 'active_support/core_ext/enumerable'
require_relative 'distance_hausdorff'
require_relative 'refs'
require_relative 'tags'
require_relative 'geom'
require_relative 'osm_object'


module OSMLogicalHistory
  module Conflation
    extend T::Sig

    class ConflationReason < T::InexactStruct
      prop :geom, T.nilable(T::Hash[Symbol, T.untyped])
      prop :tags, T.nilable(T::Hash[Symbol, T.untyped])
      prop :conflate, String
    end

    class Conflation < T::InexactStruct
      prop :before, OSMObject
      prop :before_at_now, T.nilable(OSMObject)
      prop :after, OSMObject
      prop :reason, ConflationReason

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
        %i[deleted].select{ |attrib|
          before.send(attrib) != after.send(attrib)
        }.collect { |attrib|
          [attrib.to_s, [['reject', nil, nil]]]
        }.compact.to_h
      end

      sig { returns(T::Hash[String, T::Array[[String, T.nilable(String), NilClass]]]) }
      def diff_tags
        (before.tags.keys + after.tags.keys).uniq.select{ |key|
          !before.tags.key?(key) || !after.tags.key?(key) || before.tags[key] != after.tags[key]
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
      prop :reason, ConflationReason

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
        %i[deleted].select{ |attrib|
          before&.send(attrib) != after&.send(attrib)
        }.collect { |attrib|
          [attrib.to_s, [['reject', nil, nil]]]
        }.compact.to_h
      end

      sig { returns(T::Hash[String, T::Array[[String, T.nilable(String), NilClass]]]) }
      def diff_tags
        ((before&.tags&.keys || []) + (after&.tags&.keys || [])).uniq.select{ |key|
          !before&.tags&.key?(key) || !after&.tags&.key?(key) || before&.tags&.[](key) != after&.tags&.[](key)
        }.to_h{ |key|
          [key, [['reject', nil, nil]]]
        }
      end
    end

    ConflationNilable = T.type_alias { T.any(Conflation, ConflationNilableOnly) }

    ConflationsNilable = T.type_alias { T::Array[ConflationNilable] }

    sig {
      params(
        before_tags: T::Hash[String, String],
        after_tags: T::Hash[String, String],
      ).returns(T::Boolean)
    }
    def self.same_refs?(before_tags, after_tags)
      before_refs = OSMLogicalHistory::Refs.refs(before_tags).sort
      return false if before_refs.empty?

      after_refs = OSMLogicalHistory::Refs.refs(after_tags).sort
      before_refs == after_refs
    end

    sig {
      params(
        befores: T::Set[OSMObject],
        afters: T::Set[OSMObject],
        demi_distance: Float,
      ).returns(
        T::Hash[
          [OSMObject, OSMObject],
          [OSMLogicalHistory::Tags::DistanceMeusure, OSMLogicalHistory::Geom::DistanceMeusure, Float]
        ],
      )
    }
    def self.conflate_matrix(befores, afters, demi_distance)
      distance_matrix = T.let({}, T::Hash[
        [OSMObject, OSMObject],
        [OSMLogicalHistory::Tags::DistanceMeusure, OSMLogicalHistory::Geom::DistanceMeusure, Float]
      ])

      befores.each{ |b|
        next if T.unsafe(b.geos).nil?

        afters.each{ |a|
          next if a.geojson_geometry.nil?

          t_dist = OSMLogicalHistory::Tags.tags_distance(b.tags, a.tags)
          next if t_dist.nil?

          same_refs = same_refs?(a.tags, b.tags)
          if same_refs
            # Same ref, force the distance tags to 0
            t_dist[0] = 0.0
          end

          next if T.unsafe(a.geos).nil?

          g_dist = (
            if same_refs
              [0.0, nil, nil, 'same refs']
            elsif b.geos == a.geos
              [0.0, nil, nil, 'same geom']
            elsif (b.geos&.dimension == 2 && a.geos&.dimension == 2 && befores.size == 1 && afters.size == 1)
              # Geom distance does not matter on 1x1 matrix, fast return
              [0.0, nil, nil, '1x1 matrix']
            else
              OSMLogicalHistory::Geom.geom_score(T.must(b.geos), T.must(a.geos), demi_distance)
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
        dist_geom: OSMLogicalHistory::Geom::DistanceMeusure,
      ).returns(T::Array[[
        T::Enumerable[OSMObject],
        T::Enumerable[OSMObject]
      ]])
    }
    def self.remaining_geom_parts(key_min, befores, afters, dist_geom)
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
        key_min: [OSMObject, OSMObject],
        befores: T::Set[OSMObject],
        afters: T::Set[OSMObject],
        dist_tags: OSMLogicalHistory::Tags::DistanceMeusure,
      ).returns(T::Array[[
        T::Enumerable[OSMObject],
        T::Enumerable[OSMObject]
      ]])
    }
    def self.remaining_tags_parts(key_min, befores, afters, dist_tags)
      parts = T.let([], T::Array[[
        T::Enumerable[OSMObject],
        T::Enumerable[OSMObject]
      ]])

      remaning_before_tags = dist_tags[1]
      remaning_after_tags = dist_tags[2]
      remaning_before = T.let(nil, T.nilable(OSMObject))
      remaning_after = T.let(nil, T.nilable(OSMObject))
      if !T.unsafe(remaning_before_tags).nil?
        remaning_before = key_min[0].with(tags: remaning_before_tags)
        parts << [[remaning_before], afters]
      end
      if !T.unsafe(remaning_after_tags).nil?
        remaning_after = key_min[1].with(tags: remaning_after_tags)
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
          after: key_min[1],
          reason: ConflationReason.new(
            tags: { score: dist[0][0], reason: dist[0][3] }.compact,
            geom: { score: dist[1][0], reason: dist[1][3] }.compact,
            conflate: 'better score match'
          )
        )
        paired << match

        befores.delete(key_min[0])
        afters.delete(key_min[1])

        distance_matrix = distance_matrix.select{ |k, _v| k[0] != key_min[0] && k[1] != key_min[1] }

        # Add the remaining geom parts to the matrix
        new_befores = T.let(Set.new, T::Set[OSMObject])
        new_afters = T.let(Set.new, T::Set[OSMObject])
        if !T.unsafe(dist[1][1]).nil? || !T.unsafe(dist[1][2]).nil?
          remaining_geom_parts(key_min, befores, afters, dist[1]).each{ |parts|
            new_befores = new_befores.merge(parts[0])
            new_afters = new_afters.merge(parts[1])
          }
        elsif !dist[0][1].nil? || !dist[0][2].nil?
          remaining_tags_parts(key_min, befores, afters, dist[0]).each{ |parts|
            new_befores = new_befores.merge(parts[0])
            new_afters = new_afters.merge(parts[1])
          }
          # else
          # TODO Handle case with reaming geom AND tags
        end

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
          sum.reason.conflate += ' (+unicity)'
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
        c = T.must(deleted[key])
        c.reason.conflate += ' (+deleted/created merge)'
        c
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
          union = p.with(
            tags: p.tags.merge(b.tags),
            geos: T.must(p.geos).union(b.geos)
          )
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
      befores_index = befores.index_by{ |b| [b.objtype, b.id] }
      afters_index = afters.index_by{ |a| [a.objtype, a.id] }
      befores = befores.select{ |b| !b.deleted }.to_set
      afters = afters.select{ |b| !b.deleted }.to_set

      paired_by_distance, befores, afters = conflate_core(befores, afters, afters_index, demi_distance)

      paired_by_distance, befores, afters = conflate_uniq(paired_by_distance, befores, afters)
      paired_by_distance, befores, afters = conflate_merge_remaning_parts(paired_by_distance, befores, afters)

      # Link deleted object to original
      paired_deleted_ids = []
      paired_deleted = afters_index.values.select(&:deleted).collect{ |a|
        b = befores_index[[a.objtype, a.id]]
        if !b.nil?
          paired_deleted_ids << [b.objtype, b.id]
          ConflationNilableOnly.new(before: b, before_at_now: a, after: a, reason: ConflationReason.new(conflate: 'match delete with original object'))
        end
      }.compact
      befores = befores.select{ |b| !paired_deleted_ids.include?([b.objtype, b.id]) }
      paired_by_distance += paired_deleted

      (
        paired_by_distance +
        befores.collect{ |b| ConflationNilableOnly.new(before: b, before_at_now: afters_index[[b.objtype, b.id]], reason: ConflationReason.new(conflate: 'same osm object')) } +
        afters.collect{ |a| ConflationNilableOnly.new(after: a, reason: ConflationReason.new(conflate: 'remeaning only after object')) }
      ).collect{ |c|
        # Get original full objects (not remaining part)
        ConflationNilableOnly.new(
          before: c.before.nil? ? nil : T.must(befores_index[[T.must(c.before).objtype, T.must(c.before).id]]),
          before_at_now: c.before_at_now,
          after: c.after.nil? ? nil : T.must(afters_index[[T.must(c.after).objtype, T.must(c.after).id]]),
          reason: c.reason,
        )
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
      paired = conflate_merge_deleted_created(paired)

      paired.collect{ |c|
        if !c.before.nil? && !c.after.nil? && !T.unsafe(c.before&.geos).nil? && !T.unsafe(c.after&.geos).nil?
          after_geos = T.must(c.after&.geos)
          before_geos = T.must(c.before&.geos)
          geom_distance = before_geos.distance(after_geos)
          if geom_distance > 0
            c.reason.geom = (c.reason.geom || {}).merge({ min_distance: geom_distance })
          end
          if before_geos.dimension > 0 && after_geos.dimension > 0
            # Only it not points, else it the same as min_distance
            geom_distance = DistanceHausdorff.distance(before_geos, after_geos)
            if geom_distance > 0
              c.reason.geom = (c.reason.geom || {}).merge({ max_distance: geom_distance })
            end
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
