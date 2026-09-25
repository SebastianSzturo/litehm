# frozen_string_literal: true

require_relative "../test_helper"

class ValueCodecTest < Minitest::Test
  def test_round_trips_every_sqlite_storage_class_without_conflating_text_and_blob
    values = [nil, -9_223_372_036_854_775_808, 1.5, "", "\0unicode-雪", "".b, "\x00\xff".b]

    decoded = LiteHM::ValueCodec.decode_row(LiteHM::ValueCodec.encode_row(values))

    assert_equal values, decoded
    assert_equal Encoding::UTF_8, decoded[4].encoding
    assert_equal Encoding::BINARY, decoded[5].encoding
    assert_equal Encoding::BINARY, decoded[6].encoding
  end

  def test_float_encoding_preserves_negative_zero_and_infinity
    values = [-0.0, Float::INFINITY, -Float::INFINITY]
    decoded = LiteHM::ValueCodec.decode_row(LiteHM::ValueCodec.encode_row(values))

    assert_equal values.map { |value| [value].pack("G") }, decoded.map { |value| [value].pack("G") }
  end
end
