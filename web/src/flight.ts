// Flight parser for JPI EDM files
// Handles binary delta-compressed flight data

import type { FlightIndex, FlightRecord, TemperatureUnit } from './types';

// Field index mapping - derived from format documentation
// Some fields use two indices: [lowByte, highByte]
const FIELD_LABELS: Record<string, number | [number, number]> = {
  // EGT fields: low byte + high byte
  egt1: [0, 48], egt2: [1, 49], egt3: [2, 50],
  egt4: [3, 51], egt5: [4, 52], egt6: [5, 53],
  // CHT fields (single byte each)
  cht1: 8, cht2: 9, cht3: 10, cht4: 11, cht5: 12, cht6: 13,
  // Engine parameters
  cld: 14, oilT: 15, mark: 16, oilP: 17, crb: 18,
  volt: 20, oat: 21, usd: 22, ff: 23, hp: 30,
  map: 40, rpm: [41, 42],
  // Hobbs time
  hours: [78, 79],
  // GPS fields
  alt: 83,
  gspd: 85,
};

// GPS field indices
const GPS_LONG_INDEX = 86;
const GPS_LAT_INDEX = 87;
const GPS_LONG_HIGH_INDEX = 81;
const GPS_LAT_HIGH_INDEX = 82;

const NUM_FIELDS = 128;
const DEFAULT_VALUE = 0xF0; // 240
const FLIGHT_HEADER_SIZE = 28; // 14 x 16-bit words

const TEMP_FIELDS = [
  'egt1', 'egt2', 'egt3', 'egt4', 'egt5', 'egt6',
  'cht1', 'cht2', 'cht3', 'cht4', 'cht5', 'cht6',
  'crb', 'cld', 'oilT', 'oat'
];

export class Flight {
  readonly flightNumber: number;
  readonly indexEntry: FlightIndex;

  date: Date | null = null;
  flags: number = 0;
  intervalSecs: number = 6;
  records: FlightRecord[] = [];
  parseWarnings: string[] = [];
  initialLat: number | null = null;
  initialLong: number | null = null;

  private data: DataView;
  private binaryOffset: number;
  private temperatureUnit: TemperatureUnit;
  private dataLength: number;
  private flightStart: number = 0;

  // GPS state
  private gpsLatCumulative: number = DEFAULT_VALUE;
  private gpsLongCumulative: number = DEFAULT_VALUE;
  private gpsStableCount: number = 0;
  private lastGoodGpsLat: number | null = null;
  private lastGoodGpsLong: number | null = null;
  private gpsCandidateLat: number | null = null;
  private gpsCandidateLong: number | null = null;
  private gpsOutputCount: number = 0;
  private gpsNonKansasCount: number = 0;
  private kansasJunkHeader: boolean = false;

  constructor(
    indexEntry: FlightIndex,
    data: ArrayBuffer,
    binaryOffset: number,
    temperatureUnit: TemperatureUnit = 'original'
  ) {
    this.indexEntry = indexEntry;
    this.flightNumber = indexEntry.flightNumber;
    this.data = new DataView(data);
    this.binaryOffset = binaryOffset;
    this.temperatureUnit = temperatureUnit;
    this.dataLength = indexEntry.dataLength;
  }

  parse(): this {
    try {
      // Find the start of this flight's data
      const flightStart = this.findFlightStart();
      if (flightStart === null) {
        this.parseWarnings.push('Could not locate flight data start marker');
        return this;
      }
      this.flightStart = flightStart;

      if (this.flightStart + this.dataLength > this.data.byteLength) {
        this.parseWarnings.push(
          `Flight data extends beyond file (start=${this.flightStart}, length=${this.dataLength}, fileSize=${this.data.byteLength})`
        );
        return this;
      }

      if (this.dataLength < FLIGHT_HEADER_SIZE) {
        this.parseWarnings.push(
          `Flight data too short (${this.dataLength} bytes, need ${FLIGHT_HEADER_SIZE})`
        );
        return this;
      }

      this.parseFlightHeader();
      this.parseDataRecords();
    } catch (e) {
      this.parseWarnings.push(`Parse error: ${e instanceof Error ? e.message : String(e)}`);
    }
    return this;
  }

  get startTime(): Date | null {
    return this.date;
  }

  get interval(): number {
    return this.intervalSecs <= 0 ? 6 : this.intervalSecs;
  }

  get durationHours(): number {
    if (this.records.length === 0) return 0;
    return (this.records.length * this.interval) / 3600;
  }

