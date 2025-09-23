# frozen_string_literal: true
# typed: strict

require 'sorbet-runtime'
require 'test/unit'
require 'json'
require 'active_support/all'
require './overpass/overpass_logical_history'

Conflation = LogicalHistory::Conflation
OSMObject = LogicalHistory::OSMObject

class TestConflationReal < Test::Unit::TestCase
  extend T::Sig

  @@demi_distance = T.let(100.0, Float) # m
  @@srid = T.let(2154, Integer)

  sig { void }
  def test_building
    # [out:xml][timeout:25][adiff:"2024-12-10T00:00:00.00Z","2024-12-15T00:00:00.00Z"];
    # (
    #   way(756231553);
    #   way(1342109813);
    # );
    # out meta geom;
    xml = '
    <osm version="0.6" generator="openstreetmap-cgimap 2.1.0 (1060541 spike-06.openstreetmap.org)" copyright="OpenStreetMap and contributors" attribution="http://www.openstreetmap.org/copyright" license="http://opendatacommons.org/licenses/odbl/1-0/">
    <action type="delete">
    <old>
      <way id="756231553" visible="true" version="1" changeset="78525508" timestamp="2019-12-17T12:02:03Z" user="Etzharai" uid="3771138">
        <nd ref="7063168425" lat="42.6862569" lon="-1.6527141"/>
        <nd ref="7063168426" lat="42.6862020" lon="-1.6525740"/>
        <nd ref="7063168427" lat="42.6860956" lon="-1.6526394"/>
        <nd ref="7063168428" lat="42.6861265" lon="-1.6527047"/>
        <nd ref="7063168429" lat="42.6861608" lon="-1.6526814"/>
        <nd ref="7063168430" lat="42.6861849" lon="-1.6527374"/>
        <nd ref="7063168425" lat="42.6862569" lon="-1.6527141"/>
        <tag k="building" v="yes"/>
      </way>
    </old>
    <new>
      <way id="756231553" visible="false" version="2" timestamp="2024-12-12T13:43:47Z" changeset="160208663" uid="3771138" user="Etzharai"/>
    </new>
    </action>
    <action type="create">
      <way id="1342109813" version="1" timestamp="2024-12-12T13:43:47Z" changeset="160208663" uid="3771138" user="Etzharai">
        <nd ref="12416010721" lat="42.6862363" lon="-1.6526962"/>
        <nd ref="12416011073" lat="42.6862154" lon="-1.6526387"/>
        <nd ref="12416010722" lat="42.6861917" lon="-1.6525733"/>
        <nd ref="12416010723" lat="42.6860959" lon="-1.6526377"/>
        <nd ref="12416010724" lat="42.6861179" lon="-1.6526983"/>
        <nd ref="12416010725" lat="42.6861520" lon="-1.6526754"/>
        <nd ref="12416010726" lat="42.6861746" lon="-1.6527376"/>
        <nd ref="12416010721" lat="42.6862363" lon="-1.6526962"/>
        <tag k="addr:city" v="Campanas/Arrizabalaga"/>
        <tag k="addr:housenumber" v="9"/>
        <tag k="addr:postcode" v="31398"/>
        <tag k="addr:street" v="Calle Artearraga"/>
        <tag k="building" v="house"/>
      </way>
      </action>
    </osm>
    '

    data_start, data_end = OverspassLogicalHistory.parse_xml(xml)
    data_start = OverspassLogicalHistory.overpass_to_geojson(data_start, @@srid)
    data_end = OverspassLogicalHistory.overpass_to_geojson(data_end, @@srid)

    conf = Conflation.conflate(data_start, data_end, @@demi_distance)

    assert_equal 1, conf.size, conf.inspect
  end
end
