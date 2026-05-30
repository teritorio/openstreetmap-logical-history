# frozen_string_literal: true
# typed: false

require 'sorbet-runtime'
require 'test/unit'
require_relative '../../lib/osm_logical_history/refs'


class TestRef < Test::Unit::TestCase
  extend T::Sig

  Refs = OSMLogicalHistory::Refs

  sig { void }
  def test_refs
    assert_equal(Refs.refs({}), {})
    assert_equal(Refs.refs({ 'foo' => 'b' }), {})
    assert_equal(Refs.refs({ 'ref:a' => 'a' }), { 'ref:a' => 'a' })

    assert_not_equal(Refs.refs({ 'ref:a' => 'a' }), { 'ref:a' => 'b' })
  end
end
