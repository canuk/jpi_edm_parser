# frozen_string_literal: true

require_relative 'jpi_edm_parser/version'
require_relative 'jpi_edm_parser/header_parser'
require_relative 'jpi_edm_parser/flight'
require_relative 'jpi_edm_parser/file'

module JpiEdmParser
  class Error < StandardError; end
  class ParseError < Error; end
  class ChecksumError < Error; end
end