  get valid(): boolean {
    return this.date !== null && this.records.length > 0;
  }

  get empty(): boolean {
    return this.records.length === 0;
  }

  get hasWarnings(): boolean {
    return this.parseWarnings.length > 0;
  }

  get hasGps(): boolean {
    return this.records.some(r => (r.lat ?? 0) !== 0 || (r.long ?? 0) !== 0);
  }

  toCsv(): string {
    const headers = ['DATE', ...Object.keys(FIELD_LABELS).map(k => k.toUpperCase()), 'LAT', 'LONG'];
    const lines: string[] = [headers.join(',')];

    for (const record of this.records) {
      const row: string[] = [];

      // Date
      if (record.date) {
        row.push(this.formatDate(record.date));
      } else {
        row.push('');
      }

      // Field values
      for (const key of Object.keys(FIELD_LABELS)) {
        const val = record[key];
        row.push(val !== undefined && val !== null ? String(val) : '');
      }

      // GPS
      row.push(record.lat !== null ? String(record.lat) : '');
      row.push(record.long !== null ? String(record.long) : '');

      lines.push(row.join(','));
    }

    return lines.join('\n') + '\n';
  }

  private formatDate(date: Date): string {
    const pad = (n: number) => n.toString().padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
           `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  }

  private findFlightStart(): number | null {
    // Find the flight by searching for its flight number in big-endian
    const flightNumHigh = (this.flightNumber >> 8) & 0xFF;
    const flightNumLow = this.flightNumber & 0xFF;

    for (let pos = this.binaryOffset; pos < this.data.byteLength - FLIGHT_HEADER_SIZE; pos++) {
      if (this.data.getUint8(pos) === flightNumHigh &&
          this.data.getUint8(pos + 1) === flightNumLow) {
        return pos;
      }
    }

    return null;
  }

  private parseFlightHeader(): void {
    const offset = this.flightStart;

    // Read 14 x 16-bit words (big-endian)
    const words: number[] = [];
    for (let i = 0; i < 14; i++) {
      words.push(this.data.getUint16(offset + i * 2, false)); // false = big-endian
    }

    this.flags = words[1] | (words[2] << 16);

    // Parse initial GPS from words 6-9
    this.parseInitialGps(words);

    this.intervalSecs = words[11];

    // Date: day:5, month:4, year:7
    const dateBits = words[12];
    const day = dateBits & 0x1F;
    const month = (dateBits >> 5) & 0x0F;
    const year = ((dateBits >> 9) & 0x7F) + 2000;

    // Time: secs:5 (stored as secs/2), mins:6, hrs:5
    const timeBits = words[13];
    const secs = (timeBits & 0x1F) * 2;
    const mins = (timeBits >> 5) & 0x3F;
    const hrs = (timeBits >> 11) & 0x1F;

    try {
      this.date = new Date(year, month - 1, day, hrs, mins, secs);
      // Check for invalid date
      if (isNaN(this.date.getTime())) {
        this.date = null;
        this.parseWarnings.push('Invalid date/time in flight header');
      }
    } catch {
      this.date = null;
      this.parseWarnings.push('Invalid date/time in flight header');
    }

    if (this.intervalSecs <= 0) {
      this.parseWarnings.push(
        `Invalid recording interval (${this.intervalSecs}), using default of 6 seconds`
      );
    }
  }

  private parseInitialGps(words: number[]): void {
    // GPS coordinates stored as 32-bit signed integers
    // Combine high and low words, then divide by 6000 for decimal degrees
    let latRaw = (words[6] << 16) | words[7];
    let longRaw = (words[8] << 16) | words[9];

    // Convert to signed 32-bit
    if (latRaw > 0x7FFFFFFF) latRaw -= 0x100000000;
    if (longRaw > 0x7FFFFFFF) longRaw -= 0x100000000;

    if (latRaw !== 0 && longRaw !== 0) {
      const latDeg = latRaw / 6000;
      const longDeg = longRaw / 6000;

      // Sanity check
      if (Math.abs(latDeg) <= 90 && Math.abs(longDeg) <= 180) {
        this.initialLat = latDeg;
        this.initialLong = longDeg;
      }
    }
  }

  private parseDataRecords(): void {
    const dataStart = this.flightStart + FLIGHT_HEADER_SIZE;
    const dataEnd = this.flightStart + this.dataLength;

    if (dataStart >= dataEnd) {
      this.parseWarnings.push('No data records present after flight header');
      return;
    }

    // Initialize default values
    const defaultValues = new Array(NUM_FIELDS).fill(DEFAULT_VALUE);
    if (FIELD_LABELS.hp !== undefined) {
      const hpIndex = typeof FIELD_LABELS.hp === 'number' ? FIELD_LABELS.hp : FIELD_LABELS.hp[0];
      defaultValues[hpIndex] = 0;
    }

    // High bytes default to 0
    for (const index of Object.values(FIELD_LABELS)) {
      if (Array.isArray(index)) {
        defaultValues[index[1]] = 0;
      }
    }

    const previousValues: (number | null)[] = new Array(NUM_FIELDS).fill(null);
    let currentDate = this.date ? new Date(this.date.getTime()) : null;
    let gspdBug = true;
    let offset = dataStart;

    while (offset < dataEnd - 5) {
      // Skip 1 unknown byte
      offset += 1;
      if (offset + 4 > dataEnd) break;

      // Read 2x16-bit decode_flags (should be equal)
      const decodeFlags1 = this.data.getUint16(offset, false);
      const decodeFlags2 = this.data.getUint16(offset + 2, false);
      offset += 4;

      if (offset >= dataEnd) break;

      // Read repeat count
      const repeatCount = this.data.getUint8(offset);
      offset += 1;

      // Validate decode flags match
      if (decodeFlags1 !== decodeFlags2) {
        if (this.records.length === 0) {
          this.parseWarnings.push(
            `Decode flags mismatch at start of data (0x${decodeFlags1.toString(16)} vs 0x${decodeFlags2.toString(16)})`
          );
        }
        break;
      }

      const decodeFlags = decodeFlags1;

      // Handle repeat count - advance time for repeated records
      for (let i = 0; i < repeatCount; i++) {
        if (currentDate) {
          currentDate = new Date(currentDate.getTime() + this.intervalSecs * 1000);
        }
      }

      // Read field flags for each bit set in decode_flags
      const fieldFlags = new Array(16).fill(0);
      const signFlags = new Array(16).fill(0);

      for (let i = 0; i < 16; i++) {
        if ((decodeFlags & (1 << i)) !== 0) {
          if (offset >= dataEnd) break;
          fieldFlags[i] = this.data.getUint8(offset);
          offset += 1;
        }
      }

      for (let i = 0; i < 16; i++) {
        // Skip sign flags for bits 6 and 7
        if ((decodeFlags & (1 << i)) !== 0 && i !== 6 && i !== 7) {
          if (offset >= dataEnd) break;
          signFlags[i] = this.data.getUint8(offset);
          offset += 1;
        }
      }

      // Expand to 128-bit arrays
      const expandedFieldFlags = new Array(NUM_FIELDS).fill(0);
      const expandedSignFlags = new Array(NUM_FIELDS).fill(0);

      for (let i = 0; i < 16; i++) {
        const byte = fieldFlags[i];
        for (let bit = 0; bit < 8; bit++) {
          expandedFieldFlags[i * 8 + bit] = (byte & (1 << bit)) !== 0 ? 1 : 0;
        }
      }

      for (let i = 0; i < 16; i++) {
        const byte = signFlags[i];
        for (let bit = 0; bit < 8; bit++) {
          expandedSignFlags[i * 8 + bit] = (byte & (1 << bit)) !== 0 ? 1 : 0;
        }
      }

      // Copy sign flags for high bytes from low bytes
      for (const index of Object.values(FIELD_LABELS)) {
        if (Array.isArray(index)) {
          expandedSignFlags[index[1]] = expandedSignFlags[index[0]];
        }
      }

      // Read and calculate values
      const newValues = new Array(NUM_FIELDS).fill(0);
      const gpsRawDeltas: Record<number, number> = {};

      for (let k = 0; k < NUM_FIELDS; k++) {
        let value = previousValues[k];

        if (expandedFieldFlags[k] !== 0) {
          if (offset >= dataEnd) break;
          const rawByte = this.data.getUint8(offset);
          offset += 1;

          // Save raw bytes for GPS-related fields
          if ([GPS_LONG_HIGH_INDEX, GPS_LAT_HIGH_INDEX, GPS_LONG_INDEX, GPS_LAT_INDEX].includes(k)) {
            gpsRawDeltas[k] = rawByte;
          }

          let diff = rawByte;
          if (expandedSignFlags[k] !== 0) {
            diff = -diff;
          }

          if (!(value === null && diff === 0)) {
            // Apply the change
            const baseValue = value ?? defaultValues[k];
            value = baseValue + diff;
            previousValues[k] = value;
          }
        }

        newValues[k] = value ?? 0;
      }

      // Build record from field mapping
      const record: FlightRecord = {
        date: currentDate ? new Date(currentDate.getTime()) : null,
        egt1: 0, egt2: 0, egt3: 0, egt4: 0, egt5: 0, egt6: 0,
        cht1: 0, cht2: 0, cht3: 0, cht4: 0, cht5: 0, cht6: 0,
        cld: 0, oilT: 0, mark: 0, oilP: 0, crb: 0,
        volt: 0, oat: 0, usd: 0, ff: 0, hp: 0,
        map: 0, rpm: 0, hours: 0, alt: 0, gspd: 0,
        lat: null, long: null,
      };

      for (const [key, index] of Object.entries(FIELD_LABELS)) {
        if (Array.isArray(index)) {
          const low = newValues[index[0]];
          const high = newValues[index[1]];
          record[key] = low + (high << 8);
        } else {
          record[key] = newValues[index];
        }
      }

      // Handle GPS lat/long - 16-bit deltas from initial position
      const longLoChanged = expandedFieldFlags[GPS_LONG_INDEX] !== 0;
      const latLoChanged = expandedFieldFlags[GPS_LAT_INDEX] !== 0;
      const longHiChanged = expandedFieldFlags[GPS_LONG_HIGH_INDEX] !== 0;
      const latHiChanged = expandedFieldFlags[GPS_LAT_HIGH_INDEX] !== 0;

      // Compute 16-bit GPS deltas from raw bytes
      if (longLoChanged) {
        const longLo = gpsRawDeltas[GPS_LONG_INDEX] ?? 0;
        const longHi = longHiChanged ? (gpsRawDeltas[GPS_LONG_HIGH_INDEX] ?? 0) : 0;
        let longDelta = longHiChanged ? ((longHi << 8) | longLo) : longLo;
        if (expandedSignFlags[GPS_LONG_INDEX] !== 0) {
          longDelta = -longDelta;
        }
        this.gpsLongCumulative += longDelta;
      }

      if (latLoChanged) {
        const latLo = gpsRawDeltas[GPS_LAT_INDEX] ?? 0;
        const latHi = latHiChanged ? (gpsRawDeltas[GPS_LAT_HIGH_INDEX] ?? 0) : 0;
        let latDelta = latHiChanged ? ((latHi << 8) | latLo) : latLo;
        if (expandedSignFlags[GPS_LAT_INDEX] !== 0) {
          latDelta = -latDelta;
        }
        this.gpsLatCumulative += latDelta;
      }

      this.processGpsRecord(record, this.gpsLongCumulative, this.gpsLatCumulative,
                            longLoChanged, latLoChanged);

      // GSPD bug workaround (stuck at 150 when no GPS)
      if (record.gspd === 150 && gspdBug) {
        record.gspd = 0;
      } else if (record.gspd > 0) {
        gspdBug = false;
      }

      // Clamp negative GSPD
      if (record.gspd < 0) {
        record.gspd = 0;
      }

      // Temperature conversion
      this.applyTemperatureConversion(record);

      // Fuel flow scaling: stored as gph × 10
      if (record.ff > 0) {
        record.ff = Math.round((record.ff / 10) * 10) / 10;
      }

      // Voltage scaling: stored as volts × 10
      if (record.volt > 0) {
        record.volt = Math.round((record.volt / 10) * 10) / 10;
      }

      this.records.push(record);

      if (currentDate) {
        currentDate = new Date(currentDate.getTime() + this.intervalSecs * 1000);
      }
    }
  }

  private isFahrenheit(): boolean {
    // Bit 28 indicates Fahrenheit (1=F, 0=C)
    return ((this.flags >> 28) & 1) === 1;
  }

  private applyTemperatureConversion(record: FlightRecord): void {
    if (this.temperatureUnit === 'original') {
      return;
    }

    if (this.temperatureUnit === 'celsius' && this.isFahrenheit()) {
      this.convertTempsToCelsius(record);
    } else if (this.temperatureUnit === 'fahrenheit' && !this.isFahrenheit()) {
      this.convertTempsToFahrenheit(record);
    }
  }

  private convertTempsToCelsius(record: FlightRecord): void {
    for (const field of TEMP_FIELDS) {
      const val = record[field];
      if (typeof val === 'number' && val !== 0) {
        record[field] = Math.round(((val - 32) * 5 / 9) * 10) / 10;
      }
    }
  }

  private convertTempsToFahrenheit(record: FlightRecord): void {
    for (const field of TEMP_FIELDS) {
      const val = record[field];
      if (typeof val === 'number' && val !== 0) {
        record[field] = Math.round(((val * 9 / 5) + 32) * 10) / 10;
      }
    }
  }

  private processGpsRecord(
    record: FlightRecord,
    gpsLongValue: number,
    gpsLatValue: number,
    _longChanged: boolean,
    _latChanged: boolean
  ): void {
    // No header GPS = no GPS output
    if (this.initialLat === null || this.initialLong === null) {
      record.lat = null;
      record.long = null;
      return;
    }

    // Detect junk "Kansas" GPS header
    this.kansasJunkHeader = (
      Math.abs(this.initialLat - 39.05) < 0.1 &&
      Math.abs(this.initialLong - (-94.88)) < 0.1
    );

    // Value of 0 means no GPS data yet
    if (gpsLongValue === 0 && gpsLatValue === 0) {
      record.lat = null;
      record.long = null;
      this.gpsStableCount = 0;
      this.lastGoodGpsLong = null;
      this.lastGoodGpsLat = null;
      this.gpsCandidateLat = null;
      this.gpsCandidateLong = null;
      return;
    }

    // GPS values are 16-bit cumulative values (accumulated from DEFAULT_VALUE = 240)
    const latOffset = (gpsLatValue - DEFAULT_VALUE) / 6000;
    const longOffset = (gpsLongValue - DEFAULT_VALUE) / 6000;
    const lat = this.initialLat + latOffset;
    const long = this.initialLong + longOffset;

    const maxJump = 0.02; // ~1.3 miles - max reasonable change per interval

    // Current position is "Kansas-like" if it's near the header position
    const isKansasPosition = this.kansasJunkHeader &&
      Math.abs(lat - 39.05) < 5 && Math.abs(long - (-94.88)) < 5;

    // Allow large jumps if we have Kansas header and haven't established stable non-Kansas GPS yet
    const allowLargeJump = this.kansasJunkHeader && this.gpsNonKansasCount < 50;

    if (this.gpsCandidateLat !== null && this.gpsCandidateLong !== null) {
      // Compare to previous candidate reading
      const latJump = Math.abs(lat - this.gpsCandidateLat);
      const longJump = Math.abs(long - this.gpsCandidateLong);

      if (!allowLargeJump && (latJump > maxJump || longJump > maxJump)) {
        // Position jumped from candidate - junk data, start over
        this.gpsStableCount = 1;
        this.gpsCandidateLat = lat;
        this.gpsCandidateLong = long;
        record.lat = null;
        record.long = null;
        return;
      }

      // Similar to candidate (or large jump allowed during acquisition)
      this.gpsStableCount += 1;
    } else {
      // First reading - save as candidate
      this.gpsStableCount = 1;
      this.gpsCandidateLat = lat;
      this.gpsCandidateLong = long;
      record.lat = null;
      record.long = null;
      return;
    }

    // Require 2+ consecutive similar readings
    if (this.gpsStableCount < 2) {
      this.gpsCandidateLat = lat;
      this.gpsCandidateLong = long;
      record.lat = null;
      record.long = null;
      return;
    }

    // Check continuity with last output
    if (!allowLargeJump && this.gpsNonKansasCount >= 50 &&
        this.lastGoodGpsLat !== null && this.lastGoodGpsLong !== null) {
      const latJump = Math.abs(lat - this.lastGoodGpsLat);
      const longJump = Math.abs(long - this.lastGoodGpsLong);
      if (latJump > maxJump || longJump > maxJump) {
        // Jump from last output - might be re-acquiring, reset
        this.gpsStableCount = 1;
        this.gpsCandidateLat = lat;
        this.gpsCandidateLong = long;
        record.lat = null;
        record.long = null;
        return;
      }
    }

    // GPS is good - output and save
    this.gpsOutputCount += 1;
    if (!isKansasPosition) {
      this.gpsNonKansasCount += 1;
    }
    this.lastGoodGpsLat = lat;
    this.lastGoodGpsLong = long;
    this.gpsCandidateLat = lat;
    this.gpsCandidateLong = long;
    record.lat = Math.round(lat * 1000000) / 1000000;
    record.long = Math.round(long * 1000000) / 1000000;
  }
}
