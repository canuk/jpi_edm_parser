// Header parser for JPI EDM files
// Parses the ASCII header section that precedes binary flight data

import type { Config, AlarmLimits, FuelConfig, FlightIndex, Timestamp, ParsedHeader } from './types';

export class HeaderParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'HeaderParseError';
  }
}

export class ChecksumError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ChecksumError';
  }
}

export function parseHeader(data: Uint8Array): ParsedHeader {
  const result: ParsedHeader = {
    tailNumber: null,
    config: null,
    alarmLimits: null,
    fuelConfig: null,
    flights: [],
    timestamp: null,
    binaryOffset: 0,
  };

  const decoder = new TextDecoder('ascii');
  let pos = 0;

  while (pos < data.length) {
    // Find next line ending (CR+LF)
    let lineEnd = -1;
    for (let i = pos; i < data.length - 1; i++) {
      if (data[i] === 0x0D && data[i + 1] === 0x0A) { // \r\n
        lineEnd = i;
        break;
      }
    }

    if (lineEnd === -1) break;

    const lineBytes = data.slice(pos, lineEnd);
    const line = decoder.decode(lineBytes);

    // Header lines start with $
    if (!line.startsWith('$')) break;

    parseHeaderLine(line, result);

    pos = lineEnd + 2; // Skip past \r\n

    // $L marks end of headers
    if (line.startsWith('$L')) {
      result.binaryOffset = pos;
      break;
    }
  }

  if (result.binaryOffset === 0) {
    throw new HeaderParseError('No $L record found - invalid file format');
  }

  return result;
}

function parseHeaderLine(line: string, result: ParsedHeader): void {
  // Verify checksum
  verifyChecksum(line);

  // Remove checksum suffix (*XX)
  const content = line.replace(/\*[0-9A-Fa-f]{2}$/, '');

  const recordType = content[1];
  const fieldsStr = content.slice(3); // Skip "$X,"
  const fields = fieldsStr.split(',').map(f => f.trim());

  switch (recordType) {
    case 'U':
      result.tailNumber = parseTailNumber(fields);
      break;
    case 'A':
      result.alarmLimits = parseAlarmLimits(fields);
      break;
    case 'C':
      result.config = parseConfig(fields);
      break;
    case 'D':
      result.flights.push(parseFlightIndex(fields));
      break;
    case 'F':
      result.fuelConfig = parseFuelConfig(fields);
      break;
    case 'T':
      result.timestamp = parseTimestamp(fields);
      break;
    case 'P':
    case 'H':
    case 'L':
      // Known but not parsed
      break;
    default:
      // Unknown record type - ignore
      break;
  }
}

function verifyChecksum(line: string): void {
  const starIndex = line.indexOf('*');
  if (starIndex === -1) return;

  const content = line.slice(1, starIndex); // Between $ and *
  const expectedHex = line.slice(starIndex + 1, starIndex + 3);
  const expected = parseInt(expectedHex, 16);

  let calculated = 0;
  for (let i = 0; i < content.length; i++) {
    calculated ^= content.charCodeAt(i);
  }

  if (calculated !== expected) {
    throw new ChecksumError(
      `Header checksum mismatch: expected ${expected.toString(16)}, got ${calculated.toString(16)}`
    );
  }
}

function parseTailNumber(fields: string[]): string {
  // Join fields in case tail number contains commas
  return fields.join(',').replace(/\*.*$/, '').trim();
}

function parseAlarmLimits(fields: string[]): AlarmLimits {
  return {
    voltsHigh: parseInt(fields[0]) || 0,
    voltsLow: parseInt(fields[1]) || 0,
    dif: parseInt(fields[2]) || 0,
    cht: parseInt(fields[3]) || 0,
    cld: parseInt(fields[4]) || 0,
    tit: parseInt(fields[5]) || 0,
    oilHigh: parseInt(fields[6]) || 0,
    oilLow: parseInt(fields[7]) || 0,
  };
}

function parseConfig(fields: string[]): Config {
  return {
    model: parseInt(fields[0]) || 0,
    flagsLow: parseInt(fields[1]) || 0,
    flagsHigh: parseInt(fields[2]) || 0,
    unknown1: fields[3] ? parseInt(fields[3]) : undefined,
    unknown2: fields[4] ? parseInt(fields[4]) : undefined,
    unknown3: fields[5] ? parseInt(fields[5]) : undefined,
    unknown4: fields[6] ? parseInt(fields[6]) : undefined,
    unknown5: fields[7] ? parseInt(fields[7]) : undefined,
    unknown6: fields[8] ? parseInt(fields[8]) : undefined,
  };
}

function parseFlightIndex(fields: string[]): FlightIndex {
  const dataWords = parseInt(fields[1]) || 0;
  return {
    flightNumber: parseInt(fields[0]) || 0,
    dataWords,
    dataLength: dataWords * 2,
  };
}

function parseFuelConfig(fields: string[]): FuelConfig {
  return {
    emptyWarning: parseInt(fields[0]) || 0,
    fullCapacity: parseInt(fields[1]) || 0,
    warningLevel: parseInt(fields[2]) || 0,
    kFactor1: parseInt(fields[3]) || 0,
    kFactor2: parseInt(fields[4]) || 0,
  };
}

function parseTimestamp(fields: string[]): Timestamp {
  return {
    month: parseInt(fields[0]) || 0,
    day: parseInt(fields[1]) || 0,
    year: parseInt(fields[2]) || 0,
    hour: parseInt(fields[3]) || 0,
    minute: parseInt(fields[4]) || 0,
    unknown: fields[5] ? parseInt(fields[5]) : undefined,
  };
}
