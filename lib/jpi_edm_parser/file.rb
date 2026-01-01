# frozen_string_literal: true

module JpiEdmParser
  # Main class for reading and parsing JPI EDM files
  #
  # @example List flights in a file
  #   file = JpiEdmParser::File.new('path/to/file.jpi')
  #   file.flights.each do |flight|
  #     puts "Flight ##{flight.number}"
  #   end
  #
  # @example Get a specific flight
  #   flight = file.flight(1196)
  #   puts flight.duration_hours
  #
  class File
    attr_reader :path, :header_parser, :temperature_unit

    # @param path [String] Path to the JPI file
    # @param temperature_unit [Symbol] Temperature output unit:
    #   - :original (default) - keep original units from the file
    #   - :fahrenheit - convert to Fahrenheit if needed
    #   - :celsius - convert to Celsius if needed
    def initialize(path, temperature_unit: :original)
      @path = path
      @temperature_unit = temperature_unit
      @data = nil
      @header_parser = HeaderParser.new
      @flights_cache = {}
      @parsed = false
      @all_flights_parsed = false
    end

    # Parse the file (called automatically when needed)
    def parse
      return if @parsed
      
      @data = ::File.binread(@path)
      
      # Verify this looks like a JPI file
      unless @data.start_with?('$U')
        raise ParseError, "Not a valid JPI file - expected $U header"
      end
      
      @header_parser.parse(@data)
      @parsed = true
    end

    # Get aircraft tail number
    def tail_number
      ensure_parsed
      @header_parser.tail_number
    end

    # Get EDM model number
    def model
      ensure_parsed
      @header_parser.config&.model
    end

    # Get download timestamp
    def download_time
      ensure_parsed
      ts = @header_parser.timestamp
      return nil unless ts
      
      year = ts.year < 50 ? 2000 + ts.year : 1900 + ts.year
      Time.new(year, ts.month, ts.day, ts.hour, ts.minute, 0)
    rescue ArgumentError
      nil
    end

    # Get list of flight index entries
    # @return [Array<HeaderParser::FlightIndex>]
    def flight_index
      ensure_parsed
      @header_parser.flights
    end

    # Get list of flights (lazy-loaded)
    # @return [Array<Flight>]
    def flights
      ensure_parsed
      parse_all_flights unless @all_flights_parsed
      @header_parser.flights.map do |index_entry|
        @flights_cache[index_entry.flight_number]
      end.compact
    end

    # Get a specific flight by number
    # @param flight_number [Integer] The flight number to retrieve
    # @return [Flight, nil] The flight or nil if not found
    def flight(flight_number)
      ensure_parsed

      # If not cached, parse all flights to find it
      # (flights must be parsed in order to track positions)
      parse_all_flights unless @all_flights_parsed

      @flights_cache[flight_number]
    end

    # Parse all flights sequentially, tracking actual positions
    #
    # JPI files store flights sequentially after the header. The $D index records
    # contain data_words (16-bit word count) for each flight. However, the actual
    # byte length may be 1 less than data_words * 2 when the raw data ends on an
    # odd byte boundary - JPI rounds UP to the next word for the index.
    #
    # We check both the expected position and expected-1 to handle this.
    def parse_all_flights
      return if @all_flights_parsed

      current_pos = @header_parser.binary_offset

      @header_parser.flights.each do |index_entry|
        # Check expected position and expected-1 for the flight header
        # (JPI rounds data_words UP for odd-length flights)
        flight_offset = find_flight_at_position(index_entry.flight_number, current_pos)

        if flight_offset
          flight = Flight.new(
            index_entry: index_entry,
            data: @data,
            flight_offset: flight_offset,
            config: @header_parser.config,
            temperature_unit: @temperature_unit
          ).parse

          @flights_cache[index_entry.flight_number] = flight

          # Move to expected next position (data_words * 2)
          # The actual position may be 0 or 1 byte less, handled on next iteration
          current_pos = flight_offset + index_entry.data_length
        else
          # Flight not found, advance by expected length
          current_pos += index_entry.data_length
        end
      end

      @all_flights_parsed = true
    end

    # Get summary information about the file
    def summary
      ensure_parsed

      {
        path: @path,
        tail_number: tail_number,
        model: "EDM-#{model}",
        download_time: download_time,
        flight_count: flight_index.length,
        flights: flight_index.map do |f|
          {
            number: f.flight_number,
            data_words: f.data_words,
            data_bytes: f.data_words * 2
          }
        end
      }
    end

    # Print summary to stdout
    def print_summary
      ensure_parsed

      puts "JPI File: #{@path}"
      puts "Aircraft: #{tail_number}"
      puts "Model: EDM-#{model}"
      puts "Downloaded: #{download_time}"
      puts "Flights: #{flight_index.length}"
      puts
      puts "Flight List:"
      puts "-" * 50

      flight_index.each do |f|
        flight_obj = flight(f.flight_number)
        duration = flight_obj.duration_hours
        duration_str = duration > 0 ? format('%.2f hrs', duration) : 'N/A'

        puts format("  #%-5d  %s  %d bytes",
          f.flight_number,
          duration_str,
          f.data_words * 2)
      end
    end

    private

    def ensure_parsed
      parse unless @parsed
    end

    # Find flight header at the expected position or 1 byte before.
    #
    # JPI data_words may be 1 more than actual bytes / 2 when the flight's
    # raw data length is odd. This method checks both positions.
    #
    # @param expected_flight_number [Integer] The flight number to find
    # @param expected_pos [Integer] The calculated position based on cumulative data_words
    # @return [Integer, nil] The actual position of the flight header, or nil if not found
    def find_flight_at_position(expected_flight_number, expected_pos)
      flight_num_bytes = [expected_flight_number].pack('n')

      # Check expected position first, then 1 byte before
      # (data_words rounds UP for odd-length flights)
      [0, -1].each do |delta|
        pos = expected_pos + delta
        next if pos < @header_parser.binary_offset
        next if pos + Flight::FLIGHT_HEADER_SIZE > @data.length

        # Check if flight number matches
        if @data[pos, 2] == flight_num_bytes && valid_flight_header_at?(pos)
          return pos
        end
      end

      nil
    end

    def valid_flight_header_at?(pos)
      return false if pos + Flight::FLIGHT_HEADER_SIZE > @data.length

      words = @data[pos, Flight::FLIGHT_HEADER_SIZE].unpack('n14')
      return false unless words

      # Check interval (word 11) - should be 1-60 seconds
      interval = words[11]
      return false unless interval >= 1 && interval <= 60

      # Check date components (word 12)
      date_bits = words[12]
      day = date_bits & 0x1F
      month = (date_bits >> 5) & 0x0F
      year = ((date_bits >> 9) & 0x7F) + 2000

      # Reasonable date range
      return false unless day >= 1 && day <= 31
      return false unless month >= 1 && month <= 12
      return false unless year >= 2000 && year <= 2050

      # Check time components (word 13)
      time_bits = words[13]
      secs = (time_bits & 0x1F) * 2
      mins = (time_bits >> 5) & 0x3F
      hrs = (time_bits >> 11) & 0x1F

      return false unless hrs <= 23 && mins <= 59 && secs <= 59

      true
    end
  end
end
