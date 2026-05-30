# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'test/unit'
require 'json'
require_relative '../../lib/osm_logical_history/conflation'
require_relative '../../lib/osm_logical_history/tags'
require_relative '../../lib/osm_logical_history/geom'

class TestConflation < Test::Unit::TestCase
  extend T::Sig

  Tags = OSMLogicalHistory::Tags
  Geom = OSMLogicalHistory::Geom
  Conflation = OSMLogicalHistory::Conflation

  @@demi_distance = T.let(1.0, Float) # m

  sig {
    params(
      id: Integer,
      version: Integer,
      deleted: T::Boolean,
      tags: T::Hash[String, String],
      geojson_geometry: String,
      srid: Integer,
    ).returns(OSMLogicalHistory::OSMObject)
  }
  def build_object(
    id: 1,
    version: 1,
    deleted: false,
    tags: { 'highway' => 'a' },
    geojson_geometry: '{"type":"Point","coordinates":[0,0]}',
    srid: 4326
  )
    geos_factory = OSMLogicalHistory.build_geos_factory(srid)
    OSMLogicalHistory::OSMObject.new(
        objtype: 'n',
        id: id,
        geojson_geometry: geojson_geometry,
        geos_factory: geos_factory,
        deleted: deleted,
        members: nil,
        version: version,
        # changesets: nil,
        username: 'bob',
        created: 'today',
        tags: tags,
        # is_change: false,
        # group_ids: nil,
      )
  end

  sig {
    params(
      before_tags: T::Hash[String, String],
      after_tags: T::Hash[String, String],
      before_geom: String,
      after_geom: String,
      srid: Integer,
    ).returns([T::Array[OSMLogicalHistory::OSMObject], T::Array[OSMLogicalHistory::OSMObject]])
  }
  def build_objects(
    before_tags: { 'highway' => 'a' },
    after_tags: { 'highway' => 'a' },
    before_geom: '{"type":"Point","coordinates":[0,0]}',
    after_geom: '{"type":"Point","coordinates":[0,0]}',
    srid: 4326
  )
    before = [build_object(id: 1, tags: before_tags, geojson_geometry: before_geom, srid: srid)]
    after = [build_object(id: 1, tags: after_tags, geojson_geometry: after_geom, srid: srid)]
    [before, after]
  end

  sig { void }
  def test_conflate_refs
    before, after = build_objects(before_tags: { 'highway' => 'a', 'ref' => 'a' }, after_tags: { 'highway' => 'a', 'ref' => 'a' })
    assert_equal(
      [[before[0], after[0], after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )

    before, after = build_objects(before_tags: { 'highway' => 'a', 'ref' => 'a', 'foo' => 'a' }, after_tags: { 'highway' => 'a', 'ref' => 'a', 'foo' => 'b' })
    assert_equal(
      [[before[0], after[0], after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )

    before, after = build_objects(before_tags: { 'ref' => 'a' }, after_tags: { 'ref' => 'b' })
    assert_equal(
      [[before[0], after[0], nil], [nil, nil, after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )
  end

  sig { void }
  def test_conflate_tags
    before, after = build_objects(before_tags: { 'highway' => 'a' }, after_tags: { 'highway' => 'a' })
    assert_equal(
      [[before[0], after[0], after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )

    before, after = build_objects(before_tags: { 'highway' => 'a', 'foo' => 'a' }, after_tags: { 'highway' => 'a', 'foo' => 'b' })
    assert_equal(
      [[before[0], after[0], after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )

    before, after = build_objects(before_tags: { 'highway' => 'a' }, after_tags: { 'building' => 'b' })
    assert_equal(
      [[before[0], after[0], nil], [nil, nil, after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )

    bt = {
      'name' => 'Utopia',
      'brand' => 'Utopia',
      'screen' => '4',
      'amenity' => 'cinema',
      'roof:shape' => 'gabled',
      'addr:street' => 'Rue du Moulinet',
      'brand:wikidata' => 'Q3552766',
      'addr:housenumber' => '11',
      'phone' => '+33 (0) 3 25 40 52 90',
    }
    at = bt.merge({
      'phone' => '+33 3 25 40 52 90',
      'addr:city' => 'Pont-Sainte-Marie',
      'addr:postcode' => '10150',
    }).compact
    before, after = build_objects(before_tags: bt, after_tags: at)

    assert(T.must(Tags.tags_distance(bt, at))[0] < 0.5)
    assert_equal(
      [[before[0], after[0], after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )
  end

  sig { void }
  def test_conflate_geom
    before, after = build_objects(before_geom: '{"type":"Point","coordinates":[0,0]}', after_geom: '{"type":"Point","coordinates":[0,1]}')
    assert_equal(1.0, Geom.geom_score(
      T.must(before[0]&.geos),
      T.must(after[0]&.geos),
      @@demi_distance
    )&.first)
    assert_equal(
      [[before[0], after[0], after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )

    before, after = build_objects(before_geom: '{"type":"LineString","coordinates":[[0,0],[100,0]]}', after_geom: '{"type":"LineString","coordinates":[[0,0],[0,100]]}')
    assert_equal(0.5, Geom.geom_score(
      T.must(before[0]&.geos),
      T.must(after[0]&.geos),
      @@demi_distance
    )&.first)
    assert_equal(
      [[before[0], after[0], after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )

    before, after = build_objects(before_geom: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', after_geom: '{"type":"LineString","coordinates":[[0,200],[0,300]]}')
    assert_equal(0.995049504950495, Geom.geom_score(
      T.must(before[0]&.geos),
      T.must(after[0]&.geos),
      @@demi_distance
    )&.first)
    assert_equal(
      [[before[0], after[0], after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )
  end

  sig { void }
  def test_conflate_deleted
    tags = { 'highway' => 'residential' }
    geojson_geometry = '{"type":"Point","coordinates":[0,0]}'
    before = [
      build_object(id: 1, geojson_geometry: geojson_geometry, tags: tags),
    ]
    after = [
      build_object(id: 1, geojson_geometry: geojson_geometry, tags: tags, deleted: true),
      build_object(id: 2, geojson_geometry: geojson_geometry, tags: tags),
    ]

    conflations = Conflation.new.conflate(before, after, @@demi_distance)
    assert_equal(2, conflations.size, conflations)
    assert_equal(
      [[before[0], after[0], after[0]], [before[0], after[0], after[1]]].collect{ |t| t.collect(&:id) }.sort,
      conflations.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }.sort
    )
  end

  sig { void }
  def test_conflate_semantic_deleted
    geojson_geometry = '{"type":"Point","coordinates":[0,0]}'
    before = [
      build_object(id: 1, geojson_geometry: geojson_geometry, tags: { 'highway' => 'residential' }),
    ]
    after = [
      build_object(id: 1, geojson_geometry: geojson_geometry, tags: {}),
      build_object(id: 2, geojson_geometry: geojson_geometry, tags: { 'highway' => 'residential' }),
    ]

    conflations = Conflation.new.conflate(before, after, @@demi_distance)
    assert_equal(2, conflations.size, conflations)
    assert_equal([[before[0], after[0], after[1]], [nil, nil, after[0]]], conflations.collect(&:to_a))
  end

  sig { void }
  def test_conflate_tags_geom_not_tag_comparable
    before, after = build_objects(
      before_tags: { 'amenity' => 'bicycle_parking' },
      before_geom: '{"type":"Point","coordinates":[0, 0]}',
      after_tags: { 'amenity' => 'parking' },
      after_geom: '{"type":"Point","coordinates":[0, 0]}'
    )
    assert_equal(nil, Tags.tags_distance(T.must(before[0]).tags, T.must(after[0]).tags))
    conflate_distances = Conflation.new.conflate_matrix(before.to_set, after.to_set, @@demi_distance)
    assert(conflate_distances.empty?)
    assert_equal(
      [[before[0], after[0], nil], [nil, nil, after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )
  end

  sig { void }
  def test_conflate_tags_geom_too_large_distance
    before, after = build_objects(
      before_tags: { 'amenity' => 'bicycle_parking' },
      before_geom: '{"type":"Point","coordinates":[0, 0]}',
      after_tags: { 'amenity' => 'bicycle_parking' },
      after_geom: '{"type":"Point","coordinates":[0, 2]}'
    )
    assert_equal([0.0, nil, nil, 'matched tags: amenity=bicycle_parking'], Tags.tags_distance(T.must(before[0]).tags, T.must(after[0]).tags))
    conflate_distances = Conflation.new.conflate_matrix(before.to_set, after.to_set, @@demi_distance)
    assert(conflate_distances.empty?)
    assert_equal(
      [[before[0], after[0], nil], [nil, nil, after[0]]],
      Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a)
    )
  end

  sig { void }
  def test_conflate_tags_geom
    before, after = build_objects(
      before_tags: { 'amenity' => 'bicycle_parking' },
      before_geom: '{"type":"Point","coordinates":[0, 0]}',
      after_tags: { 'amenity' => 'bicycle_parking' },
      after_geom: '{"type":"Point","coordinates":[0, 0.5]}'
    )
    assert_equal([0.0, nil, nil, 'matched tags: amenity=bicycle_parking'], Tags.tags_distance(T.must(before[0]).tags, T.must(after[0]).tags))
    conflate_distances = Conflation.new.conflate_matrix(before.to_set, after.to_set, @@demi_distance)
    assert_equal([[before[0], after[0]]], conflate_distances.collect{ |cell| [cell.before, cell.after] })
    assert_equal([0.0, nil, nil, 'matched tags: amenity=bicycle_parking'], T.must(conflate_distances.first).dist_tags)
    assert_equal([[before[0], after[0], after[0]]], Conflation.new.conflate(before, after, @@demi_distance).collect(&:to_a))
  end

  sig { void }
  def test_conflate_no_comparable_tags
    srid = 23_031 # UTM zone 31N, 0°E
    demi_distance = 200.0 # m

    before, after = build_objects(
      before_tags: { 'landuse' => 'retail' },
      before_geom: '{"type":"Point","coordinates":[28.10176, -15.44687]}',
      after_tags: { 'building' => 'yes', 'building:levels' => '13' },
      after_geom: '{"type":"Point","coordinates":[28.10128, -15.44647]}',
      srid: srid,
    )
    conflate_distances = Conflation.new.conflate_matrix(before.to_set, after.to_set, demi_distance)
    assert_equal([], conflate_distances.collect{ |cell| [cell.before, cell.after] })
    assert_equal([[before[0], after[0], nil], [nil, nil, after[0]]], Conflation.new.conflate(before, after, demi_distance).collect(&:to_a))
  end

  sig { void }
  def test_conflate_double
    srid = 2154
    demi_distance = 200.0 # m

    before_tags = {
      'bus' => 'yes',
      'highway' => 'bus_stop',
      'name' => 'Guyenne',
      'operator' => 'Chronoplus',
      'public_transport' => 'platform',
    }
    before = [
      build_object(id: 1, geojson_geometry: '{"type":"Point","coordinates":[-1.4865344, 43.5357032]}', tags: before_tags, srid: srid),
      build_object(id: 2, geojson_geometry: '{"type":"Point","coordinates":[-1.4864637, 43.5359501]}', tags: before_tags, srid: srid),
    ]

    after_tags = {
      'bench' => 'no',
      'bus' => 'yes',
      'highway' => 'bus_stop',
      'name' => 'Guyenne',
      'network' => 'Txik Txak',
      'operator' => 'Chronoplus',
      'public_transport' => 'platform',
      'shelter' => 'no',
    }
    after = [
      build_object(id: 1, geojson_geometry: '{"type":"Point","coordinates":[-1.4865344, 43.5357032]}', tags: after_tags, srid: srid),
      build_object(id: 2, geojson_geometry: '{"type":"Point","coordinates":[-1.4864637, 43.5359501]}', tags: after_tags, srid: srid),
    ]

    conflate_distances = Conflation.new.conflate_matrix(before.to_set, after.to_set, demi_distance)
    assert_equal(4, conflate_distances.size)
    assert_equal(
      [[before[0], after[0], after[0]], [before[1], after[1], after[1]]],
      Conflation.new.conflate(before, after, demi_distance).collect(&:to_a)
    )
  end

  sig { void }
  def test_conflate_polygon
    srid = 2154
    demi_distance = 200.0 # m

    geojson = '{"type":"Polygon","coordinates":[[[-1.102128,43.543789],[-1.102262,43.543822],[-1.102333,43.543663],[-1.102197,43.54363],[-1.102128,43.543789]]]}'

    before_tags = {
      'tourism' => 'information',
      'opening_hours' => 'Mo-Sa 09:30-13:00,14:30-18:00',
    }
    before = [
      build_object(id: 1, geojson_geometry: geojson, tags: before_tags, srid: srid),
    ]

    after_tags = {
      'tourism' => 'information',
      'opening_hours' => 'Mo-Sa 09:30-13:00,14:30-18:00; PH 10:00-13:00',
    }
    after = [
      build_object(id: 1, geojson_geometry: geojson, tags: after_tags, srid: srid),
    ]

    assert_equal(
      [[before[0], after[0], after[0]]],
      Conflation.new.conflate(before, after, demi_distance).collect(&:to_a)
    )
  end

  sig { void }
  def test_conflate_splited_way
    tags = {
      'highway' => 'residential',
    }
    before = [
      build_object(id: 1, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,200]]}', tags: tags),
    ]
    after = [
      build_object(id: 1, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,200]]}', tags: tags, deleted: true),
      build_object(id: 2, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: tags),
      build_object(id: 3, geojson_geometry: '{"type":"LineString","coordinates":[[0,100],[0,200]]}', tags: tags),
    ]

    conflations = Conflation.new.conflate(before, after, @@demi_distance)
    assert_equal(3, conflations.size, conflations)
    assert_equal(
      [[before[0], after[0], after[0]], [before[0], after[0], after[1]], [before[0], after[0], after[2]]].collect{ |t| t.collect(&:id) }.sort,
      conflations.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }.sort
    )
  end

  sig { void }
  def test_conflate_splited_way_gap
    tags = {
      'highway' => 'residential',
    }
    before = [
      build_object(id: 1, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,300]]}', tags: tags),
    ]
    after = [
      build_object(id: 2, geojson_geometry: '{"type":"LineString","coordinates":[[0,100],[0,200]]}', tags: tags),
    ]

    paired, befores, afters = Conflation.new.conflate_core(Set.new(before), Set.new(after), {}, @@demi_distance)
    assert_equal(1, paired.size, paired)
    assert_equal(2, befores.size, befores)
    assert_equal(0, afters.size, afters)

    conflations = Conflation.new.conflate(before, after, @@demi_distance)
    assert_equal(1, conflations.size, conflations)
    assert_equal(
      [[before[0], nil, after[0]]].collect{ |t| t.collect{ |i| i&.id } }.sort,
      conflations.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }.sort
    )
  end

  sig { void }
  def test_conflate_splited_tags
    before = [
      build_object(id: 1, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: {
        'building' => 'house',
        'landuse' => 'residencial',
      }),
    ]
    after = [
      build_object(id: 1, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: {}, deleted: true),
      build_object(id: 2, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: { 'building' => 'house' }),
      build_object(id: 3, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: { 'landuse' => 'residencial' }),
    ]

    conflations = Conflation.new.conflate(before, after, @@demi_distance)
    assert_equal(3, conflations.size, conflations)
    assert_equal(
      [[before[0], after[0], after[0]], [before[0], after[0], after[1]], [before[0], after[0], after[2]]].collect{ |t| t.collect(&:id) },
      conflations.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }.sort
    )
  end

  sig { void }
  def test_conflate_splited_tags_reverse
    before = [
      build_object(id: 2, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: { 'building' => 'house' }),
      build_object(id: 3, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: { 'landuse' => 'residencial' }),
    ]
    after = [
      build_object(id: 2, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: {}, deleted: true),
      build_object(id: 3, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: {}, deleted: true),
      build_object(id: 1, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: {
        'building' => 'house',
        'landuse' => 'residencial',
      }),
    ]

    conflations = Conflation.new.conflate(before, after, @@demi_distance)
    assert_equal(4, conflations.size, conflations)
    assert_equal(
      [[before[0], after[0], after[0]], [before[1], after[1], after[1]], [before[0], after[0], after[2]], [before[1], after[1], after[2]]].collect{ |t| t.collect(&:id) }.sort,
      conflations.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }.sort
    )
  end

  sig { void }
  def test_conflate_splited_tags_real
    before = [
      build_object(id: 1, geojson_geometry: '{"type":"Point","coordinates":[1.7528455,49.1251444]}', tags: {
        'amenity' => 'townhall',
        'opening_hours' => 'Mo 17:00-19:00; Tu 10:00-12:00; Th 10:00-12:00; Sa 09:00-11:00',
      }),
      build_object(id: 2, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: {
        'building' => 'yes'
      }),
    ]
    after = [
      build_object(id: 1, geojson_geometry: '{"type":"Point","coordinates":[1.7528455,49.1251444]}', tags: {}, deleted: true),
      build_object(id: 2, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: {
        'amenity' => 'townhall',
        'opening_hours' => 'Mo 17:00-19:00; Tu 10:00-12:00; Th 10:00-12:00; Sa 09:00-11:00',
        'building' => 'yes'
      }),
    ]

    conflations = Conflation.new.conflate(before, after, @@demi_distance)
    assert_equal(3, conflations.size, conflations)
    assert_equal(
      [[before[0], after[0], after[0]], [before[0], after[0], after[1]], [before[1], after[1], after[1]]].collect{ |t| t.collect(&:id) },
      conflations.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }.sort
    )
  end

  sig { void }
  def test_conflate_merge_duplicate
    before = [
      build_object(
        id: 1,
        geojson_geometry: '{"type": "LineString", "coordinates": [[-1.421862006187439, 43.72491455078125], [-1.421954035758972, 43.72502899169922], [-1.422500014305115, 43.72486877441406], [-1.422412037849426, 43.72471237182617], [-1.421862006187439, 43.72491455078125]]}',
        tags: { 'amenity' => 'parking' }
      ),
    ]
    after = [
      build_object(
        id: 1,
        geojson_geometry: '{"type": "LineString", "coordinates": [[-1.421862006187439, 43.72491455078125], [-1.421954035758972, 43.72502899169922], [-1.422500014305115, 43.72486877441406], [-1.422412037849426, 43.72471237182617], [-1.422093033790588, 43.724788665771484], [-1.422013998031616, 43.72474670410156], [-1.421862006187439, 43.72491455078125]]}',
        tags: { 'fee' => 'no', 'access' => 'yes', 'amenity' => 'parking', 'parking' => 'surface' }
      )
    ]

    conflation = Conflation.new.conflate(before, after, @@demi_distance)
    assert_equal(1, conflation.size, conflation)
    assert_equal(
      [[before[0], after[0], after[0]]].collect{ |t| t.collect(&:id) },
      conflation.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }
    )
  end

  sig { void }
  def test_conflate_merge_remeaning
    tags = {
      'highway' => 'residential',
    }
    before = [
      build_object(id: 1, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,200]]}', tags: tags),
    ]
    after = [
      build_object(id: 1, geojson_geometry: '{"type":"LineString","coordinates":[[0,0],[0,100]]}', tags: tags),
    ]

    conflations = Conflation.new.conflate(before, after, @@demi_distance)
    assert_equal(1, conflations.size, conflations)
    assert_equal(
      [[before[0], after[0], after[0]]].collect{ |t| t.collect(&:id) },
      conflations.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }
    )
  end

  sig { void }
  def test_conflate_merge_deleted_created
    before = [
      build_object(id: 1, geojson_geometry: '{"type":"Point","coordinates":[0,0]}', tags: { 'amenity' => 'a' }),
    ]
    after = [
      build_object(id: 1, geojson_geometry: '{"type":"Point","coordinates":[0,0]}', tags: { 'building' => 'b' }),
    ]

    conflations = Conflation.new.conflate_with_simplification(before, after, @@demi_distance)
    assert_equal(1, conflations.size, conflations)
    assert_equal(
      [[before[0], after[0], after[0]]].collect{ |t| t.collect(&:id) },
      conflations.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }
    )
  end

  sig { void }
  def test_conflate_cluster
    before, after = build_objects(before_tags: { 'ref' => 'a' }, after_tags: { 'ref' => 'a' })
    assert_equal(
      [[[before[0], after[0], after[0]]]],
      Conflation.new.conflate_cluster(before, after, @@demi_distance).collect{ |t| t.collect(&:to_a) }
    )

    before, after = build_objects(before_tags: { 'ref' => 'a', 'foo' => 'a' }, after_tags: { 'ref' => 'a', 'foo' => 'b' })
    assert_equal(
      [[[before[0], after[0], after[0]]]],
      Conflation.new.conflate_cluster(before, after, @@demi_distance).collect{ |t| t.collect(&:to_a) }
    )
  end

  sig { void }
  def test_conflate_split_highway_small_first
    before = [
      build_object(id: 1, version: 1, srid: 2154, geojson_geometry: {
        type: 'LineString',
        coordinates: [[-1.043926954, 42.718948364], [-1.043930054, 42.718891144], [-1.043956041, 42.718841553], [-1.043995976, 42.718795776], [-1.044077992, 42.718753815], [-1.044137955, 42.718738556], [-1.044232965, 42.718738556], [-1.044824004, 42.718753815], [-1.045017958, 42.718746185], [-1.045133948, 42.718730927], [-1.045251966, 42.718700409], [-1.045400977, 42.718650818], [-1.045879006, 42.718475342], [-1.046360016, 42.718299866], [-1.046622992, 42.718204498], [-1.046790004, 42.718151093], [-1.046965003, 42.71811676], [-1.047126055, 42.718097687], [-1.047261, 42.718097687], [-1.047433972, 42.718109131], [-1.047600031, 42.718139648], [-1.047868967, 42.718208313], [-1.048012972, 42.718227386], [-1.048235059, 42.718250275], [-1.048439026, 42.718261719], [-1.048485994, 42.718261719], [-1.04863596, 42.718261719], [-1.048825026, 42.718242645], [-1.049005032, 42.718215942], [-1.049198985, 42.718177795], [-1.049448013, 42.718112946], [-1.049829006, 42.717983246], [-1.050706983, 42.717685699], [-1.050953031, 42.71761322], [-1.05114603, 42.717563629], [-1.051311016, 42.717540741], [-1.051542997, 42.717517853], [-1.051787972, 42.717502594], [-1.052294016, 42.717483521], [-1.052546024, 42.717456818], [-1.052708983, 42.7174263], [-1.052943945, 42.717372894], [-1.054011941, 42.717079163], [-1.054299951, 42.717002869], [-1.054553032, 42.716934204], [-1.054720998, 42.716899872], [-1.054864049, 42.716880798], [-1.055009961, 42.716869354], [-1.055153966, 42.716861725], [-1.055320024, 42.716869354], [-1.055529952, 42.716896057], [-1.055721045, 42.716938019], [-1.055999994, 42.717018127], [-1.057788014, 42.717617035], [-1.058071017, 42.717674255], [-1.058405042, 42.717712402], [-1.058698058, 42.717704773], [-1.059015036, 42.717651367], [-1.059720039, 42.717460632], [-1.059988022, 42.717430115], [-1.060389996, 42.717430115], [-1.062073946, 42.717586517], [-1.062394977, 42.717601776], [-1.062703013, 42.717601776], [-1.062960029, 42.717556], [-1.063146949, 42.717483521], [-1.06337595, 42.717380524], [-1.063555002, 42.717243195], [-1.063693047, 42.717071533], [-1.064084053, 42.716442108], [-1.064218044, 42.7162323], [-1.064427018, 42.715808868], [-1.064504027, 42.715587616], [-1.064646006, 42.715126038], [-1.064798951, 42.714939117], [-1.064975023, 42.714832306], [-1.065220952, 42.714729309], [-1.06547296, 42.714675903], [-1.065788984, 42.714691162], [-1.066032052, 42.714752197], [-1.066265941, 42.714859009], [-1.067203999, 42.715309143], [-1.067538023, 42.715457916], [-1.067865014, 42.715572357], [-1.06803298, 42.715629578], [-1.068477035, 42.71572876], [-1.069038033, 42.715801239], [-1.070080996, 42.715938568], [-1.070960045, 42.71604538], [-1.071076035, 42.716064453]],
      }.to_json),
    ]
    after = [
      build_object(id: 1, version: 2, srid: 2154, geojson_geometry: {
        type: 'LineString',
        coordinates: [[-1.043926954, 42.718948364], [-1.043930054, 42.718891144], [-1.043956041, 42.718841553], [-1.043995976, 42.718795776], [-1.044077992, 42.718753815], [-1.044137955, 42.718738556], [-1.044232965, 42.718738556], [-1.044824004, 42.718753815], [-1.045017958, 42.718746185], [-1.045133948, 42.718730927], [-1.045251966, 42.718700409], [-1.045400977, 42.718650818], [-1.045879006, 42.718475342], [-1.046360016, 42.718299866], [-1.046622992, 42.718204498], [-1.046790004, 42.718151093], [-1.046965003, 42.71811676], [-1.047126055, 42.718097687], [-1.047261, 42.718097687], [-1.047433972, 42.718109131], [-1.047600031, 42.718139648], [-1.047868967, 42.718208313], [-1.048012972, 42.718227386], [-1.048235059, 42.718250275], [-1.048439026, 42.718261719], [-1.048485994, 42.718261719], [-1.04863596, 42.718261719], [-1.048825026, 42.718242645], [-1.049005032, 42.718215942], [-1.049198985, 42.718177795], [-1.049448013, 42.718112946], [-1.049829006, 42.717983246], [-1.050706983, 42.717685699], [-1.050953031, 42.71761322], [-1.05114603, 42.717563629], [-1.051311016, 42.717540741], [-1.051542997, 42.717517853], [-1.051787972, 42.717502594], [-1.052294016, 42.717483521], [-1.052546024, 42.717456818], [-1.052708983, 42.7174263], [-1.052943945, 42.717372894], [-1.054011941, 42.717079163], [-1.054299951, 42.717002869], [-1.054553032, 42.716934204], [-1.054720998, 42.716899872], [-1.054864049, 42.716880798], [-1.055009961, 42.716869354], [-1.055153966, 42.716861725], [-1.055320024, 42.716869354], [-1.055529952, 42.716896057], [-1.055721045, 42.716938019], [-1.055999994, 42.717018127], [-1.057788014, 42.717617035], [-1.058071017, 42.717674255], [-1.058405042, 42.717712402], [-1.058698058, 42.717704773], [-1.059015036, 42.717651367], [-1.059720039, 42.717460632], [-1.059988022, 42.717430115], [-1.060389996, 42.717430115], [-1.06103301, 42.717487335]],
      }.to_json),
      build_object(id: 2, version: 1, srid: 2154, geojson_geometry: {
        type: 'LineString',
        coordinates: [[-1.061200023, 42.717502594], [-1.062073946, 42.717586517], [-1.062394977, 42.717601776], [-1.062703013, 42.717601776], [-1.062960029, 42.717556], [-1.063146949, 42.717483521], [-1.06337595, 42.717380524], [-1.063555002, 42.717243195], [-1.063693047, 42.717071533], [-1.064084053, 42.716442108], [-1.064218044, 42.7162323], [-1.064427018, 42.715808868], [-1.064504027, 42.715587616], [-1.064646006, 42.715126038], [-1.064798951, 42.714939117], [-1.064975023, 42.714832306], [-1.065220952, 42.714729309], [-1.06547296, 42.714675903], [-1.065788984, 42.714691162], [-1.066032052, 42.714752197], [-1.066265941, 42.714859009], [-1.067203999, 42.715309143], [-1.067538023, 42.715457916], [-1.067865014, 42.715572357], [-1.06803298, 42.715629578], [-1.068477035, 42.71572876], [-1.069038033, 42.715801239], [-1.070080996, 42.715938568], [-1.070960045, 42.71604538], [-1.071076035, 42.716064453]],
      }.to_json),
      build_object(id: 3, version: 1, srid: 2154, geojson_geometry: {
        type: 'LineString',
        coordinates: [[-1.06103301, 42.717487335], [-1.061200023, 42.717502594]],
      }.to_json),
    ]

    conflations = OSMLogicalHistory::Conflation.new.conflate_with_simplification(before, after, @@demi_distance)
    assert_equal(3, conflations.size, conflations)
    assert_equal(
      [[1, 1, 1], [1, 1, 2], [1, 1, 3]].sort,
      conflations.collect(&:to_a).collect{ |t| t.collect{ |k| k&.id } }.sort
    )
  end
end
