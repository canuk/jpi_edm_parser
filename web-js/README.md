# JPI EDM Parser - Browser Edition

A zero-build, browser-based parser for JPI Engine Data Management (EDM) files. Convert your `.JPI` files to CSV entirely client-side - no server upload required.

## Features

- **Zero Build**: Pure ES modules - just serve the files, no compilation needed
- **100% Client-Side**: All parsing happens in your browser. Your data never leaves your device.
- **Rails Importmaps Ready**: Works directly with Rails importmaps
- **Multiple Flight Support**: Parse files containing multiple flights and download them individually or as a ZIP
- **GPS Data**: Extracts GPS coordinates when available
- **Temperature Conversion**: Supports Fahrenheit and Celsius output

## Quick Start

Just open `index.html` in a browser (needs a local server for ES modules):

```bash
# Using Python
python -m http.server 8000

# Using Ruby
ruby -run -e httpd . -p 8000

# Using Node
npx serve
```

Then open http://localhost:8000

## Rails Integration (Importmaps)

1. Copy the `src/` files to your Rails app:
   ```bash
   cp -r src/* app/javascript/jpi_parser/
   ```

2. Pin the modules in `config/importmap.rb`:
   ```ruby
   pin "jpi_parser", to: "jpi_parser/index.js"
   pin "jpi_parser/parser", to: "jpi_parser/parser.js"
   pin "jpi_parser/flight", to: "jpi_parser/flight.js"
   pin "jpi_parser/header-parser", to: "jpi_parser/header-parser.js"
   pin "jszip", to: "https://cdn.jsdelivr.net/npm/jszip@3.10.1/+esm"
   ```

3. Use in your JavaScript:
   ```javascript
   import { JpiEdmParser } from "jpi_parser"

   const parser = await JpiEdmParser.fromFile(file)
   console.log(parser.tailNumber)  // "N73898"
   ```

## API Usage

```javascript
import { JpiEdmParser } from './src/index.js';

// From a File object (browser)
const parser = await JpiEdmParser.fromFile(file);

// From an ArrayBuffer
const parser = JpiEdmParser.fromArrayBuffer(buffer);

// Access metadata
console.log(parser.tailNumber);     // "N73898"
console.log(parser.modelString);    // "EDM-830"
console.log(parser.flightCount);    // 20

// Iterate flights
for (const flight of parser.flights) {
  console.log(flight.flightNumber, flight.date, flight.durationHours);
  console.log(flight.hasGps);  // true/false

  // Export to CSV
  const csv = flight.toCsv();
}
```

## File Structure

```
├── index.html          # Standalone web app
├── src/
│   ├── index.js        # Main entry point
│   ├── parser.js       # JpiEdmParser class
│   ├── flight.js       # Flight parsing and CSV export
│   ├── header-parser.js # ASCII header parsing
│   └── app.js          # Web UI (optional)
```

## Technical Notes

This is a JavaScript implementation of the [Ruby JPI EDM Parser gem](https://github.com/canuk/jpi_edm_parser). It implements:

- ASCII header parsing with XOR checksum verification
- Binary delta-compressed flight data decoding
- 16-bit GPS delta accumulation for large position changes
- GPS stability filtering for reliable coordinates
- Temperature unit conversion (F↔C)
- Voltage and fuel flow scaling

## Browser Support

Works in all modern browsers that support:
- ES Modules
- Import Maps
- ArrayBuffer / DataView
- TextDecoder

## License

MIT
