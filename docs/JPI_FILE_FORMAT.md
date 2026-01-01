# JPI EDM File Format Specification

This document describes the JPI EDM binary file format as independently determined through analysis of JPI data files and publicly available documentation.

## Document Status

This specification was derived through:
1. Analysis of real JPI data files owned by the author
2. Public forum discussions about the format
3. General knowledge of binary file format conventions

## Overview

JPI EDM files consist of two main sections:
1. **ASCII Header Section** - Configuration and flight index
2. **Binary Data Section** - Compressed flight data records

## ASCII Header Section

Headers are ASCII text lines terminated by CR+LF (`\r\n`). Each header:
- Starts with `$` followed by a record type letter
- Contains comma-separated fields
- Ends with `*XX` where XX is a two-digit hex checksum

### Checksum Calculation

The checksum is the XOR of all bytes between `$` (exclusive) and `*` (exclusive).

```ruby
def calculate_checksum(line)
  # line includes $ at start, find content between $ and *
  content = line[1...line.index('*')]
  content.bytes.reduce(0) { |xor, byte| xor ^ byte }
end
```

### Header Record Types

#### $U - Aircraft Identification (Tail Number)
```
$U, N73898*2A
```
- Field 1: Tail number (may have trailing spaces)

#### $A - Alarm Limits
```
$A, 160, 120, 500, 450, 60, 1650, 230, 90*7D
```
- Field 1: Volts High × 10 (16.0V)
- Field 2: Volts Low × 10 (12.0V)
- Field 3: DIF alarm (°F)
- Field 4: CHT alarm (°F)
- Field 5: CLD (shock cooling) alarm (°F/min)
- Field 6: TIT alarm (°F)
- Field 7: Oil High (°F)
- Field 8: Oil Low (°F)

#### $F - Fuel Configuration
```
$F,0,40,0,2146,2990*6D
```
- Field 1: Empty/warning threshold
- Field 2: Full capacity
- Field 3: Warning level
- Field 4: K-factor 1
- Field 5: K-factor 2

#### $T - Download Timestamp (UTC)
```
$T, 12, 22, 25, 1, 46, 24833*5D
```
- Field 1: Month
- Field 2: Day
- Field 3: Year (2-digit)
- Field 4: Hour
- Field 5: Minute
- Field 6: Unknown (possibly sequence number)

#### $C - Configuration
```
$C,830,30781,23552,1024,25826,120,140,2014,2*55
```
- Field 1: Model number (830 = EDM-830)
- Field 2: Feature flags low word
- Field 3: Feature flags high word
- Field 4: Unknown flags
- Field 5: Unknown (possibly extended flags)
- Field 6-8: Additional configuration
- Field 9: Unknown

The feature flags indicate which data fields are recorded.

#### $P - Unknown
```
$P, 2*6E
```
Purpose not yet determined.

#### $H - Unknown
```
$H,0*54
```
Purpose not yet determined.

#### $D - Flight Directory Entry
```
$D, 1196, 3387*44
```
- Field 1: Flight number
- Field 2: Data length in 16-bit words

Multiple $D records appear, one per flight stored in the file.

#### $L - End of Headers
```
$L, 7594*4F
```
- Field 1: Unknown meaning

Binary data immediately follows this record.

## Binary Data Section

### Flight Position Calculation

**Important:** The `data_words` value in $D records represents **word-aligned counts**:

```
data_words = ceiling(actual_bytes / 2)
```

This means:
- When actual flight data length is **ODD**, `data_words * 2 = actual + 1`
- When actual flight data length is **EVEN**, `data_words * 2 = actual`
- The discrepancy is **ALWAYS 0 or 1 byte**, never more

**Algorithm for finding flight positions:**

1. Start at `binaryOffset` (immediately after `$L` header line)
2. For each flight in order:
   a. Calculate expected position based on cumulative `data_words * 2` of previous flights
   b. Check **both** the expected position AND expected-1 for valid flight header
   c. Validate by matching flight number + checking date/time/interval fields
   d. Advance position by found offset + `data_words * 2`

**Why this matters:**

This is bounded checking (exactly 2 positions) rather than arbitrary searching. Without this
understanding, parsers may fail to locate flights that start at position-1 due to the odd-length
rounding. The issue typically manifests as "flight not found" errors for files with multiple
flights where some have odd-length data.

**Example:**

