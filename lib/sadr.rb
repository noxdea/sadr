# frozen_string_literal: true

require "json"
require "open3"
require "thread"
require "uri"

require_relative "sadr/version"

module Sadr
  class Error < StandardError; end
  class Timeout < Error; end

  class ServerError < Error
    attr_reader :code, :data

    def initialize(error)
      @code = error["code"]
      @data = error["data"]
      super(error["message"])
    end
  end

  module Value
    module_function

    def define(*members)
      return Data.define(*members) if defined?(Data)

      Struct.new(*members, keyword_init: true) do
        def initialize(**values)
          super
          freeze
        end
      end
    end
  end

  Position = Value.define(:line, :character)
  Range_ = Value.define(:start, :end)
  ContentChange = Value.define(:range, :text)
  Document = Value.define(:uri, :language_id, :version, :text)
  Token = Value.define(:line, :character, :length, :type, :modifiers)
  private_constant :Value

  # Text indexes are accepted by protocol conversion methods through duck typing.
  # Required methods are documented in sig/sadr.rbs.
  module TextIndex; end
end

require_relative "sadr/protocol"
require_relative "sadr/future"
require_relative "sadr/transport"
require_relative "sadr/document_sync"
require_relative "sadr/client"
