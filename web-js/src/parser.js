// Main JPI EDM Parser
// Orchestrates header and flight parsing

import { parseHeader, HeaderParseError, ChecksumError } from './header-parser.js';
import { Flight } from './flight.js';

export { HeaderParseError, ChecksumError };

export class JpiEdmParser {
  constructor(data, header, temperatureUnit) {
    this._data = data;
    this._header = header;
    this._flightsCache = new Map();
    this._temperatureUnit = temperatureUnit;
  }

  /**
   * Parse a JPI file from an ArrayBuffer
   */
  static fromArrayBuffer(buffer, temperatureUnit = 'original') {
    const data = new Uint8Array(buffer);

    // Verify this looks like a JPI file
    if (data.length < 2 || data[0] !== 0x24 || data[1] !== 0x55) { // $U
      throw new HeaderParseError('Not a valid JPI file - expected $U header');
    }

    const header = parseHeader(data);
    return new JpiEdmParser(buffer, header, temperatureUnit);
  }

  /**
   * Parse a JPI file from a browser File object
   */
  static async fromFile(file, temperatureUnit = 'original') {
    const buffer = await file.arrayBuffer();
    return JpiEdmParser.fromArrayBuffer(buffer, temperatureUnit);
  }

  /**
   * Get aircraft tail number
   */
  get tailNumber() {
    return this._header.tailNumber;
  }

  /**
   * Get EDM model number
   */
  get model() {
    return this._header.config?.model ?? null;
  }

  /**
   * Get model string (e.g., "EDM-830")
   */
  get modelString() {
    return this.model ? `EDM-${this.model}` : 'Unknown';
  }

  /**
   * Get configuration
   */
  get config() {
    return this._header.config;
  }

  /**
   * Get download timestamp
   */
  get downloadTime() {
    const ts = this._header.timestamp;
    if (!ts) return null;

    const year = ts.year < 50 ? 2000 + ts.year : 1900 + ts.year;
    try {
      return new Date(year, ts.month - 1, ts.day, ts.hour, ts.minute, 0);
    } catch (e) {
      return null;
    }
  }

  /**
   * Get list of flight index entries
   */
  get flightIndex() {
    return this._header.flights;
  }

  /**
   * Get number of flights
   */
  get flightCount() {
    return this._header.flights.length;
  }

  /**
   * Get all flights (parsed lazily and cached)
   */
  get flights() {
    return this._header.flights.map(entry => this.flight(entry.flightNumber));
  }

  /**
   * Get a specific flight by number
   */
  flight(flightNumber) {
    // Check cache first
    if (this._flightsCache.has(flightNumber)) {
      return this._flightsCache.get(flightNumber);
    }

    // Find the index entry
    const indexEntry = this._header.flights.find(f => f.flightNumber === flightNumber);
    if (!indexEntry) return null;

    // Parse and cache the flight
    const flight = new Flight(
      indexEntry,
      this._data,
      this._header.binaryOffset,
      this._temperatureUnit
    ).parse();

    this._flightsCache.set(flightNumber, flight);
    return flight;
  }

  /**
   * Get summary information
   */
  get summary() {
    return {
      tailNumber: this.tailNumber,
      model: this.modelString,
      downloadTime: this.downloadTime,
      flightCount: this.flightCount,
      flights: this.flightIndex.map(f => ({
        number: f.flightNumber,
        dataWords: f.dataWords,
        dataBytes: f.dataLength,
      })),
    };
  }
}