If flight 125 has `data_words = 683`:
- Expected data length = 683 × 2 = 1366 bytes
- But actual data might be 1365 bytes (odd)
- Next flight starts at position 1365, not 1366
- Parser must check both positions to find it

### Flight Header (28 bytes for extended format)

Each flight's data begins with a header. The header size varies by EDM model and firmware version.

#### Standard Header (14 words = 28 bytes, big-endian)

| Word | Field | Description |
|------|-------|-------------|
| 0 | flight_num | Flight number (matches $D record) |
| 1-2 | flags | Configuration flags (32-bit, word 1 = low, word 2 = high) |
| 3 | unknown[0] | Unknown/config value |
| 4 | unknown[1] | Unknown/config value |
| 5 | unknown[2] | Unknown/config value |
| 6 | lat_high | Initial GPS latitude, high 16 bits (see GPS section) |
| 7 | lat_low | Initial GPS latitude, low 16 bits |
| 8 | long_high | Initial GPS longitude, high 16 bits |
| 9 | long_low | Initial GPS longitude, low 16 bits |
| 10 | unknown[7] | Unknown/config value |
| 11 | interval | Recording interval in seconds |
| 12 | date | Packed date (see below) |
| 13 | time | Packed time (see below) |

**Note:** Words 6-9 contain initial GPS coordinates when GPS is connected. If no GPS is present, these fields may contain other configuration data or zeros.

#### Configuration Flags (32-bit)

Bit 28 indicates temperature unit: 1 = Fahrenheit, 0 = Celsius.

### Date/Time Packing

**Date field (16 bits):**
```
Bits 0-4:   Day (1-31)
Bits 5-8:   Month (1-12)
Bits 9-15:  Year (offset from 2000 or 1900)
```

**Time field (16 bits):**
```
Bits 0-4:   Seconds ÷ 2 (0-29 representing 0-58 seconds)
Bits 5-10:  Minutes (0-59)
Bits 11-15: Hours (0-23)
```

### Data Records

Flight data uses delta compression. Each record contains only the *changes* from the previous record.

#### Record Structure

```
decode_flags[2]   - Which field groups are present (2 bytes, typically identical)
repeat_count      - Number of times to repeat previous record
field_flags[0-5]  - Which fields in each group changed (conditional)
scale_flags[0-1]  - High-byte present for EGT fields (conditional)
sign_flags[0-5]   - Add or subtract the delta (conditional)
field_deltas[]    - The actual delta values (conditional)
scale_deltas[]    - High bytes for 16-bit deltas (conditional)
checksum          - 1 byte checksum
```

#### Decode Flags

The decode_flags bytes indicate which groups of 8 fields are present:
- Bit 0-5: field_flags[0-5] and sign_flags[0-5] present
- Bit 6-7: scale_flags[0-1] present

#### Initial Values

All fields are initialized to 0xF0 (240) before the first record.

#### Applying Deltas

For each field where the corresponding bit is set in field_flags:
1. Read the delta byte
2. If sign_flags bit is set: subtract delta from current value
3. If sign_flags bit is clear: add delta to current value
4. If scale_flags bit is set: also read high byte and apply (value << 8)

### Data Fields Layout

The data is conceptually an array of 48+ 16-bit values. Field assignments vary by model.

#### EDM 730/830 Field Layout (estimated)

| Index | Field | Description |
|-------|-------|-------------|
| 0-3 | EGT1-4 | Exhaust Gas Temps (°F) |
| 4-5 | T1, T2 | TIT probes (°F) |
| 6-7 | Reserved | |
| 8-11 | CHT1-4 | Cylinder Head Temps (°F) |
| 12 | CLD | Cooling rate |
| 13 | OIL | Oil temperature (°F) |
| 14 | MARK | Event marker |
| 15 | Unknown | |
| 16 | CDT | Compressor Discharge Temp |
| 17 | IAT | Induction Air Temp |
| 18 | BAT | Battery voltage × 10 |
| 19 | OAT | Outside Air Temp (°F) |
| 20 | USD | Fuel used × 10 |
| 21 | FF | Fuel flow × 10 |
| ... | ... | Additional fields |
| 40+ | MAP | Manifold pressure × 10 |
| 41+ | RPM | Engine RPM |
| ... | GPS | Lat, Long, Alt, Ground Speed |

### GPS Data Fields

When GPS is connected to the EDM, GPS data is stored in two places:

#### Initial Position (Flight Header)

The initial GPS position is stored in the flight header as two 32-bit signed integers:

