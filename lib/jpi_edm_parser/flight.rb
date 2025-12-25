# frozen_string_literal: true

require 'date'

module JpiEdmParser
  # Represents a single flight's data from a JPI file
  class Flight
    # Field index mapping - derived from format documentation
    # Some fields use two indices: [low_byte, high_byte]
    FIELD_LABELS = {
      # EGT fields: low byte + high byte (indices 0-5 and 48-53)
      egt1: [0, 48], egt2: [1, 49], egt3: [2, 50],
      egt4: [3, 51], egt5: [4, 52], egt6: [5, 53],
      # CHT fields (single byte each)
      cht1: 8, cht2: 9, cht3: 10, cht4: 11, cht5: 12, cht6: 13,
      # Engine parameters
      cld: 14, oil_t: 15, mark: 16, oil_p: 17, crb: 18,
      volt: 20, oat: 21, usd: 22, ff: 23, hp: 30,
      map: 40, rpm: [41, 42],
      # Hobbs time
      hours: [78, 79],
      # GPS fields (when GPS is connected to EDM)
      # Note: lat/long are handled specially - values are deltas from header
      alt: 83,              # Altitude (feet)
      gspd: 85              # Ground speed (knots)
      # Indices 86 (long delta) and 87 (lat delta) handled separately
    }.freeze

    # GPS field indices - these are deltas from initial position in header
    GPS_LONG_INDEX = 86
    GPS_LAT_INDEX = 87
    GPS_INIT_VALUE = 100  # Value that signals GPS is initialized

    NUM_FIELDS = 128
    DEFAULT_VALUE = 0xF0
    FLIGHT_HEADER_SIZE = 28  # 14 x 16-bit words

    attr_reader :flight_number, :date, :flags, :interval_secs, :records, :index_entry,
                :temperature_unit, :parse_warnings, :initial_lat, :initial_long

    def initialize(index_entry:, data:, binary_offset:, config:, temperature_unit: :original)
      @index_entry = index_entry
      @data = data
      @binary_offset = binary_offset
      @config = config
      @temperature_unit = temperature_unit
      @records = []
      @flight_number = index_entry.flight_number
      @data_length = index_entry.data_length
      @parse_warnings = []
      @initial_lat = nil
      @initial_long = nil
      @gps_initialized = false
    end

    # Parse the flight data
    def parse
      # Find the start of this flight's data
      @flight_start = find_flight_start
      unless @flight_start
        @parse_warnings << "Could not locate flight data start marker"
        return self
      end

      @raw_data = @data[@flight_start, @data_length]
      unless @raw_data && @raw_data.length >= FLIGHT_HEADER_SIZE
        @parse_warnings << "Flight data too short (#{@raw_data&.length || 0} bytes, need #{FLIGHT_HEADER_SIZE})"
        return self
      end

      parse_flight_header
      parse_data_records
      self
    rescue StandardError => e
      @parse_warnings << "Parse error: #{e.message}"
      self
    end

    # Get start date/time as Time object
    def start_time
      @date
    end

    # Get recording interval in seconds (defaults to 6 if not set or invalid)
    def interval
      (@interval_secs.nil? || @interval_secs <= 0) ? 6 : @interval_secs
    end

    # Calculate flight duration in hours
    def duration_hours
      return 0 if @records.empty?
      (@records.length * interval) / 3600.0
    end

    # Returns true if flight has valid, parseable data
    def valid?
      @date && !@records.empty?
    end

    # Returns true if flight has no data records
    def empty?
      @records.empty?
    end

    # Returns true if there were any warnings during parsing
    def warnings?
      !@parse_warnings.empty?
    end

    # Returns true if flight has GPS data
    def has_gps?
      @records.any? { |r| (r[:lat] || 0) != 0 || (r[:long] || 0) != 0 }
    end

    # Export flight data to CSV
    def to_csv(filename = nil)
      csv_data = generate_csv

      if filename
        ::File.write(filename, csv_data)
      end

      csv_data
    end

    private

    def find_flight_start
      # Find the flight by searching for its flight number in big-endian
      flight_num_bytes = [@flight_number].pack('n')

      # Start searching from binary_offset
      pos = @binary_offset
      
      # The flight data should be sequential, but we search to be safe
      while pos < @data.length - FLIGHT_HEADER_SIZE
        if @data[pos, 2] == flight_num_bytes
          return pos
        end
        pos += 1
      end

      nil
    end

    def parse_flight_header
      # Flight header: 14 x 16-bit words, big-endian
      words = @raw_data[0, FLIGHT_HEADER_SIZE].unpack('n14')

      @flight_number_check = words[0]
      @flags = words[1] | (words[2] << 16)

      # words[3..10] are unknown/config values
      # For EDM-900+ with extended format, GPS coordinates are stored in:
      #   words[6..7] = latitude (high, low) as 32-bit signed, divide by 6000 for degrees
      #   words[8..9] = longitude (high, low) as 32-bit signed, divide by 6000 for degrees
      parse_initial_gps(words)

      @interval_secs = words[11]

      # Date: day:5, month:4, year:7
      date_bits = words[12]
      day = date_bits & 0x1F
      month = (date_bits >> 5) & 0x0F
      year = ((date_bits >> 9) & 0x7F) + 2000

      # Time: secs:5 (stored as secs/2), mins:6, hrs:5
      time_bits = words[13]
      secs = (time_bits & 0x1F) * 2
      mins = (time_bits >> 5) & 0x3F
      hrs = (time_bits >> 11) & 0x1F

      begin
        @date = DateTime.new(year, month, day, hrs, mins, secs)
      rescue ArgumentError => e
        @date = nil
        @parse_warnings << "Invalid date/time in flight header: #{e.message}"
      end

      if @interval_secs.nil? || @interval_secs <= 0
        @parse_warnings << "Invalid recording interval (#{@interval_secs}), using default of 6 seconds"
      end
    end

    def parse_initial_gps(words)
      # GPS coordinates stored as 32-bit signed integers
      # Combine high and low words, then divide by 6000 for decimal degrees
      lat_raw = (words[6] << 16) | words[7]
      long_raw = (words[8] << 16) | words[9]

      # Convert to signed 32-bit
      lat_raw = lat_raw > 0x7FFFFFFF ? lat_raw - 0x100000000 : lat_raw
      long_raw = long_raw > 0x7FFFFFFF ? long_raw - 0x100000000 : long_raw

      # Only set if values look valid (non-zero and reasonable range)
      if lat_raw != 0 && long_raw != 0
        lat_deg = lat_raw / 6000.0
        long_deg = long_raw / 6000.0

        # Sanity check: valid lat is -90 to 90, valid long is -180 to 180
        if lat_deg.abs <= 90 && long_deg.abs <= 180
          @initial_lat = lat_deg
          @initial_long = long_deg
        end
      end
    end

    def parse_data_records
      data = @raw_data[FLIGHT_HEADER_SIZE..-1]
      if data.nil? || data.empty?
        @parse_warnings << "No data records present after flight header"
        return
      end

      # Initialize default values
      default_values = Array.new(NUM_FIELDS, DEFAULT_VALUE)
      default_values[FIELD_LABELS[:hp]] = 0 if FIELD_LABELS[:hp]

      # High bytes default to 0
      FIELD_LABELS.each do |_key, index|
        if index.is_a?(Array)
          default_values[index[1]] = 0
        end
      end

      previous_values = Array.new(NUM_FIELDS)
      current_date = @date
      gspd_bug = true
      offset = 0

      # GPS tracking - accumulate deltas from initial position
      # GPS values in data are deltas in units of 1/6000 degree
      @gps_lat_raw = @initial_lat ? (@initial_lat * 6000).round : 0
      @gps_long_raw = @initial_long ? (@initial_long * 6000).round : 0
      previous_gps_long = nil
      previous_gps_lat = nil

      while offset < data.length - 5
        # Skip 1 unknown byte
        offset += 1
        break if offset + 4 > data.length

        # Read 2x16-bit decode_flags (should be equal)
        decode_flags1 = data[offset, 2].unpack1('n')
        decode_flags2 = data[offset + 2, 2].unpack1('n')
        offset += 4

        break if offset >= data.length

        # Read repeat count
        repeat_count = data.getbyte(offset)
        offset += 1

        # Validate decode flags match
        unless decode_flags1 == decode_flags2
          if @records.empty?
            @parse_warnings << "Decode flags mismatch at start of data (0x#{decode_flags1.to_s(16)} vs 0x#{decode_flags2.to_s(16)})"
          end
          break
        end

        decode_flags = decode_flags1

        # Handle repeat count
        repeat_count.times do
          if current_date
            current_date = current_date + Rational(@interval_secs, 86400)
          end
        end

        # Read field flags for each bit set in decode_flags
        field_flags = Array.new(16, 0)
        sign_flags = Array.new(16, 0)

        16.times do |i|
          if (decode_flags & (1 << i)) != 0
            break if offset >= data.length
            field_flags[i] = data.getbyte(offset)
            offset += 1
          end
        end

        16.times do |i|
          # Skip sign flags for bits 6 and 7
          if (decode_flags & (1 << i)) != 0 && i != 6 && i != 7
            break if offset >= data.length
            sign_flags[i] = data.getbyte(offset)
            offset += 1
          end
        end

        # Expand to 128-bit arrays
        expanded_field_flags = Array.new(NUM_FIELDS, 0)
        expanded_sign_flags = Array.new(NUM_FIELDS, 0)

        field_flags.each_with_index do |byte, i|
          8.times do |bit|
            expanded_field_flags[i * 8 + bit] = (byte & (1 << bit)) != 0 ? 1 : 0
          end
        end

        sign_flags.each_with_index do |byte, i|
          8.times do |bit|
            expanded_sign_flags[i * 8 + bit] = (byte & (1 << bit)) != 0 ? 1 : 0
          end
        end

        # Copy sign flags for high bytes from low bytes
        FIELD_LABELS.each do |_key, index|
          if index.is_a?(Array)
            expanded_sign_flags[index[1]] = expanded_sign_flags[index[0]]
          end
        end

        # Read and calculate values
        new_values = Array.new(NUM_FIELDS)

        NUM_FIELDS.times do |k|
          value = previous_values[k]

          if expanded_field_flags[k] != 0
            break if offset >= data.length
            diff = data.getbyte(offset)
            offset += 1

            diff = -diff if expanded_sign_flags[k] != 0

            if value.nil? && diff == 0
              # Skip - no change from nil
            else
              value = default_values[k] if value.nil?
              value += diff
              previous_values[k] = value
            end
          end

          new_values[k] = value || 0
        end

        # Build record from field mapping
        record = { date: current_date }

        FIELD_LABELS.each do |key, index|
          if index.is_a?(Array)
            low = new_values[index[0]]
            high = new_values[index[1]]
            record[key] = low + (high << 8)
          else
            record[key] = new_values[index]
          end
        end

        # Handle GPS lat/long - these are deltas from initial position
        # We need to track the raw deltas for GPS initialization detection
        long_delta_raw = expanded_field_flags[GPS_LONG_INDEX] != 0 ?
                         (new_values[GPS_LONG_INDEX] - (previous_gps_long || DEFAULT_VALUE)) : 0
        lat_delta_raw = expanded_field_flags[GPS_LAT_INDEX] != 0 ?
                        (new_values[GPS_LAT_INDEX] - (previous_gps_lat || DEFAULT_VALUE)) : 0
        previous_gps_long = new_values[GPS_LONG_INDEX]
        previous_gps_lat = new_values[GPS_LAT_INDEX]

        process_gps_record!(record, long_delta_raw.abs, lat_delta_raw.abs, expanded_sign_flags)

        # GSPD bug workaround (stuck at 150 when no GPS)
        if record[:gspd] == 150 && gspd_bug
          record[:gspd] = 0
        elsif record[:gspd] && record[:gspd] > 0
          gspd_bug = false
        end

        # Clamp negative GSPD
        record[:gspd] = 0 if record[:gspd] && record[:gspd] < 0

        # Temperature conversion based on configured output unit
        apply_temperature_conversion!(record)

        @records << record

        if current_date
          current_date = current_date + Rational(@interval_secs, 86400)
        end
      end
    end

    def fahrenheit?
      # Bit 28 indicates Fahrenheit (1=F, 0=C)
      (@flags >> 28) & 1 == 1
    end

    def apply_temperature_conversion!(record)
      case @temperature_unit
      when :original
        # Keep original units - no conversion
      when :celsius
        convert_temps_to_celsius!(record) if fahrenheit?
      when :fahrenheit
        convert_temps_to_fahrenheit!(record) unless fahrenheit?
      end
    end

    TEMP_FIELDS = %i[egt1 egt2 egt3 egt4 egt5 egt6
                     cht1 cht2 cht3 cht4 cht5 cht6
                     crb cld oil_t oat].freeze

    def convert_temps_to_celsius!(record)
      TEMP_FIELDS.each do |field|
        if record[field] && record[field] != 0
          record[field] = fahrenheit_to_celsius(record[field])
        end
      end
    end

    def convert_temps_to_fahrenheit!(record)
      TEMP_FIELDS.each do |field|
        if record[field] && record[field] != 0
          record[field] = celsius_to_fahrenheit(record[field])
        end
      end
    end

    def fahrenheit_to_celsius(temp)
      ((temp - 32) * 5.0 / 9.0).round(1)
    end

    def celsius_to_fahrenheit(temp)
      ((temp * 9.0 / 5.0) + 32).round(1)
    end

    def process_gps_record!(record, long_delta_abs, lat_delta_abs, sign_flags)
      # Check for GPS initialization signal (both deltas are 100)
      # Per docs: when GPS is detected, both elements are set to 100
      if !@gps_initialized && long_delta_abs == GPS_INIT_VALUE && lat_delta_abs == GPS_INIT_VALUE
        @gps_initialized = true
        # Initial position is already set from header
        record[:lat] = @initial_lat
        record[:long] = @initial_long
        return
      end

      if @gps_initialized && @initial_lat && @initial_long
        # Apply deltas - these are in units of 1/6000 degree
        # After initialization, deltas modify the position
        # Sign flags indicate whether to add or subtract
        if long_delta_abs != 0 && long_delta_abs != GPS_INIT_VALUE
          long_delta = sign_flags[GPS_LONG_INDEX] != 0 ? -long_delta_abs : long_delta_abs
          @gps_long_raw += long_delta
        end
        if lat_delta_abs != 0 && lat_delta_abs != GPS_INIT_VALUE
          lat_delta = sign_flags[GPS_LAT_INDEX] != 0 ? -lat_delta_abs : lat_delta_abs
          @gps_lat_raw += lat_delta
        end

        record[:lat] = @gps_lat_raw / 6000.0
        record[:long] = @gps_long_raw / 6000.0
      else
        # No GPS data
        record[:lat] = nil
        record[:long] = nil
      end
    end

    def generate_csv
      headers = [:date] + FIELD_LABELS.keys + [:lat, :long]
      lines = [headers.map { |h| h.to_s.upcase }.join(',')]

      @records.each do |record|
        row = headers.map do |h|
          val = record[h]
          if val.is_a?(DateTime)
            val.strftime('%Y-%m-%d %H:%M:%S')
          else
            val.to_s
          end
        end
        lines << row.join(',')
      end

      lines.join("\n") + "\n"
    end
  end
end
