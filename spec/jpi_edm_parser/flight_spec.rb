# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JpiEdmParser::Flight do
  let(:test_file_path) { 'test_data/U251222.JPI' }
  let(:flight_number) { 1197 }

  describe 'temperature conversion' do
    context 'with temperature_unit: :original (default)' do
      let(:file) { JpiEdmParser::File.new(test_file_path) }
      let(:flight) { file.flight(flight_number) }

      it 'keeps temperatures in original Fahrenheit units' do
        expect(flight.temperature_unit).to eq(:original)

        record = flight.records.find { |r| r[:egt1] && r[:egt1] > 100 }
        expect(record).not_to be_nil

        # EGT values in Fahrenheit are typically 1000-1600°F
        expect(record[:egt1]).to be > 500
        expect(record[:egt1]).to be < 2000

        # CHT values in Fahrenheit are typically 200-450°F
        expect(record[:cht1]).to be > 100
        expect(record[:cht1]).to be < 500
      end

      it 'returns integer values (no decimal conversion applied)' do
        record = flight.records.find { |r| r[:egt1] && r[:egt1] > 100 }
        expect(record[:egt1]).to be_a(Integer)
        expect(record[:cht1]).to be_a(Integer)
      end
    end

    context 'with temperature_unit: :celsius' do
      let(:file) { JpiEdmParser::File.new(test_file_path, temperature_unit: :celsius) }
      let(:flight) { file.flight(flight_number) }

      it 'converts temperatures to Celsius' do
        expect(flight.temperature_unit).to eq(:celsius)

        record = flight.records.find { |r| r[:egt1] && r[:egt1] > 100 }
        expect(record).not_to be_nil

        # EGT values in Celsius are typically 500-900°C
        expect(record[:egt1]).to be > 400
        expect(record[:egt1]).to be < 1000

        # CHT values in Celsius are typically 90-230°C
        expect(record[:cht1]).to be > 50
        expect(record[:cht1]).to be < 300
      end

      it 'returns float values with one decimal place' do
        record = flight.records.find { |r| r[:egt1] && r[:egt1] > 100 }
        expect(record[:egt1]).to be_a(Float)
        expect(record[:cht1]).to be_a(Float)
      end
    end

    context 'with temperature_unit: :fahrenheit' do
      let(:file) { JpiEdmParser::File.new(test_file_path, temperature_unit: :fahrenheit) }
      let(:flight) { file.flight(flight_number) }

      it 'keeps Fahrenheit values when source is already Fahrenheit' do
        expect(flight.temperature_unit).to eq(:fahrenheit)

        # Since the test file is in Fahrenheit, values should match :original
        original_file = JpiEdmParser::File.new(test_file_path, temperature_unit: :original)
        original_flight = original_file.flight(flight_number)

        record = flight.records.find { |r| r[:egt1] && r[:egt1] > 100 }
        original_record = original_flight.records.find { |r| r[:egt1] && r[:egt1] > 100 }

        expect(record[:egt1]).to eq(original_record[:egt1])
        expect(record[:cht1]).to eq(original_record[:cht1])
      end
    end

    describe 'conversion accuracy' do
      let(:file_original) { JpiEdmParser::File.new(test_file_path, temperature_unit: :original) }
      let(:file_celsius) { JpiEdmParser::File.new(test_file_path, temperature_unit: :celsius) }

      it 'correctly converts Fahrenheit to Celsius' do
        flight_f = file_original.flight(flight_number)
        flight_c = file_celsius.flight(flight_number)

        record_f = flight_f.records.find { |r| r[:egt1] && r[:egt1] > 100 }
        record_c = flight_c.records.find { |r| r[:egt1] && r[:egt1] > 100 }

        # Verify conversion formula: C = (F - 32) * 5/9
        expected_egt1_c = ((record_f[:egt1] - 32) * 5.0 / 9.0).round(1)
        expect(record_c[:egt1]).to eq(expected_egt1_c)

        expected_cht1_c = ((record_f[:cht1] - 32) * 5.0 / 9.0).round(1)
        expect(record_c[:cht1]).to eq(expected_cht1_c)
      end

      it 'converts all temperature fields' do
        flight_f = file_original.flight(flight_number)
        flight_c = file_celsius.flight(flight_number)

        # Find a record with multiple temperature values
        record_f = flight_f.records.find { |r| r[:egt1].to_i > 100 && r[:egt2].to_i > 100 }
        record_c = flight_c.records.find { |r| r[:egt1].to_i > 100 && r[:egt2].to_i > 100 }

        next unless record_f && record_c

        temp_fields = %i[egt1 egt2 egt3 egt4 egt5 egt6
                         cht1 cht2 cht3 cht4 cht5 cht6]

        temp_fields.each do |field|
          next if record_f[field].nil? || record_f[field] == 0

          expected = ((record_f[field] - 32) * 5.0 / 9.0).round(1)
          expect(record_c[field]).to eq(expected),
            "Expected #{field} to be #{expected}, got #{record_c[field]}"
        end
      end
    end
  end

  describe '#fahrenheit?' do
    let(:file) { JpiEdmParser::File.new(test_file_path) }
    let(:flight) { file.flight(flight_number) }

    it 'detects the temperature unit from file flags' do
      # The test file uses Fahrenheit (US units)
      expect(flight.send(:fahrenheit?)).to be true
    end
  end

  describe 'GPS fields' do
    let(:file) { JpiEdmParser::File.new(test_file_path) }
    let(:flight) { file.flight(flight_number) }

    it 'includes GPS fields in records' do
      record = flight.records.first
      expect(record).to have_key(:lat)
      expect(record).to have_key(:long)
      expect(record).to have_key(:alt)
      expect(record).to have_key(:gspd)
    end

    it 'includes GPS columns in CSV export' do
      csv = flight.to_csv
      headers = csv.lines.first
      expect(headers).to include('LAT')
      expect(headers).to include('LONG')
      expect(headers).to include('ALT')
      expect(headers).to include('GSPD')
    end

    it 'has_gps? returns false when no GPS data present' do
      # Flight 1199 has no GPS connected
      no_gps_flight = file.flight(1199)
      expect(no_gps_flight.has_gps?).to be false
    end

    context 'with GPS-enabled flight' do
      # Flight 1209 has GPS data
      let(:gps_flight) { file.flight(1209) }

      # Header coordinates (raw values from file)
      let(:header_lat) { 33.507333 }
      let(:header_long) { -112.284 }

      # Stable GPS output coordinates include offset from DEFAULT_VALUE
      # When GPS stabilizes at typical values like (140, 340), offset is:
      #   lat: (340-240)/6000 = +0.0167 degrees
      #   long: (140-240)/6000 = -0.0167 degrees
      let(:expected_stable_lat) { 33.524 }  # header + 100/6000
      let(:expected_stable_long) { -112.3007 }  # header - 100/6000

      it 'parses initial GPS coordinates from flight header' do
        expect(gps_flight.initial_lat).to be_within(0.001).of(header_lat)
        expect(gps_flight.initial_long).to be_within(0.001).of(header_long)
      end

      it 'has_gps? returns true when GPS data present' do
        expect(gps_flight.has_gps?).to be true
      end

      it 'includes GPS coordinates in records' do
        # Find a record with valid GPS data (after stabilization)
        record = gps_flight.records.find { |r| r[:lat] && r[:lat] != 0 }
        expect(record).not_to be_nil
        expect(record[:lat]).to be_within(0.01).of(expected_stable_lat)
        expect(record[:long]).to be_within(0.01).of(expected_stable_long)
      end

      it 'exports GPS coordinates to CSV' do
        csv = gps_flight.to_csv
        # Check that GPS coordinates appear somewhere in the CSV
        # The exact values depend on GPS stabilization timing
        expect(csv).to include('33.5')  # Latitude near 33.5xx
        expect(csv).to include('-112.')  # Longitude near -112.xxx
      end
    end
  end

  describe 'short and invalid flight handling' do
    let(:file) { JpiEdmParser::File.new(test_file_path) }

    describe 'valid short flights' do
      # Flight 1209 is a very short but valid flight (14 records)
      let(:flight) { file.flight(1209) }

      it 'parses successfully' do
        expect(flight.valid?).to be true
        expect(flight.empty?).to be false
      end

      it 'has a valid date' do
        expect(flight.date).not_to be_nil
      end

      it 'has records' do
        expect(flight.records.length).to be > 0
      end

      it 'has no parse warnings' do
        expect(flight.warnings?).to be false
        expect(flight.parse_warnings).to be_empty
      end
    end

    describe 'invalid/corrupted flights' do
      # Flights 1199 and 1216 have corrupted data
      let(:invalid_flight_numbers) { [1199, 1216] }

      it 'does not raise errors when parsing' do
        invalid_flight_numbers.each do |num|
          expect { file.flight(num) }.not_to raise_error
        end
      end

      it 'returns a flight object even when data is invalid' do
        invalid_flight_numbers.each do |num|
          flight = file.flight(num)
          expect(flight).to be_a(JpiEdmParser::Flight)
          expect(flight.flight_number).to eq(num)
        end
      end

      it 'marks invalid flights as not valid' do
        invalid_flight_numbers.each do |num|
          flight = file.flight(num)
          expect(flight.valid?).to be_falsey
        end
      end

      it 'marks invalid flights as empty' do
        invalid_flight_numbers.each do |num|
          flight = file.flight(num)
          expect(flight.empty?).to be true
        end
      end

      it 'records parse warnings' do
        invalid_flight_numbers.each do |num|
          flight = file.flight(num)
          expect(flight.warnings?).to be true
          expect(flight.parse_warnings).not_to be_empty
        end
      end

      it 'includes decode flags mismatch in warnings' do
        invalid_flight_numbers.each do |num|
          flight = file.flight(num)
          expect(flight.parse_warnings.any? { |w| w.include?('Decode flags mismatch') }).to be true
        end
      end

      it 'returns zero duration for empty flights' do
        invalid_flight_numbers.each do |num|
          flight = file.flight(num)
          expect(flight.duration_hours).to eq(0)
        end
      end
    end

    describe '#interval' do
      it 'returns default of 6 seconds when interval is 0' do
        flight = file.flight(1216)  # This flight has interval_secs = 0
        expect(flight.interval).to eq(6)
      end

      it 'returns actual interval when valid' do
        flight = file.flight(flight_number)
        expect(flight.interval).to be > 0
      end
    end
  end
end
