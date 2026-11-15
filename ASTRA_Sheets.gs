/**
 * ASTRA ↔ Google Sheets bridge (Google Apps Script web app)
 *
 * Setup
 *  1. Create a new Google Sheet.
 *  2. Extensions → Apps Script → delete the default code and paste this file.
 *  3. Change TOKEN below to a secret string known only to your team, then save.
 *     Enter the same token in the app (Data tab → Google Sheets).
 *  4. Deploy → New deployment → Type: Web app → Execute as: Me → Who has access: Anyone → Deploy.
 *  5. Approve the permissions (Advanced → Go to project → Allow if a warning appears).
 *  6. Copy the Web app URL (ends with /exec) into the app (Data tab → Google Sheets).
 *  Note: after editing this code, use Deploy → Manage deployments → Edit → Version: New version → Deploy.
 *  Do not publish the token in a public repository.
 *
 * Behavior
 *  - App → Sheet (POST): appends new records to the 'records' sheet; rows with an existing id are skipped.
 *  - When a person edits value, note, or reliability, that row's 'edited' cell becomes TRUE automatically.
 *  - Sheet → App (GET ?editedOnly=1): returns only edited rows; the app applies them to records with the same id.
 *    Edited values outside the physiological plausibility range are rejected by the app.
 *  - Browser test: open <Web app URL>?token=<TOKEN> to see stored rows as JSON.
 */

const TOKEN = 'change-this-team-secret';
const SHEET_NAME = 'records';
const HEADERS = [
  'timestamp_utc', 'metric_label', 'value', 'unit', 'note', 'reliability',
  'provenance', 'source', 'source_kind', 'device', 'context', 'metric', 'start_utc', 'id', 'edited'
];
const SCENARIO_SHEET = 'scenario';   // simulation dataset tab (one row per time point)
const COL = Object.fromEntries(HEADERS.map((h, i) => [h, i]));   // column name → zero-based index

function sheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(SHEET_NAME);
  if (!sh) {
    sh = ss.insertSheet(SHEET_NAME);
    sh.appendRow(HEADERS);
    sh.setFrozenRows(1);
  }
  return sh;
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function provenance_(sourceKind) {
  if (String(sourceKind).indexOf('simulated') === 0) return 'Simulated';
  if (sourceKind === 'manual') return 'Manual entry';
  return 'Measured';
}

/** App → Sheet: append records */
function doPost(e) {
  let body;
  try {
    body = JSON.parse(e.postData.contents);
  } catch (err) {
    return json_({ ok: false, error: 'Request body is not valid JSON' });
  }
  if (body.token !== TOKEN) return json_({ ok: false, error: 'Invalid token' });

  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const sh = sheet_();
    const last = sh.getLastRow();
    const existing = new Set(
      last > 1 ? sh.getRange(2, COL.id + 1, last - 1, 1).getValues().flat() : []
    );
    const rows = (body.records || [])
      .filter(r => r.id && !existing.has(r.id))
      .map(r => {
        const row = new Array(HEADERS.length).fill('');
        row[COL.timestamp_utc] = r.end;
        row[COL.metric_label] = r.metricLabel;
        row[COL.value] = r.value;
        row[COL.unit] = r.unit;
        row[COL.note] = r.note || '';
        row[COL.reliability] = r.reliability;
        row[COL.provenance] = provenance_(r.sourceKind);
        row[COL.source] = r.sourceName;
        row[COL.source_kind] = r.sourceKind;
        row[COL.device] = r.deviceModel || '';
        row[COL.context] = r.context || '';
        row[COL.metric] = r.metric;
        row[COL.start_utc] = r.start;
        row[COL.id] = r.id;
        row[COL.edited] = false;
        return row;
      });
    if (rows.length) {
      sh.getRange(sh.getLastRow() + 1, 1, rows.length, HEADERS.length).setValues(rows);
    }
    return json_({ ok: true, added: rows.length });
  } finally {
    lock.releaseLock();
  }
}

/** Sheet → App: read rows (editedOnly=1 returns only rows a person changed; sheet=scenario returns the scenario tab) */
function doGet(e) {
  if (e.parameter.token !== TOKEN) return json_({ ok: false, error: 'Invalid token' });
  if (e.parameter.sheet === 'scenario') {
    const sc = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SCENARIO_SHEET);
    if (!sc) return json_({ ok: false, error: "No tab named '" + SCENARIO_SHEET + "'. Run setupScenarioSheet() once." });
    // Display values keep text such as "118/78" and "36.7°C" exactly as typed.
    return json_({ ok: true, values: sc.getDataRange().getDisplayValues() });
  }
  const values = sheet_().getDataRange().getValues();
  const header = values.shift();
  const editedOnly = e.parameter.editedOnly === '1';
  const rows = values
    .filter(r => r[COL.id])
    .filter(r => !editedOnly || r[COL.edited] === true || r[COL.edited] === 'TRUE')
    .map(r => Object.fromEntries(header.map((h, i) => [h, r[i]])));
  return json_({ ok: true, rows: rows });
}

/** Marks a row edited=TRUE when a person changes it (values written by the script do not trigger this). */
function onEdit(e) {
  const sh = e.range.getSheet();
  if (sh.getName() !== SHEET_NAME || e.range.getRow() === 1) return;
  if (e.range.getColumn() === COL.edited + 1) return;
  sh.getRange(e.range.getRow(), COL.edited + 1, e.range.getNumRows(), 1).setValue(true);
}

/**
 * Run once from the Apps Script editor (select setupScenarioSheet ▸ Run) to create an example 'scenario' tab.
 * Values are illustrative test data, not medical targets. Edit, add, or delete rows freely; ASTRA validates every value.
 * Columns ASTRA recognizes: Timestamp (or Minute), Heart Rate, Blood Pressure (120/80), Systolic, Diastolic, SpO2,
 * Temperature (°C), Respiratory Rate, HRV, Glucose, Cabin Pressure (kPa). Leave a cell empty for a missing measurement.
 */
function setupScenarioSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sc = ss.getSheetByName(SCENARIO_SHEET);
  if (!sc) sc = ss.insertSheet(SCENARIO_SHEET);
  sc.clear();
  const rows = [
    ['Timestamp', 'Heart Rate', 'Blood Pressure', 'SpO2', 'Temperature', 'Respiratory Rate'],
    ['09:00', '72 bpm', '118/78 mmHg', '98%', '36.7°C', '14'],
    ['09:05', '85 bpm', '125/82 mmHg', '97%', '36.8°C', '15'],
    ['09:10', '105 bpm', '145/95 mmHg', '95%', '37.0°C', '18'],
    ['09:15', '120 bpm', '160/100 mmHg', '93%', '37.2°C', '22']
  ];
  sc.getRange(1, 1, rows.length, rows[0].length).setNumberFormat('@').setValues(rows);
  sc.setFrozenRows(1);
}
