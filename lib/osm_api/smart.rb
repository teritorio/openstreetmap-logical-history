# frozen_string_literal: true
# typed: strict

require 'async'
require 'sorbet-runtime'
require 'net/http'
require 'uri'
require 'json'
require 'active_support/all'
require_relative '../osm_logical_history/conflation'
require_relative 'osm_source'
require_relative 'ohsome'
require_relative 'overpass'


class Smart < OSMSource
  extend T::Sig

  sig {
    params(
      bbox: [Float, Float, Float, Float],
      selector: String,
      date_start: String,
      date_end: String,
      srid: Integer,
      demi_distance: Float
    ).returns(T::Array[[
      T::Hash[Integer, OSMLogicalHistory::OSMObject],
      T::Array[T::Hash[Symbol, T.untyped]]
    ]])
  }
  def self.struct(bbox, selector, date_start, date_end, srid, demi_distance)
    Ohsome.struct(bbox, selector, date_start, date_end, srid, demi_distance)
  rescue StandardError => e
    puts "Ohsome failed with #{e.message}, fallback to Overpass"
    Overpass.struct(bbox, selector, date_start, date_end, srid, demi_distance)
  end
end
