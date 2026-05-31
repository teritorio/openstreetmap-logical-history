# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'set'
require 'sorted_set'
require 'rgl/implicit'
require 'rgl/connected_components'
require 'active_support/core_ext/enumerable'
require_relative 'distance_hausdorff'
require_relative 'refs'
require_relative 'tags'
require_relative 'geom'
require_relative 'osm_object'


module OSMLogicalHistory
  class Conflation
    extend T::Sig
    extend T::Generic

    OSMObjectT = type_member { { upper: OSMObject } }

    class ConflationReason < T::InexactStruct
      prop :geom, T.nilable(T::Hash[Symbol, T.untyped])
      prop :tags, T.nilable(T::Hash[Symbol, T.untyped])
      prop :conflate, String
    end

    class Conflation < T::InexactStruct
      extend T::Sig
      extend T::Generic

      OSMObjectT = type_member { { upper: OSMObject } }

      prop :before, OSMObjectT
      prop :before_at_now, T.nilable(OSMObjectT)
      prop :after, OSMObjectT
      prop :conflation_reason, ConflationReason

      sig { returns([OSMObjectT, T.nilable(OSMObjectT), OSMObjectT]) }
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

    class ConflationNilableOnly < T::InexactStruct
      extend T::Sig
      extend T::Generic

      OSMObjectT = type_member { { upper: OSMObject } }

      prop :before, T.nilable(OSMObjectT)
      prop :before_at_now, T.nilable(OSMObjectT)
      prop :after, T.nilable(OSMObjectT)
      prop :conflation_reason, ConflationReason

      sig { returns(T::Array[T.nilable(OSMObjectT)]) }
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

    sig {
      params(
        before_tags: T::Hash[String, String],
        after_tags: T::Hash[String, String],
      ).returns(T::Boolean)
    }
    def same_refs?(before_tags, after_tags)
      before_refs = OSMLogicalHistory::Refs.refs(before_tags).sort
      return false if before_refs.empty?

      after_refs = OSMLogicalHistory::Refs.refs(after_tags).sort
      before_refs == after_refs
    end

    class MatrixCell < T::Struct
      extend T::Sig
      extend T::Generic

      OSMObjectT = type_member { { upper: OSMObject } }

      prop :before, OSMObjectT
      prop :after, OSMObjectT
      prop :dist_tags, OSMLogicalHistory::Tags::DistanceMeusure
      prop :dist_geom, OSMLogicalHistory::Geom::DistanceMeusure

      sig {
        params(
          other: MatrixCell[OSMObjectT],
        ).returns(Integer)
      }
      def <=>(other)
        dist = dist_tags[0] + dist_geom[0] <=> other.dist_tags[0] + other.dist_geom[0]
        return dist if dist != 0

        # Match smaller first
        dist = (Geom.geom_diameter(T.must(before.geos)) <=> Geom.geom_diameter(T.must(other.before.geos)))
        return dist if dist != 0

        dist = (Geom.geom_diameter(T.must(after.geos)) <=> Geom.geom_diameter(T.must(other.after.geos)))
        return dist if dist != 0

        [before, after] <=> [other.before, other.after]
      end
    end

    sig {
      params(
        befores: T::Set[OSMObjectT],
        afters: T::Set[OSMObjectT],
        demi_distance: Float,
      ).returns(T::Set[MatrixCell[OSMObjectT]])
    }
    def conflate_matrix(befores, afters, demi_distance)
      distance_matrix = T.let([], T::Array[MatrixCell[OSMObjectT]])

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
            t_dist[3] += ' (+same refs)'
          end

          next if T.unsafe(a.geos).nil?

          g_dist = (
            if b.geos == a.geos
              [0.0, nil, nil, 'same geom']
            elsif (b.geos&.dimension == 2 && a.geos&.dimension == 2 && befores.size == 1 && afters.size == 1)
              # Geom distance does not matter on 1x1 matrix, fast return
              [0.0, nil, nil, '1x1 matrix']
            else
              OSMLogicalHistory::Geom.geom_score(T.must(b.geos), T.must(a.geos), demi_distance)
            end
          )
          next if g_dist.nil?

          distance_matrix << MatrixCell.new(
            before: b,
            after: a,
            dist_tags: t_dist,
            dist_geom: g_dist,
          )
        }
      }

      T.cast(SortedSet.new(distance_matrix), T::Set[MatrixCell[OSMObjectT]])
    end

    sig {
      params(
        object: OSMObjectT,
        geom: RGeo::Feature::Geometry,
      ).returns(T::Enumerable[OSMObjectT])
    }
    def remaining_geom_parts(object, geom)
      geoms = (
        if [RGeo::Feature::MultiPoint, RGeo::Feature::MultiLineString, RGeo::Feature::MultiPolygon].include?(geom.geometry_type)
          T.cast(geom, RGeo::Feature::GeometryCollection).each.to_a
        else
          [geom]
        end
      )
      geoms.collect{ |geom_|
        remaning = object.clone
        remaning.geos = geom_.clone
        remaning
      }
    end

    sig {
      params(
        object: OSMObjectT,
        tags: T::Hash[String, String],
      ).returns(T::Enumerable[OSMObjectT])
    }
    def remaining_tags_parts(object, tags)
      remaning = object.clone
      remaning.tags = tags
      [remaning]
    end

    sig {
      params(
        befores: T::Set[OSMObjectT],
        afters: T::Set[OSMObjectT],
        distance_matrix: T::Set[MatrixCell[OSMObjectT]],
        demi_distance: Float,
        cell: MatrixCell[OSMObjectT],
      ).returns(
        [
          T::Set[MatrixCell[OSMObjectT]],
          T::Set[OSMObjectT],
          T::Set[OSMObjectT],
        ],
      )
    }
    def add_remaining_parts(befores, afters, distance_matrix, demi_distance, cell)
      # Add the remaining geom parts to the matrix
      new_befores = T.let(Set.new, T::Set[OSMObjectT])
      new_afters = T.let(Set.new, T::Set[OSMObjectT])
      if !T.unsafe(cell.dist_geom[1]).nil? || !T.unsafe(cell.dist_geom[2]).nil?
        new_befores += remaining_geom_parts(cell.before, T.must(cell.dist_geom[1])) if !T.unsafe(cell.dist_geom[1]).nil?
        new_afters += remaining_geom_parts(cell.after, T.must(cell.dist_geom[2])) if !T.unsafe(cell.dist_geom[2]).nil?
      elsif !cell.dist_tags[1].nil? || !cell.dist_tags[2].nil?
        new_befores += remaining_tags_parts(cell.before, T.must(cell.dist_tags[1])) if !cell.dist_tags[1].nil?
        new_afters += remaining_tags_parts(cell.after, T.must(cell.dist_tags[2])) if !cell.dist_tags[2].nil?
        # else
        # TODO Handle case with reaming geom AND tags
      end

      distance_matrix += conflate_matrix(new_befores, new_afters, demi_distance)
      distance_matrix += conflate_matrix(new_befores, afters, demi_distance)
      distance_matrix += conflate_matrix(befores, new_afters, demi_distance)
      befores = befores.merge(new_befores)
      afters = afters.merge(new_afters)

      [distance_matrix, befores, afters]
    end

    sig {
      params(
        befores: T::Set[OSMObjectT],
        afters: T::Set[OSMObjectT],
        afters_index: T::Hash[[String, Integer], OSMObjectT],
        demi_distance: Float,
      ).returns([
        T::Array[Conflation[OSMObjectT]],
        T::Set[OSMObjectT],
        T::Set[OSMObjectT],
      ])
    }
    def conflate_core(befores, afters, afters_index, demi_distance)
      distance_matrix = conflate_matrix(befores, afters, demi_distance)

      paired = T.let([], T::Array[Conflation[OSMObjectT]])
      until distance_matrix.empty?
        cell = T.must(distance_matrix.first)
        match = Conflation.new(
          before: cell.before,
          before_at_now: afters_index[[cell.before.objtype, cell.before.id]],
          after: cell.after,
          conflation_reason: ConflationReason.new(
            tags: { score: cell.dist_tags[0], reason: cell.dist_tags[3] }.compact,
            geom: { score: cell.dist_geom[0], reason: cell.dist_geom[3] }.compact,
            conflate: 'better score match'
          )
        )
        paired << match

        befores.delete(cell.before)
        afters.delete(cell.after)

        distance_matrix.delete_if{ |c| c.before == cell.before || c.after == cell.after }

        distance_matrix, befores, afters = add_remaining_parts(befores, afters, distance_matrix, demi_distance, cell)
      end

      [paired, befores, afters]
    end

    sig {
      params(
        paired: T::Array[Conflation[OSMObjectT]],
        befores: T::Set[OSMObjectT],
        afters: T::Set[OSMObjectT],
      ).returns([
        T::Array[Conflation[OSMObjectT]],
        T::Set[OSMObjectT],
        T::Set[OSMObjectT],
      ])
    }
    def conflate_uniq(paired, befores, afters)
      # Make conflation (before, after) uniq
      r = paired.group_by{ |p|
        [p.before.objtype, p.before.id, p.after.objtype, p.after.id]
      }.values.collect{ |group|
        # Merge geometry parts with same before and after objects
        T.must(group.reduce{ |sum, conflate|
          sum.before.geos = T.must(sum.before.geos).union(conflate.before.geos)
          sum.after.geos = T.must(sum.after.geos).union(conflate.after.geos)
          sum.conflation_reason.conflate += ' (+unicity)'
          sum
        })
      }

      [r, befores, afters]
    end

    sig {
      params(
        paired: T::Array[ConflationNilableOnly[OSMObjectT]],
      ).returns(T::Array[ConflationNilableOnly[OSMObjectT]])
    }
    def conflate_merge_deleted_created(paired)
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
        c.conflation_reason.conflate += ' (+deleted/created merge)'
        c
      }

      paired = paired.select{ |p| !merged.include?(p) }

      paired + deleted_created
    end

    sig {
      params(
        paireds: T::Array[Conflation[OSMObjectT]],
        remeainings: T::Enumerable[OSMObjectT],
        key: Symbol,
        block: T.proc.params(c: Conflation[OSMObjectT]).returns(OSMObjectT)
      ).returns([T::Array[Conflation[OSMObjectT]], T::Enumerable[OSMObjectT]])
    }
    def conflate_merge_remaning_parts_side(paireds, remeainings, key, &block)
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
          union = p.clone
          union.tags = p.tags.merge(b.tags)
          union.geos = T.must(p.geos).union(b.geos)
          paired.send("#{key}=", union)
          false
        end
      }

      [paireds, remeainings]
    end

    sig {
      params(
        paired: T::Array[Conflation[OSMObjectT]],
        befores: T::Set[OSMObjectT],
        afters: T::Set[OSMObjectT],
      ).returns([
        T::Array[Conflation[OSMObjectT]],
        T::Enumerable[OSMObjectT],
        T::Enumerable[OSMObjectT],
      ])
    }
    def conflate_merge_remaning_parts(paired, befores, afters)
      paired, befores = conflate_merge_remaning_parts_side(paired, befores, :before, &:before)
      paired, afters = conflate_merge_remaning_parts_side(paired, afters, :after, &:after)

      [paired, befores, afters]
    end

    sig {
      params(
        befores: T::Enumerable[OSMObjectT],
        afters: T::Enumerable[OSMObjectT],
        demi_distance: Float,
      ).returns(T::Array[ConflationNilableOnly[OSMObjectT]])
    }
    def conflate(befores, afters, demi_distance)
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
          ConflationNilableOnly[OSMObjectT].new(before: b, before_at_now: a, after: a, conflation_reason: ConflationReason.new(conflate: 'match delete with original object'))
        end
      }.compact
      befores = befores.select{ |b| !paired_deleted_ids.include?([b.objtype, b.id]) }
      paired_by_distance += paired_deleted

      T.cast(
        paired_by_distance +
        befores.collect{ |b| ConflationNilableOnly[OSMObjectT].new(before: b, before_at_now: afters_index[[b.objtype, b.id]], conflation_reason: ConflationReason.new(conflate: 'remeaning only before object')) } +
        afters.collect{ |a| ConflationNilableOnly[OSMObjectT].new(after: a, conflation_reason: ConflationReason.new(conflate: 'remeaning only after object')) },
        T::Array[ConflationNilableOnly[OSMObjectT]]
      ).collect{ |c|
        # Get original full objects (not remaining part)
        ConflationNilableOnly.new(
          before: c.before.nil? ? nil : T.must(befores_index[[T.must(c.before).objtype, T.must(c.before).id]]),
          before_at_now: c.before_at_now,
          after: c.after.nil? ? nil : T.must(afters_index[[T.must(c.after).objtype, T.must(c.after).id]]),
          conflation_reason: c.conflation_reason,
        )
      }
    end

    sig {
      params(
        befores: T::Enumerable[OSMObjectT],
        afters: T::Enumerable[OSMObjectT],
        demi_distance: Float,
      ).returns(T::Array[ConflationNilableOnly[OSMObjectT]])
    }
    def conflate_with_simplification(befores, afters, demi_distance)
      paired = conflate(befores, afters, demi_distance)
      paired = conflate_merge_deleted_created(paired)

      paired.collect{ |c|
        if !c.before.nil? && !c.after.nil? && !T.unsafe(c.before&.geos).nil? && !T.unsafe(c.after&.geos).nil?
          after_geos = T.must(c.after&.geos)
          before_geos = T.must(c.before&.geos)
          geom_distance = before_geos.distance(after_geos)
          if geom_distance > 0
            c.conflation_reason.geom = (c.conflation_reason.geom || {}).merge({ min_distance: geom_distance })
          end
          if before_geos.dimension > 0 && after_geos.dimension > 0
            # Only if it is not points, else it the same as min_distance
            geom_distance = DistanceHausdorff.distance(before_geos, after_geos)
            if geom_distance > 0
              c.conflation_reason.geom = (c.conflation_reason.geom || {}).merge({ max_distance: geom_distance })
            end
          end
        end
        c
      }
    end

    sig {
      params(
        befores: T::Enumerable[OSMObjectT],
        afters: T::Enumerable[OSMObjectT],
        demi_distance: Float,
      ).returns(T::Array[T::Array[ConflationNilableOnly[OSMObjectT]]])
    }
    def conflate_cluster(befores, afters, demi_distance)
      links = conflate_with_simplification(befores, afters, demi_distance)

      vertices = T.let(Hash.new { |h, k| h[k] = [] }, T::Hash[[String, Integer], T::Array[ConflationNilableOnly[OSMObjectT]]])
      links.each{ |i|
        if !i.before.nil?
          T.must(vertices[[T.must(i.before).objtype, T.must(i.before).id]]) << i
        end
        if !i.after.nil?
          T.must(vertices[[T.must(i.after).objtype, T.must(i.after).id]]) << i
        end
      }

      graph = RGL::ImplicitGraph.new { |g|
        g.vertex_iterator { |b|
          vertices.keys.each(&b)
        }
        g.adjacent_iterator { |x, b|
          T.must(vertices[x]).each { |a|
            before = a.before
            if !before.nil? && x != [before.objtype, before.id]
              b.call([before.objtype, before.id])
            end
            after = a.after
            if !after.nil? && x != [after.objtype, after.id]
              b.call([after.objtype, after.id])
            end
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
