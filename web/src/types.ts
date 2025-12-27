// Type definitions for JPI EDM Parser

export interface Config {
  model: number;
  flagsLow: number;
  flagsHigh: number;
  unknown1?: number;
  unknown2?: number;
  unknown3?: number;
  unknown4?: number;
  unknown5?: number;
  unknown6?: number;
}

export interface AlarmLimits {
  voltsHigh: number;
  voltsLow: number;
  dif: number;
  cht: number;
  cld: number;
  tit: number;
  oilHigh: number;
  oilLow: number;
}

export interface FuelConfig {
  emptyWarning: number;
  fullCapacity: number;
  warningLevel: number;
  kFactor1: number;
  kFactor2: number;
}

export interface FlightIndex {
  flightNumber: number;
  dataWords: number;
  dataLength: number; // dataWords * 2
}

export interface Timestamp {
  month: number;
  day: number;
  year: number;
  hour: number;
  minute: number;
  unknown?: number;
}

export type TemperatureUnit = 'original' | 'celsius' | 'fahrenheit';

export interface FlightRecord {
  [key: string]: Date | number | null;
  date: Date | null;
  egt1: number;
  egt2: number;
  egt3: number;
  egt4: number;
  egt5: number;
  egt6: number;
  cht1: number;
  cht2: number;
  cht3: number;
  cht4: number;
  cht5: number;
  cht6: number;
  cld: number;
  oilT: number;
  mark: number;
  oilP: number;
  crb: number;
  volt: number;
  oat: number;
  usd: number;
  ff: number;
  hp: number;
  map: number;
  rpm: number;
  hours: number;
  alt: number;
  gspd: number;
  lat: number | null;
  long: number | null;
}

export interface ParsedHeader {
  tailNumber: string | null;
  config: Config | null;
  alarmLimits: AlarmLimits | null;
  fuelConfig: FuelConfig | null;
  flights: FlightIndex[];
  timestamp: Timestamp | null;
  binaryOffset: number;
}
