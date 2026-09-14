# frozen_string_literal: true

class TextIndex
  Point = Struct.new(:row, :column)

  def initialize(text)
    @text = text
    @starts = [0]
    text.each_byte.with_index { |byte, index| @starts << index + 1 if byte == 10 }
  end

  def line_start(row) = @starts.fetch(row)

  def line(row)
    start = line_start(row)
    @text.byteslice(start, @starts.fetch(row + 1, @text.bytesize) - start).delete_suffix("\n")
  end

  def utf16_offset_at(offset)
    @text.byteslice(0, offset).each_codepoint.sum { |codepoint| codepoint > 0xffff ? 2 : 1 }
  end

  def offset_at_utf16(target)
    units = 0
    bytes = 0
    @text.each_codepoint do |codepoint|
      return bytes if units == target

      units += codepoint > 0xffff ? 2 : 1
      bytes += codepoint.chr(Encoding::UTF_8).bytesize
      raise RangeError if units > target
    end
    raise RangeError unless units == target

    bytes
  end

  def utf16_point_at(offset)
    row = @starts.bsearch_index { |start| start > offset }
    row = row ? row - 1 : @starts.length - 1
    Point.new(row, utf16_offset_at(offset) - utf16_offset_at(line_start(row)))
  end
end