- **Latitude**: words[6] (high) and words[7] (low), combined as `(high << 16) | low`
- **Longitude**: words[8] (high) and words[9] (low), combined as `(high << 16) | low`

**Coordinate Encoding:**
```
decimal_degrees = raw_value / 6000.0
```

This gives a resolution of 1/6000 degree (approximately 18.5 meters at the equator).

**Example:**
```
Raw latitude:  201044  → 201044 / 6000 = 33.507333° N
Raw longitude: -673704 → -673704 / 6000 = -112.284° W
```

#### Position Deltas (Data Records)

Data records contain position deltas at these field indices:

| Index | Field | Description |
|-------|-------|-------------|
| 81 | LONG_HIGH | Longitude delta HIGH BYTE (for 16-bit deltas) |
| 82 | LAT_HIGH | Latitude delta HIGH BYTE (for 16-bit deltas) |
| 83 | ALT | Altitude in feet |
| 85 | GSPD | Ground speed in knots |
| 86 | LONG_DELTA | Longitude delta LOW BYTE (units of 1/6000 degree) |
| 87 | LAT_DELTA | Latitude delta LOW BYTE (units of 1/6000 degree) |

**16-bit GPS Deltas (IMPORTANT):**

GPS position deltas can be either 8-bit or 16-bit values. When the GPS needs to represent large position changes (greater than 255 units = 0.0425 degrees = ~2.9 miles), it uses 16-bit deltas by including high bytes at indices 81 (longitude) and 82 (latitude).

When both high and low byte fields are present in the same record:
```
16-bit delta = (high_byte << 8) | low_byte
```

The sign flag from the LOW byte field (86 or 87) applies to the entire 16-bit value.

This is critical for parsing GPS during acquisition when the unit may report large jumps as it locks onto satellites. A single 16-bit delta can represent up to 65535/6000 = ~10.9 degrees of position change.

**GPS Initialization Signal ("Handshake"):**

When GPS lock is first acquired, both indices 86 and 87 are set to the value ±100. This "handshake" signals that GPS data is now valid.

**Kansas Placeholder Header:**

Some GPS units (notably Garmin 430) temporarily report their headquarters location (39.05°N, -94.88°W - Olathe, Kansas) during initialization before satellite lock. If this value appears in the flight header, subsequent GPS deltas will transition the position from Kansas to the actual location once lock is acquired. This transition typically uses large 16-bit deltas (e.g., ~32000 units latitude + ~65000 units longitude to move from Kansas to California).

**Applying Deltas:**

GPS values are accumulated from an initial baseline of 240 (0xF0), the same as other fields:

```ruby
# Initialize cumulative values
gps_lat_cumulative = 240
gps_long_cumulative = 240

# For each record with GPS changes:
# 1. Read raw delta bytes
long_lo = raw_delta[86]  # low byte
long_hi = raw_delta[81]  # high byte (0 if not present)
lat_lo = raw_delta[87]
lat_hi = raw_delta[82]

# 2. Combine into 16-bit delta if high byte present
long_delta = high_byte_present[81] ? ((long_hi << 8) | long_lo) : long_lo
lat_delta = high_byte_present[82] ? ((lat_hi << 8) | lat_lo) : lat_lo

# 3. Apply sign (from low byte sign flag)
long_delta = -long_delta if sign_flag[86]
lat_delta = -lat_delta if sign_flag[87]

# 4. Accumulate
gps_long_cumulative += long_delta
gps_lat_cumulative += lat_delta

# 5. Convert to degrees
lat = header_lat + (gps_lat_cumulative - 240) / 6000.0
long = header_long + (gps_long_cumulative - 240) / 6000.0
```

**No GPS Connected:**

If no GPS is connected, indices 86 and 87 may still appear in records but will always contain zero deltas. The `has_gps?` method checks for non-zero lat/long values to determine GPS presence.

### Checksum Variants

Two checksum algorithms exist based on firmware version:
- **Old (firmware < 3.00)**: XOR of all bytes
- **New (firmware ≥ 3.00)**: Negative sum of all bytes (two's complement)

```ruby
def checksum_old(bytes)
  bytes.reduce(0) { |xor, b| xor ^ b }
end

def checksum_new(bytes)
  (-bytes.sum) & 0xFF
end
```

## File Identification

JPI files typically have:
- Extension: `.JPI` or `.DAT`
- First bytes: `$U,` (tail number header)

## References

This specification was independently derived through analysis of real JPI data files.

No copyrighted specifications were used in its creation.
