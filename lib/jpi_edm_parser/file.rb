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
      @header_parser.flights.map do |index_entry|
        flight(index_entry.flight_number)
      end
    end

    # Get a specific flight by number
    # @param flight_number [Integer] The flight number to retrieve
    # @return [Flight, nil] The flight or nil if not found
    def flight(flight_number)
      ensure_parsed
      
      @flights_cache[flight_number] ||= begin
        index_entry = @header_parser.flights.find { |f| f.flight_number == flight_number }
        return nil unless index_entry
        
        Flight.new(
          index_entry: index_entry,
          data: @data,
          binary_offset: @header_parser.binary_offset,
          config: @header_parser.config,
          temperature_unit: @temperature_unit
        ).parse
      end
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
  end
end
