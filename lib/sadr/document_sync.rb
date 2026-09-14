# frozen_string_literal: true

module Sadr
  class DocumentIndex
    Point = Struct.new(:row, :column)
    BREAK = /(?:\r\n|[\r\n\u2028\u2029])\z/

    def initialize(text)
      @text = text
      @line_starts = [0]
      offset = 0
      previous_cr = false
      text.each_char do |character|
        offset += character.bytesize
        case character
        when "\r"
          @line_starts << offset
        when "\n"
          previous_cr ? @line_starts[-1] = offset : @line_starts << offset
        when "\u2028", "\u2029"
          @line_starts << offset
        end
        previous_cr = character == "\r"
      end
    end

    def line_start(row)
      @line_starts.fetch(row)
    rescue IndexError
      raise RangeError, "line out of bounds"
    end

    def line(row)
      start = line_start(row)
      finish = @line_starts.fetch(row + 1, @text.bytesize)
      @text.byteslice(start, finish - start).sub(BREAK, "")
    end

    def utf16_offset_at(byte_offset)
      prefix = prefix_at(byte_offset)
      prefix.each_codepoint.sum { |codepoint| codepoint > 0xffff ? 2 : 1 }
    end

    def offset_at_utf16(utf16_offset)
      raise RangeError, "UTF-16 offset out of bounds" unless utf16_offset.is_a?(Integer) && utf16_offset >= 0

      units = 0
      bytes = 0
      @text.each_codepoint do |codepoint|
        return bytes if units == utf16_offset

        units += codepoint > 0xffff ? 2 : 1
        bytes += codepoint.chr(Encoding::UTF_8).bytesize
        raise RangeError, "UTF-16 offset splits a surrogate pair" if units > utf16_offset
      end
      return bytes if units == utf16_offset

      raise RangeError, "UTF-16 offset out of bounds"
    end

    def utf16_point_at(byte_offset)
      prefix_at(byte_offset)
      row = @line_starts.bsearch_index { |start| start > byte_offset }
      row = row ? row - 1 : @line_starts.length - 1
      Point.new(row, utf16_offset_at(byte_offset) - utf16_offset_at(line_start(row)))
    end

    private

    def prefix_at(byte_offset)
      raise RangeError, "byte offset out of bounds" unless byte_offset.is_a?(Integer) && byte_offset.between?(0, @text.bytesize)

      prefix = @text.byteslice(0, byte_offset)
      raise RangeError, "byte offset splits a character" unless prefix.valid_encoding?

      prefix
    end
  end
  private_constant :DocumentIndex
end
