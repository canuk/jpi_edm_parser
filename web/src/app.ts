// Web application for JPI EDM Parser

import { JpiEdmParser, HeaderParseError, ChecksumError } from './parser';
import type { Flight } from './flight';
import JSZip from 'jszip';

// DOM Elements
const dropZone = document.getElementById('drop-zone')!;
const fileInput = document.getElementById('file-input') as HTMLInputElement;
const errorMessage = document.getElementById('error-message')!;
const results = document.getElementById('results')!;
const tailNumberEl = document.getElementById('tail-number')!;
const modelEl = document.getElementById('model')!;
const flightCountEl = document.getElementById('flight-count')!;
const downloadTimeEl = document.getElementById('download-time')!;
const flightsContainer = document.getElementById('flights-container')!;
const downloadAllBtn = document.getElementById('download-all')!;

let currentParser: JpiEdmParser | null = null;

// File handling
function handleFile(file: File) {
  hideError();
  hideResults();

  if (!file.name.toLowerCase().endsWith('.jpi')) {
    showError('Please select a .JPI file');
    return;
  }

  parseFile(file);
}

async function parseFile(file: File) {
  try {
    currentParser = await JpiEdmParser.fromFile(file);
    displayResults(currentParser);
  } catch (e) {
    if (e instanceof HeaderParseError || e instanceof ChecksumError) {
      showError(e.message);
    } else {
      showError(`Error parsing file: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
}

function displayResults(parser: JpiEdmParser) {
  // Update file info
  tailNumberEl.textContent = parser.tailNumber || 'Unknown';
  modelEl.textContent = parser.modelString;
  flightCountEl.textContent = String(parser.flightCount);

  if (parser.downloadTime) {
    downloadTimeEl.textContent = formatDate(parser.downloadTime);
  } else {
    downloadTimeEl.textContent = '-';
  }

  // Build flights list
  flightsContainer.innerHTML = '';

  for (const flight of parser.flights) {
    const row = createFlightRow(flight, parser.tailNumber || 'unknown');
    flightsContainer.appendChild(row);
  }

  showResults();
}

function createFlightRow(flight: Flight, tailNumber: string): HTMLDivElement {
  const row = document.createElement('div');
  row.className = 'flight-row';

  const info = document.createElement('div');
  info.className = 'flight-info';

  // Flight number
  const numSpan = document.createElement('span');
  numSpan.className = 'flight-number';
  numSpan.textContent = `#${flight.flightNumber}`;
  info.appendChild(numSpan);

  // Date
  const dateSpan = document.createElement('span');
  dateSpan.className = 'flight-date';
  dateSpan.textContent = flight.date ? formatDate(flight.date) : 'Unknown date';
  info.appendChild(dateSpan);

  // Duration
  const durationSpan = document.createElement('span');
  durationSpan.className = 'flight-duration';
  if (flight.durationHours > 0) {
    durationSpan.textContent = `${flight.durationHours.toFixed(2)} hrs`;
  } else {
    durationSpan.textContent = '-';
  }
  info.appendChild(durationSpan);

  // GPS indicator
  const gpsSpan = document.createElement('span');
  gpsSpan.className = flight.hasGps ? 'flight-gps' : 'flight-gps no-gps';
  gpsSpan.textContent = flight.hasGps ? 'GPS' : 'No GPS';
  info.appendChild(gpsSpan);

  // Warnings
  if (flight.hasWarnings) {
    const warnSpan = document.createElement('span');
    warnSpan.className = 'flight-warning';
    warnSpan.textContent = `⚠ ${flight.parseWarnings.length} warning(s)`;
    warnSpan.title = flight.parseWarnings.join('\n');
    info.appendChild(warnSpan);
  }

  row.appendChild(info);

  // Download button
  const downloadBtn = document.createElement('button');
  downloadBtn.textContent = 'Download CSV';
  downloadBtn.addEventListener('click', () => downloadFlightCsv(flight, tailNumber));
  row.appendChild(downloadBtn);

  return row;
}

function downloadFlightCsv(flight: Flight, tailNumber: string) {
  const csv = flight.toCsv();
  const filename = generateFilename(tailNumber, flight);
  downloadFile(csv, filename, 'text/csv');
}

function generateFilename(tailNumber: string, flight: Flight): string {
  const safeTail = tailNumber.replace(/[^a-zA-Z0-9]/g, '');
  let datePart = '';
  if (flight.date) {
    const d = flight.date;
    datePart = `_${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
  }
  return `${safeTail}_flight_${flight.flightNumber}${datePart}.csv`;
}

async function downloadAllAsZip() {
  if (!currentParser) return;

  const btn = downloadAllBtn as HTMLButtonElement;
  btn.disabled = true;
  btn.textContent = 'Creating ZIP...';

  try {
    const zip = new JSZip();
    const tailNumber = currentParser.tailNumber || 'unknown';
    const safeTail = tailNumber.replace(/[^a-zA-Z0-9]/g, '');

    for (const flight of currentParser.flights) {
      if (flight.valid) {
        const filename = generateFilename(tailNumber, flight);
        zip.file(filename, flight.toCsv());
      }
    }

    const blob = await zip.generateAsync({ type: 'blob' });
    const zipFilename = `${safeTail}_flights.zip`;
    downloadBlob(blob, zipFilename);
  } catch (e) {
    showError(`Error creating ZIP: ${e instanceof Error ? e.message : String(e)}`);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Download All as ZIP';
  }
}

// Utility functions
function downloadFile(content: string, filename: string, mimeType: string) {
  const blob = new Blob([content], { type: mimeType });
  downloadBlob(blob, filename);
}

function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

function formatDate(date: Date): string {
  return date.toLocaleString();
}

function pad(n: number): string {
  return n.toString().padStart(2, '0');
}

function showError(message: string) {
  errorMessage.textContent = message;
  errorMessage.classList.add('visible');
}

function hideError() {
  errorMessage.classList.remove('visible');
}

function showResults() {
  results.classList.add('visible');
}

function hideResults() {
  results.classList.remove('visible');
}

// Event listeners
dropZone.addEventListener('click', () => fileInput.click());

dropZone.addEventListener('dragover', (e) => {
  e.preventDefault();
  dropZone.classList.add('dragover');
});

dropZone.addEventListener('dragleave', () => {
  dropZone.classList.remove('dragover');
});

dropZone.addEventListener('drop', (e) => {
  e.preventDefault();
  dropZone.classList.remove('dragover');

  const files = e.dataTransfer?.files;
  if (files && files.length > 0) {
    handleFile(files[0]);
  }
});

fileInput.addEventListener('change', () => {
  const files = fileInput.files;
  if (files && files.length > 0) {
    handleFile(files[0]);
  }
});

downloadAllBtn.addEventListener('click', downloadAllAsZip);
