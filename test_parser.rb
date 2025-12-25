#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for JPI EDM Parser
# Usage: ruby test_parser.rb [path_to_jpi_file]

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'jpi_edm_parser'

file_path = ARGV[0] || 'test_data/U251222.JPI'

unless File.exist?(file_path)
  puts "Error: File not found: #{file_path}"
  exit 1
end

puts "=" * 60
puts "JPI EDM Parser Test"
puts "=" * 60
puts

begin
  jpi = JpiEdmParser::File.new(file_path)
  jpi.print_summary
  
  puts
  puts "=" * 60
  puts "Detailed Header Information"
  puts "=" * 60
  
  if jpi.header_parser.alarm_limits
    puts "\nAlarm Limits:"
    limits = jpi.header_parser.alarm_limits
    puts "  Volts High: #{limits.volts_high / 10.0}V"
    puts "  Volts Low: #{limits.volts_low / 10.0}V"
    puts "  DIF: #{limits.dif}°F"
    puts "  CHT: #{limits.cht}°F"
    puts "  CLD: #{limits.cld}°F/min"
    puts "  TIT: #{limits.tit}°F"
    puts "  Oil High: #{limits.oil_high}°F"
    puts "  Oil Low: #{limits.oil_low}°F"
  end
  
  if jpi.header_parser.fuel_config
    puts "\nFuel Configuration:"
    fuel = jpi.header_parser.fuel_config
    puts "  Full Capacity: #{fuel.full_capacity} gal"
    puts "  K-Factor 1: #{fuel.k_factor_1}"
    puts "  K-Factor 2: #{fuel.k_factor_2}"
  end
  
  if jpi.header_parser.config
    puts "\nConfiguration:"
    config = jpi.header_parser.config
    puts "  Model: EDM-#{config.model}"
    puts "  Feature Flags Low: 0x#{config.flags_low.to_s(16)}"
    puts "  Feature Flags High: 0x#{config.flags_high.to_s(16)}"
    puts "  Combined Flags: 0x#{((config.flags_high << 16) | config.flags_low).to_s(16)}"
  end
  
  puts
  puts "=" * 60
  puts "Testing Flight Parsing"
  puts "=" * 60
  
  if jpi.flight_index.any?
    first_flight_num = jpi.flight_index.first.flight_number
    puts "\nLoading flight ##{first_flight_num}..."
    
    flight = jpi.flight(first_flight_num)
    puts "  Flight number: #{flight.flight_number}"
    puts "  Data length: #{jpi.flight_index.first.data_length} bytes"
    
    if flight.date
      puts "  Start date: #{flight.date.strftime('%Y-%m-%d %H:%M:%S')}"
    else
      puts "  Start date: (could not parse)"
    end
    
    if flight.flags
      puts "  Flags: 0x#{flight.flags.to_s(16)}"
      puts "  Temperature unit: #{flight.send(:fahrenheit?) ? 'Fahrenheit' : 'Celsius'}"
    end
    
    puts "  Interval: #{flight.interval} seconds"
    puts "  Records parsed: #{flight.records.length}"
    puts "  Duration: #{flight.duration_hours.round(2)} hours"
    
    if flight.records.any?
      puts "\n  First record sample:"
      first = flight.records.first
      puts "    EGT1: #{first[:egt1]}  CHT1: #{first[:cht1]}"
      puts "    EGT2: #{first[:egt2]}  CHT2: #{first[:cht2]}"
      puts "    EGT3: #{first[:egt3]}  CHT3: #{first[:cht3]}"
      puts "    EGT4: #{first[:egt4]}  CHT4: #{first[:cht4]}"
      puts "    Oil T: #{first[:oil_t]}  Oil P: #{first[:oil_p]}"
      puts "    RPM: #{first[:rpm]}  MAP: #{first[:map]}"
      puts "    FF: #{first[:ff]}  VOLT: #{first[:volt]}"
      puts "    GSPD: #{first[:gspd]}"
      
      puts "\n  Last record sample:"
      last = flight.records.last
      puts "    EGT1: #{last[:egt1]}  CHT1: #{last[:cht1]}"
      puts "    EGT2: #{last[:egt2]}  CHT2: #{last[:cht2]}"
      puts "    RPM: #{last[:rpm]}  MAP: #{last[:map]}"
      
      # Save CSV for first flight
      csv_file = "test_data/flight_#{first_flight_num}.csv"
      flight.to_csv(csv_file)
      puts "\n  CSV saved to: #{csv_file}"
    end
  end
  
  puts
  puts "✓ Parser test completed successfully!"
  
rescue JpiEdmParser::Error => e
  puts "Parser error: #{e.message}"
  exit 1
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(10).join("\n")
  exit 1
end
