# frozen_string_literal: true

module Sadr
  module Protocol
    module_function

    def uri(path)
      raise Error, "path must be a String" unless path.is_a?(String) && !path.include?("\0")

      absolute = File.expand_path(path).tr("\\", "/")
      absolute = "/#{absolute}" if absolute.match?(/\A[A-Za-z]:/)
      "file://" + percent_encode(absolute)
    end

    def path(uri)
      parsed = URI::DEFAULT_PARSER.parse(uri)
      valid = parsed.scheme == "file" && [nil, "", "localhost"].include?(parsed.host) &&
        parsed.query.nil? && parsed.fragment.nil? && parsed.path&.start_with?("/")
      raise Error, "expected local file URI" unless valid

      value = percent_decode(parsed.path)
      raise Error, "invalid file URI path" if value.include?("\0") || !value.valid_encoding?

      RUBY_PLATFORM.match?(/mswin|mingw/) ? value.sub(%r{\A/([A-Za-z]:/)}, '\\1') : value
    rescue URI::InvalidURIError => error
      raise Error, error.message
    end

    def position(index, offset)
      point = index.utf16_point_at(offset)
      Position.new(line: point.row, character: point.column)
    rescue NoMethodError => error
      raise Error, "invalid text index: #{error.message}"
    end

    def offset(index, position)
      point = position_value(position)
      start = index.line_start(point.line)
      finish = start + index.line(point.line).bytesize
      units = index.utf16_offset_at(finish) - index.utf16_offset_at(start)
      index.offset_at_utf16(index.utf16_offset_at(start) + [point.character, units].min)
    rescue NoMethodError => error
      raise Error, "invalid text index: #{error.message}"
    end

    def range(index, byte_range)
      raise Error, "invalid byte range" unless byte_range.is_a?(Range) && byte_range.begin.is_a?(Integer) && byte_range.end.is_a?(Integer)

      finish = byte_range.end + (byte_range.exclude_end? ? 0 : 1)
      Range_.new(start: position(index, byte_range.begin), end: position(index, finish))
    end

    def text_edits(index, edits)
      raise Error, "invalid LSP text edits" unless edits.is_a?(Array)

      edits.map do |edit|
        valid = edit.is_a?(Hash) && fetch(edit, "range").is_a?(Hash) && fetch(edit, "newText").is_a?(String)
        raise Error, "invalid LSP text edit" unless valid && fetch(edit, "newText").valid_encoding?

        value = fetch(edit, "range")
        first = offset(index, fetch(value, "start"))
        last = offset(index, fetch(value, "end"))
        raise Error, "invalid LSP text edit range" if last < first

        [first...last, fetch(edit, "newText")]
      end
    end

    def semantic_delta(data, edits)
      raise Error, "invalid semantic token delta" unless data.is_a?(Array) && edits.is_a?(Array)

      edits.each do |edit|
        valid = edit.is_a?(Hash) && uint?(fetch(edit, "start")) && uint?(fetch(edit, "deleteCount"))
        inserted = fetch(edit, "data", [])
        raise Error, "invalid semantic token delta" unless valid && inserted.is_a?(Array)
      end
      previous_end = 0
      previous_start = nil
      edits.each do |edit|
        start = fetch(edit, "start")
        count = fetch(edit, "deleteCount")
        duplicate = previous_start && start == previous_start
        raise Error, "invalid semantic token delta" if duplicate || start < previous_end || start + count > data.length

        previous_start = start
        previous_end = start + count
      end
      output = data.dup
      edits.reverse_each do |edit|
        output[fetch(edit, "start"), fetch(edit, "deleteCount")] = fetch(edit, "data", [])
      end
      scan_semantic(output, nil, false)
      output
    end

    def diagnostics(values)
      valid = values.is_a?(Array) && values.all? do |value|
        next false unless value.is_a?(Hash) && fetch(value, "message").is_a?(String) && fetch(value, "range").is_a?(Hash)

        range = fetch(value, "range")
        points = %w[start end].map { |key| fetch(range, key, nil) }
        severity = fetch(value, "severity", nil)
        has_severity = value.key?("severity") || value.key?(:severity)
        points.all? { |point| valid_position?(point) } &&
          (position_tuple(points[0]) <=> position_tuple(points[1])) <= 0 &&
          (!has_severity || (severity.is_a?(Integer) && severity.between?(1, 4)))
      end
      raise Error, "invalid LSP diagnostics" unless valid

      values
    end

    def workspace_edit(value)
      raise Error, "invalid workspace edit" unless value.is_a?(Hash)

      changes = fetch(value, "changes", nil)
      if value.key?("changes") || value.key?(:changes)
        raise Error, "invalid workspace edit changes" unless changes.is_a?(Hash)

        changes.each do |uri, edits|
          validate_uri(uri)
          validate_text_edits(edits)
        end
      end
      document_changes = fetch(value, "documentChanges", nil)
      if value.key?("documentChanges") || value.key?(:documentChanges)
        raise Error, "invalid workspace document changes" unless document_changes.is_a?(Array)

        document_changes.each { |change| validate_document_change(change) }
      end
      value
    rescue KeyError
      raise Error, "invalid workspace edit"
    end

    def semantic_tokens(data, legend: nil)
      scan_semantic(data, legend, true)
    end

    def scan_semantic(data, legend, collect)
      raise Error, "invalid semantic token tuple count" unless data.is_a?(Array) && (data.length % 5).zero?
      if legend
        valid = legend.is_a?(Hash) && %w[tokenTypes tokenModifiers].all? do |key|
          value = fetch(legend, key)
          value.is_a?(Array) && value.all? { |name| name.is_a?(String) }
        end
        raise Error, "invalid semantic token legend" unless valid
      end

      unless data.empty?
        total = data.sum
        minimum, maximum = data.minmax
        valid = total.is_a?(Integer) && minimum.is_a?(Integer) && maximum.is_a?(Integer) &&
          minimum >= 0 && maximum <= 0x7fffffff
        raise Error, "invalid semantic token value" unless valid
      end
      unless collect || legend
        row = 0
        column = 0
        index = 2
        size = data.length
        while index < size
          length = data[index]
          delta_row = data[index - 2]
          delta_column = data[index - 1]
          raise Error, "invalid semantic token value" if length.zero?

          row += delta_row
          column = delta_row.zero? ? column + delta_column : delta_column
          raise Error, "semantic token position overflow" if column + length > 0x7fffffff

          index += 5
        end
        raise Error, "semantic token position overflow" if row > 0x7fffffff

        return nil
      end
      row = 0
      column = 0
      tokens = collect ? Array.new(data.length / 5) : nil
      index = 0
      while index < data.length
        delta_row = data[index]
        delta_column = data[index + 1]
        length = data[index + 2]
        type = data[index + 3]
        modifiers = data[index + 4]
        raise Error, "invalid semantic token value" unless length.positive?
        if legend
          types = fetch(legend, "tokenTypes")
          token_modifiers = fetch(legend, "tokenModifiers")
          raise Error, "semantic token exceeds legend" if type >= types.length || modifiers.bit_length > token_modifiers.length
        end

        row += delta_row
        column = delta_row.zero? ? column + delta_column : delta_column
        raise Error, "semantic token position overflow" if row > 0x7fffffff || column + length > 0x7fffffff

        tokens[index / 5] = Token.new(line: row, character: column, length: length, type: type, modifiers: modifiers) if collect
        index += 5
      end
      tokens
    rescue TypeError, ArgumentError
      raise Error, "invalid semantic token value"
    end

    def uint?(value)
      value.is_a?(Integer) && value.between?(0, 0x7fffffff)
    end

    def position_value(value)
      return value if value.is_a?(Position) && uint?(value.line) && uint?(value.character)
      return Position.new(line: fetch(value, "line"), character: fetch(value, "character")) if valid_position?(value)

      raise Error, "invalid LSP position"
    end

    def range_value(value)
      if value.is_a?(Range_)
        valid = (position_tuple(value.start) <=> position_tuple(value.end)) <= 0
        return Range_.new(start: position_value(value.start), end: position_value(value.end)) if valid
      elsif value.is_a?(Hash)
        first = position_value(fetch(value, "start"))
        last = position_value(fetch(value, "end"))
        return Range_.new(start: first, end: last) if (position_tuple(first) <=> position_tuple(last)) <= 0
      end
      raise Error, "invalid LSP range"
    rescue KeyError
      raise Error, "invalid LSP range"
    end

    def position_hash(value)
      point = position_value(value)
      {line: point.line, character: point.character}
    end

    def range_hash(value)
      value = range_value(value)
      {start: position_hash(value.start), end: position_hash(value.end)}
    end

    def validate_text_edits(edits)
      raise Error, "invalid LSP text edits" unless edits.is_a?(Array)

      edits.each do |edit|
        valid = edit.is_a?(Hash) && fetch(edit, "newText", nil).is_a?(String) && fetch(edit, "newText").valid_encoding?
        raise Error, "invalid LSP text edit" unless valid

        range_value(fetch(edit, "range"))
      end
    end

    def validate_document_change(change)
      raise Error, "invalid workspace document change" unless change.is_a?(Hash)

      kind = fetch(change, "kind", nil)
      case kind
      when "create", "delete"
        validate_uri(fetch(change, "uri"))
      when "rename"
        validate_uri(fetch(change, "oldUri"))
        validate_uri(fetch(change, "newUri"))
      when nil
        document = fetch(change, "textDocument", nil)
        raise Error, "invalid workspace text document" unless document.is_a?(Hash)

        validate_uri(fetch(document, "uri"))
        unless document.key?("version") || document.key?(:version)
          raise Error, "invalid workspace document version"
        end
        version = fetch(document, "version", nil)
        valid_version = version.nil? || (version.is_a?(Integer) && version.between?(-0x80000000, 0x7fffffff))
        raise Error, "invalid workspace document version" unless valid_version
        validate_text_edits(fetch(change, "edits"))
      else
        raise Error, "unknown workspace resource operation"
      end
      options = fetch(change, "options", nil)
      raise Error, "invalid workspace resource options" if options && !options.is_a?(Hash)
    rescue KeyError
      raise Error, "invalid workspace document change"
    end

    def validate_uri(value)
      valid = value.is_a?(String) && !value.empty? && value.valid_encoding? && !value.include?("\0")
      parsed = URI::DEFAULT_PARSER.parse(value) if valid
      raise Error, "invalid URI" unless valid && parsed&.scheme && !parsed.scheme.empty?

      value
    rescue URI::InvalidURIError
      raise Error, "invalid URI"
    end

    def percent_encode(value)
      value.b.each_byte.map do |byte|
        character = byte.chr
        character.match?(/[a-zA-Z0-9\-._~\/:]/) ? character : format("%%%02X", byte)
      end.join
    end

    def percent_decode(value)
      raise Error, "invalid file URI path" if value.match?(/%(?![0-9A-Fa-f]{2})/)

      value.b.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).to_i(16).chr }.force_encoding(Encoding::UTF_8)
    end

    def valid_position?(value)
      value.is_a?(Hash) && uint?(fetch(value, "line")) && uint?(fetch(value, "character"))
    end

    def position_tuple(value)
      point = value.is_a?(Position) ? value : position_value(value)
      [point.line, point.character]
    end

    def fetch(hash, key, default = :__missing__)
      return hash[key] if hash.key?(key)
      symbol = key.to_sym
      return hash[symbol] if hash.key?(symbol)
      return default unless default == :__missing__

      raise KeyError, "key not found: #{key}"
    end

    private_class_method :scan_semantic, :validate_text_edits, :validate_document_change, :validate_uri, :percent_encode, :percent_decode,
      :valid_position?, :position_tuple, :fetch
  end
end
