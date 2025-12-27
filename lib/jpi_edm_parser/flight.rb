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
    # Low bytes at indices 86/87, high bytes at indices 81/82
    GPS_LONG_INDEX = 86
    GPS_LAT_INDEX = 87
    GPS_LONG_HIGH_INDEX = 81  # High byte for longitude delta
    GPS_LAT_HIGH_INDEX = 82   # High byte for latitude delta
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

      # GPS 16-bit accumulation tracking
      # GPS uses fields 81/82 (high bytes) + 86/87 (low bytes) for 16-bit deltas
      # We track cumulative GPS values separately from standard field accumulation
      @gps_lat_cumulative = DEFAULT_VALUE
      @gps_long_cumulative = DEFAULT_VALUE

      # GPS stabilization tracking
      # GPS values during acquisition fluctuate wildly before stabilizing
      # We count consecutive stable readings and track last good position
      @gps_stable_count = 0
      @last_good_gps_lat = nil
      @last_good_gps_long = nil

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
        # Also capture raw unsigned delta bytes for GPS high/low byte fields
        new_values = Array.new(NUM_FIELDS)
        gps_raw_deltas = {}  # Capture raw bytes for GPS before sign/accumulation

        NUM_FIELDS.times do |k|
          value = previous_values[k]

          if expanded_field_flags[k] != 0
            break if offset >= data.length
            raw_byte = data.getbyte(offset)
            offset += 1

            # Save raw bytes for GPS-related fields (81=long_hi, 82=lat_hi, 86=long_lo, 87=lat_lo)
            if [GPS_LONG_HIGH_INDEX, GPS_LAT_HIGH_INDEX, GPS_LONG_INDEX, GPS_LAT_INDEX].include?(k)
              gps_raw_deltas[k] = raw_byte
            end

            diff = raw_byte
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

        # Handle GPS lat/long - these are 16-bit deltas from initial position
        # High bytes at fields 81/82 combine with low bytes at 86/87
        # The sign flag from the low byte applies to the entire 16-bit delta value
        long_lo_changed = expanded_field_flags[GPS_LONG_INDEX] != 0
        lat_lo_changed = expanded_field_flags[GPS_LAT_INDEX] != 0
        long_hi_changed = expanded_field_flags[GPS_LONG_HIGH_INDEX] != 0
        lat_hi_changed = expanded_field_flags[GPS_LAT_HIGH_INDEX] != 0

        # Compute 16-bit GPS deltas from raw bytes
        if long_lo_changed
          long_lo = gps_raw_deltas[GPS_LONG_INDEX] || 0
          long_hi = long_hi_changed ? (gps_raw_deltas[GPS_LONG_HIGH_INDEX] || 0) : 0
          long_delta = long_hi_changed ? ((long_hi << 8) | long_lo) : long_lo
          long_delta = -long_delta if expanded_sign_flags[GPS_LONG_INDEX] != 0
          @gps_long_cumulative += long_delta
        end

        if lat_lo_changed
          lat_lo = gps_raw_deltas[GPS_LAT_INDEX] || 0
          lat_hi = lat_hi_changed ? (gps_raw_deltas[GPS_LAT_HIGH_INDEX] || 0) : 0
          lat_delta = lat_hi_changed ? ((lat_hi << 8) | lat_lo) : lat_lo
          lat_delta = -lat_delta if expanded_sign_flags[GPS_LAT_INDEX] != 0
          @gps_lat_cumulative += lat_delta
        end

        process_gps_record!(record, @gps_long_cumulative, @gps_lat_cumulative,
                            long_lo_changed, lat_lo_changed)

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

        # Fuel flow scaling: JPI stores ff as gph × 10, convert to actual GPH
        apply_fuel_flow_scaling!(record)

        # Voltage scaling: JPI stores volts × 10, convert to actual volts
        apply_voltage_scaling!(record)

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

    # Fuel flow is stored as gph × 10 in JPI format, convert to actual GPH
    def apply_fuel_flow_scaling!(record)
      if record[:ff] && record[:ff] > 0
        record[:ff] = (record[:ff] / 10.0).round(1)
      end
    end

    # Voltage is stored as volts × 10 in JPI format, convert to actual volts
    def apply_voltage_scaling!(record)
      if record[:volt] && record[:volt] > 0
        record[:volt] = (record[:volt] / 10.0).round(1)
      end
    end

    def process_gps_record!(record, gps_long_value, gps_lat_value, long_changed, lat_changed)
      # GPS values are deltas from the header position, relative to a baseline value.
      # The baseline is normally DEFAULT_VALUE (240), but when values exceed 512 during
      # GPS acquisition, an additional offset must be applied:
      #   - lat baseline: 240 + 512 = 752 when lat values >= 512
      #   - long baseline: 240 + 1024 = 1264 when long values >= 512
      #
      # Formula: lat = header_lat + (gps_lat_value - lat_baseline) / 6000.0
      #          long = header_long + (gps_long_value - long_baseline) / 6000.0
      #
      # Value of 0 means no GPS data has been received yet
      # During GPS acquisition, values may fluctuate wildly before stabilizing
      # We filter by checking that position changes are reasonable

      # No header GPS = no GPS output
      unless @initial_lat && @initial_long
        record[:lat] = nil
        record[:long] = nil
        return
      end

      # Detect junk "Kansas" GPS header (39.05, -94.88) - this is a default/placeholder
      # value the EDM stores when GPS isn't properly initialized.
      @kansas_junk_header = ((@initial_lat - 39.05).abs < 0.1 && (@initial_long - (-94.88)).abs < 0.1)

      # Value of 0 means no GPS data yet
      if gps_long_value == 0 && gps_lat_value == 0
        record[:lat] = nil
        record[:long] = nil
        @gps_stable_count = 0
        @last_good_gps_long = nil
        @last_good_gps_lat = nil
        @gps_candidate_lat = nil
        @gps_candidate_long = nil
        return
      end

      # GPS values are now 16-bit cumulative values (accumulated from DEFAULT_VALUE = 240)
      # Formula: lat = header_lat + (cumulative_value - 240) / 6000.0
      lat_offset = (gps_lat_value - DEFAULT_VALUE) / 6000.0
      long_offset = (gps_long_value - DEFAULT_VALUE) / 6000.0
      lat = @initial_lat + lat_offset
      long = @initial_long + long_offset

      # GPS stability filter: require consecutive similar readings before outputting
      # This filters out junk data during GPS acquisition phase
      # We use two tracking variables:
      #   @gps_candidate_* : the previous reading we're comparing against for stability
      #   @last_good_gps_* : the last reading we actually output (for continuity check)
      max_jump = 0.02  # ~1.3 miles - max reasonable change per interval

      # For Kansas header flights, allow large jumps until we've stabilized at non-Kansas GPS
      # The Kansas position (39.05, -94.88) is a placeholder during GPS acquisition
      # Track non-Kansas output count separately from total output count
      @gps_output_count ||= 0
      @gps_non_kansas_count ||= 0

      # Current position is "Kansas-like" if it's near the header position (within ~5 degrees)
      is_kansas_position = @kansas_junk_header &&
                           (lat - 39.05).abs < 5 && (long - (-94.88)).abs < 5

      # Allow large jumps if we have Kansas header and haven't established stable non-Kansas GPS yet
      allow_large_jump = @kansas_junk_header && @gps_non_kansas_count < 50

      if @gps_candidate_lat && @gps_candidate_long
        # Compare to previous candidate reading
        lat_jump = (lat - @gps_candidate_lat).abs
        long_jump = (long - @gps_candidate_long).abs

        if !allow_large_jump && (lat_jump > max_jump || long_jump > max_jump)
          # Position jumped from candidate - junk data, start over
          @gps_stable_count = 1
          @gps_candidate_lat = lat
          @gps_candidate_long = long
          record[:lat] = nil
          record[:long] = nil
          return
        end

        # Similar to candidate (or large jump allowed during acquisition) - increment stability count
        @gps_stable_count += 1
      else
        # First reading - save as candidate
        @gps_stable_count = 1
        @gps_candidate_lat = lat
        @gps_candidate_long = long
        record[:lat] = nil
        record[:long] = nil
        return
      end

      # Require 2+ consecutive similar readings
      if @gps_stable_count < 2
        @gps_candidate_lat = lat
        @gps_candidate_long = long
        record[:lat] = nil
        record[:long] = nil
        return
      end

      # Check continuity with last output (if any) - prevent jumps after stable period
      # Only apply this check after GPS is well-established (50+ non-Kansas output records)
      # During acquisition, GPS may correct from initial junk to real position
      if !allow_large_jump && @gps_non_kansas_count >= 50 && @last_good_gps_lat && @last_good_gps_long
        lat_jump = (lat - @last_good_gps_lat).abs
        long_jump = (long - @last_good_gps_long).abs
        if lat_jump > max_jump || long_jump > max_jump
          # Jump from last output - might be re-acquiring, reset
          @gps_stable_count = 1
          @gps_candidate_lat = lat
          @gps_candidate_long = long
          record[:lat] = nil
          record[:long] = nil
          return
        end
      end

      # GPS is good - output and save
      @gps_output_count += 1
      @gps_non_kansas_count += 1 unless is_kansas_position
      @last_good_gps_lat = lat
      @last_good_gps_long = long
      @gps_candidate_lat = lat
      @gps_candidate_long = long
      record[:lat] = lat.round(6)
      record[:long] = long.round(6)
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
