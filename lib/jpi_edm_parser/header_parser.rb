# frozen_string_literal: true

module JpiEdmParser
  # Parses the ASCII header section of JPI files
  # 
  # The header section contains configuration and flight index information
  # in ASCII format, with each line starting with $ and ending with *XX checksum.
  class HeaderParser
    # Configuration data from $C record
    Config = Struct.new(
      :model,           # EDM model number (700, 730, 830, 900, etc.)
      :flags_low,       # Feature flags low word
      :flags_high,      # Feature flags high word  
      :unknown1,        # Unknown field
      :unknown2,        # Unknown field (extended config)
      :unknown3,        # Additional config fields
      :unknown4,
      :unknown5,
      :unknown6,
      keyword_init: true
    )

    # Alarm limits from $A record
    AlarmLimits = Struct.new(
      :volts_high,      # High voltage alarm (tenths)
      :volts_low,       # Low voltage alarm (tenths)
      :dif,             # EGT differential alarm (°F)
      :cht,             # CHT alarm (°F)
      :cld,             # Shock cooling alarm (°F/min)
      :tit,             # TIT alarm (°F)
      :oil_high,        # Oil temp high (°F)
      :oil_low,         # Oil temp low (°F)
      keyword_init: true
    )

    # Fuel configuration from $F record
    FuelConfig = Struct.new(
      :empty_warning,
      :full_capacity,
      :warning_level,
      :k_factor_1,
      :k_factor_2,
      keyword_init: true
    )

    # Flight index entry from $D record
    FlightIndex = Struct.new(
      :flight_number,   # Flight ID
      :data_words,      # Data length in 16-bit words
      keyword_init: true
    ) do
      # Get data length in bytes
      def data_length
        data_words * 2
      end
    end

    # Download timestamp from $T record
    Timestamp = Struct.new(
      :month, :day, :year, :hour, :minute, :unknown,
      keyword_init: true
    )

    attr_reader :tail_number, :config, :alarm_limits, :fuel_config
    attr_reader :flights, :timestamp, :binary_offset

    def initialize
      @flights = []
      @tail_number = nil
      @config = nil
      @alarm_limits = nil
      @fuel_config = nil
      @timestamp = nil
      @binary_offset = nil
    end

    # Parse headers from binary data
    # @param data [String] Binary file contents
    # @return [Integer] Offset where binary data begins
    def parse(data)
      pos = 0
      
      while pos < data.bytesize
        # Find next header line
        line_end = data.index("\r\n", pos)
        break unless line_end
        
        line = data[pos...line_end]
        break unless line.start_with?('$')
        
        parse_header_line(line)
        
        pos = line_end + 2
        
        # $L marks end of headers
        if line.start_with?('$L')
          @binary_offset = pos
          break
        end
      end

      raise ParseError, "No $L record found - invalid file format" unless @binary_offset
      
      @binary_offset
    end

    private

    def parse_header_line(line)
      # Verify checksum
      verify_checksum!(line)
      
      # Remove checksum suffix
      content = line.sub(/\*[0-9A-Fa-f]{2}$/, '')
      
      record_type = content[1]
      fields = content[3..].split(',').map(&:strip)
      
      case record_type
      when 'U' then parse_tail_number(fields)
      when 'A' then parse_alarm_limits(fields)
      when 'C' then parse_config(fields)
      when 'D' then parse_flight_index(fields)
      when 'F' then parse_fuel_config(fields)
      when 'T' then parse_timestamp(fields)
      when 'P', 'H', 'L'
        # Known but not yet parsed
      else
        # Unknown record type - ignore
      end
    end

    def verify_checksum!(line)
      return unless line.include?('*')
      
      content = line[1...line.index('*')]
      expected = line[line.index('*') + 1, 2].to_i(16)
      
      calculated = content.bytes.reduce(0) { |xor, byte| xor ^ byte }
      
      unless calculated == expected
        raise ChecksumError, "Header checksum mismatch: expected #{expected.to_s(16)}, got #{calculated.to_s(16)}"
      end
    end

    def parse_tail_number(fields)
      @tail_number = fields.join(',').sub(/\*.*$/, '').strip
    end

    def parse_alarm_limits(fields)
      @alarm_limits = AlarmLimits.new(
        volts_high: fields[0].to_i,
        volts_low: fields[1].to_i,
        dif: fields[2].to_i,
        cht: fields[3].to_i,
        cld: fields[4].to_i,
        tit: fields[5].to_i,
        oil_high: fields[6].to_i,
        oil_low: fields[7].to_i
      )
    end

    def parse_config(fields)
      @config = Config.new(
        model: fields[0].to_i,
        flags_low: fields[1].to_i,
        flags_high: fields[2].to_i,
        unknown1: fields[3]&.to_i,
        unknown2: fields[4]&.to_i,
        unknown3: fields[5]&.to_i,
        unknown4: fields[6]&.to_i,
        unknown5: fields[7]&.to_i,
        unknown6: fields[8]&.to_i
      )
    end

    def parse_flight_index(fields)
      @flights << FlightIndex.new(
        flight_number: fields[0].to_i,
        data_words: fields[1].to_i
      )
    end

    def parse_fuel_config(fields)
      @fuel_config = FuelConfig.new(
        empty_warning: fields[0].to_i,
        full_capacity: fields[1].to_i,
        warning_level: fields[2].to_i,
        k_factor_1: fields[3].to_i,
        k_factor_2: fields[4].to_i
      )
    end

    def parse_timestamp(fields)
      @timestamp = Timestamp.new(
        month: fields[0].to_i,
        day: fields[1].to_i,
        year: fields[2].to_i,
        hour: fields[3].to_i,
        minute: fields[4].to_i,
        unknown: fields[5]&.to_i
      )
    end
  end
end
