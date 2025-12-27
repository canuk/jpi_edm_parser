# JPI EDM Parser - Browser Edition

A browser-based parser for JPI Engine Data Management (EDM) files. Convert your `.JPI` files to CSV entirely client-side - no server upload required.

## Features

- **100% Client-Side**: All parsing happens in your browser. Your data never leaves your device.
- **Multiple Flight Support**: Parse files containing multiple flights and download them individually or as a ZIP.
- **GPS Data**: Extracts GPS coordinates when available.
- **Temperature Conversion**: Supports Fahrenheit and Celsius output.

## Usage

### As a Web App

1. Install dependencies: `npm install`
2. Start dev server: `npm run dev`
3. Open http://localhost:3000
4. Drag and drop your `.JPI` file

### As a Library

```typescript
import { JpiEdmParser } from 'jpi-edm-parser-web';

// From a File object (browser)
const parser = await JpiEdmParser.fromFile(file);

// From an ArrayBuffer
const parser = JpiEdmParser.fromArrayBuffer(buffer);

// Access data
console.log(parser.tailNumber);     // "N73898"
console.log(parser.modelString);    // "EDM-830"
console.log(parser.flightCount);    // 20

// Iterate flights
for (const flight of parser.flights) {
  console.log(flight.flightNumber, flight.date, flight.durationHours);

  // Export to CSV
  const csv = flight.toCsv();
}
```

## Building

```bash
npm install
npm run build
```

The built files will be in the `dist/` directory, ready for static hosting.

## Technical Notes

This is a TypeScript port of the [Ruby JPI EDM Parser gem](../). It implements:

- ASCII header parsing with checksum verification
- Binary delta-compressed flight data decoding
- 16-bit GPS delta accumulation
- GPS stability filtering for reliable coordinates
- Temperature unit conversion
- Voltage and fuel flow scaling

## License

MIT
