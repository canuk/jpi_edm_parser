// Main JPI EDM Parser
// Orchestrates header and flight parsing

import { parseHeader, HeaderParseError } from './header-parser';
import { Flight } from './flight';
import type { ParsedHeader, FlightIndex, Config, TemperatureUnit } from './types';

export { HeaderParseError };
export { ChecksumError } from './header-parser';

export class JpiEdmParser {
  private data: ArrayBuffer;
  private header: ParsedHeader;
  private flightsCache: Map<number, Flight> = new Map();
  private temperatureUnit: TemperatureUnit;

  private constructor(data: ArrayBuffer, header: ParsedHeader, temperatureUnit: TemperatureUnit) {
    this.data = data;
    this.header = header;
    this.temperatureUnit = temperatureUnit;
  }

  /**
   * Parse a JPI file from an ArrayBuffer
   */
  static fromArrayBuffer(buffer: ArrayBuffer, temperatureUnit: TemperatureUnit = 'original'): JpiEdmParser {
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
  static async fromFile(file: File, temperatureUnit: TemperatureUnit = 'original'): Promise<JpiEdmParser> {
    const buffer = await file.arrayBuffer();
    return JpiEdmParser.fromArrayBuffer(buffer, temperatureUnit);
  }

  /**
   * Get aircraft tail number
   */
  get tailNumber(): string | null {
    return this.header.tailNumber;
  }

  /**
   * Get EDM model number
   */
  get model(): number | null {
    return this.header.config?.model ?? null;
  }

  /**
   * Get model string (e.g., "EDM-830")
   */
  get modelString(): string {
    return this.model ? `EDM-${this.model}` : 'Unknown';
  }

  /**
   * Get configuration
   */
  get config(): Config | null {
    return this.header.config;
  }

  /**
   * Get download timestamp
   */
  get downloadTime(): Date | null {
    const ts = this.header.timestamp;
    if (!ts) return null;

    const year = ts.year < 50 ? 2000 + ts.year : 1900 + ts.year;
    try {
      return new Date(year, ts.month - 1, ts.day, ts.hour, ts.minute, 0);
    } catch {
      return null;
    }
  }

  /**
   * Get list of flight index entries
   */
  get flightIndex(): FlightIndex[] {
    return this.header.flights;
  }

  /**
   * Get number of flights
   */
  get flightCount(): number {
    return this.header.flights.length;
  }

  /**
   * Get all flights (parsed lazily and cached)
   */
  get flights(): Flight[] {
    return this.header.flights.map(entry => this.flight(entry.flightNumber)!);
  }

  /**
   * Get a specific flight by number
   */
  flight(flightNumber: number): Flight | null {
    // Check cache first
    if (this.flightsCache.has(flightNumber)) {
      return this.flightsCache.get(flightNumber)!;
    }

    // Find the index entry
    const indexEntry = this.header.flights.find(f => f.flightNumber === flightNumber);
    if (!indexEntry) return null;

    // Parse and cache the flight
    const flight = new Flight(
      indexEntry,
      this.data,
      this.header.binaryOffset,
      this.temperatureUnit
    ).parse();

    this.flightsCache.set(flightNumber, flight);
    return flight;
  }

  /**
   * Get summary information
   */
  get summary(): {
    tailNumber: string | null;
    model: string;
    downloadTime: Date | null;
    flightCount: number;
    flights: Array<{
      number: number;
      dataWords: number;
      dataBytes: number;
    }>;
  } {
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
