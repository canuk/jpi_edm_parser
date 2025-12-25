# OpenEngineData.org - JPI EDM Parser

A Ruby library for parsing JPI EDM (Engine Data Management) engine monitor data files, designed for use in general aviation applications.

## License

This project is released under the **MIT License** (see LICENSE file).

## Clean-Room Implementation Notice

This parser was developed using a **clean-room implementation approach** to ensure it is free from any copyright encumbrances:

1. **No copyrighted code was referenced** during implementation
2. The implementation is based solely on:
   - Publicly available format documentation
   - Analysis of binary file structure from user-owned data files
   - Independently derived understanding of the JPI file format
3. The JPI binary file format itself is not copyrightable - it represents factual information about how JPI instruments store data

### Sources Used

The following public sources informed our understanding of the JPI file format:

1. **Public forum discussions** on pilotsofamerica.com and other aviation forums where pilots have discussed the file format
2. **Independent reverse engineering** of the author's own JPI data files
3. **General documentation** about delta-compression schemes and binary file formats

### What This Means

- This code is an **original work** created from publicly available information
- You are free to use this library in commercial and non-commercial applications
- No attribution to any prior implementation is required (though appreciated)
- This library does not incorporate code from any CC BY-NC licensed projects

## Supported Devices

- JPI EDM 700 series
- JPI EDM 730/830
- JPI EDM 800 series  
- JPI EDM 900/930/960

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'jpi_edm_parser'
```

Or install it yourself:

```bash
gem install jpi_edm_parser
```

## Usage

```ruby
require 'jpi_edm_parser'

# Open a JPI file
file = JpiEdmParser::File.new('path/to/file.jpi')

# List flights
file.flights.each do |flight|
  puts "Flight ##{flight.flight_number}: #{flight.date} - #{flight.duration_hours} hours"
end

# Extract a specific flight to CSV
flight = file.flight(1196)
flight.to_csv('flight_1196.csv')

# Access flight data programmatically
flight.records.each do |record|
  puts "EGT1=#{record[:egt1]}, CHT1=#{record[:cht1]}, RPM=#{record[:rpm]}"
end
```

### Temperature Units

By default, temperatures are kept in their original units (typically Fahrenheit for US aircraft). You can configure automatic conversion:

```ruby
# Keep original units (default)
file = JpiEdmParser::File.new('file.jpi')

# Convert all temperatures to Celsius
file = JpiEdmParser::File.new('file.jpi', temperature_unit: :celsius)

# Ensure Fahrenheit output
file = JpiEdmParser::File.new('file.jpi', temperature_unit: :fahrenheit)
```

### GPS Data

When a GPS is connected to the EDM, latitude and longitude are recorded:

```ruby
file = JpiEdmParser::File.new('file.jpi')
flight = file.flight(1209)

# Check if GPS data is present
if flight.has_gps?
  puts "Initial position: #{flight.initial_lat}, #{flight.initial_long}"

  flight.records.each do |record|
    puts "Position: #{record[:lat]}, #{record[:long]}"
    puts "Ground speed: #{record[:gspd]} knots"
    puts "Altitude: #{record[:alt]} feet"
  end
end
```

### Handling Invalid Flights

Some flights may have corrupted or incomplete data. The parser handles these gracefully:

```ruby
flight = file.flight(1199)

if flight.valid?
  # Flight has date and records
  puts "Duration: #{flight.duration_hours} hours"
else
  # Flight failed to parse
  puts "Invalid flight: #{flight.parse_warnings.join(', ')}"
end
```

## Data Fields

The parser extracts all available engine parameters including:

- **EGT** (Exhaust Gas Temperature) - up to 9 cylinders
- **CHT** (Cylinder Head Temperature) - up to 9 cylinders
- **TIT** (Turbine Inlet Temperature)
- **Oil Temperature and Pressure**
- **Fuel Flow and Fuel Used**
- **RPM and MAP** (Manifold Absolute Pressure)
- **Voltage and Amps**
- **OAT** (Outside Air Temperature)
- **GPS Data** (Latitude, Longitude, Altitude, Ground Speed) - when connected

## Contributing

Contributions are welcome! Please ensure any contributions:
1. Do not incorporate code from incompatibly-licensed projects
2. Include tests for new functionality
3. Follow the existing code style

## Author

Created for [OpenEngineData.org](https://openenginedata.org)

## Acknowledgments

This project exists to help the general aviation community better understand and analyze their engine data. Safe flying!
