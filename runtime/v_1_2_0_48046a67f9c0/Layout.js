// Pure helpers for the eusener.displays panel: modes, scales and the
// arrangement map. No QML here so the Node tests in tests/ can load it.

// "2880x1800@90.00Hz" -> { width, height, hz, mode: "2880x1800@90.00" }
function parseMode(text) {
  var m = /^(\d+)x(\d+)@([\d.]+)(Hz)?$/.exec(String(text || "").trim())
  if (!m) return null
  return { width: +m[1], height: +m[2], hz: +m[3], mode: m[1] + "x" + m[2] + "@" + m[3] }
}

// Distinct resolutions, largest first.
function resolutions(modes) {
  var seen = {}
  var out = []
  for (var i = 0; i < (modes || []).length; i++) {
    var p = parseMode(modes[i])
    if (!p) continue
    var key = p.width + "x" + p.height
    if (seen[key]) continue
    seen[key] = true
    out.push({ key: key, width: p.width, height: p.height })
  }
  out.sort(function (a, b) { return b.width * b.height - a.width * a.height || b.width - a.width })
  return out.map(function (r) { return r.key })
}

// Refresh rates offered for one resolution, highest first, as mode strings.
function ratesFor(modes, resolution) {
  var out = []
  for (var i = 0; i < (modes || []).length; i++) {
    var p = parseMode(modes[i])
    if (p && p.width + "x" + p.height === resolution) out.push(p)
  }
  out.sort(function (a, b) { return b.hz - a.hz })
  return out
}

function modeSize(mode, fallbackW, fallbackH) {
  var m = /^(\d+)x(\d+)/.exec(String(mode || ""))
  return m ? { width: +m[1], height: +m[2] } : { width: fallbackW || 0, height: fallbackH || 0 }
}

function modeHz(mode) {
  var m = /@([\d.]+)/.exec(String(mode || ""))
  return m ? +m[1] : 0
}

function formatHz(hz) {
  var n = Math.round(Number(hz) * 100) / 100
  return (Math.abs(n - Math.round(n)) < 0.02 ? String(Math.round(n)) : n.toFixed(2)) + " Hz"
}

var CUSTOM_MODE = /^\d{3,5}x\d{3,5}@\d{1,3}(\.\d{1,5})?$/
function validCustomMode(text) { return CUSTOM_MODE.test(String(text || "").trim()) }

function gcd(a, b) {
  while (b) { var t = a % b; a = b; b = t }
  return a
}

// Hyprland only takes scales where the mode divides into whole logical pixels
// in 1/120 steps; round up to the next clean one (as Omarchy does).
function cleanScale(scale, width, height) {
  var s = Number(scale)
  if (!(s > 0) || !(width > 0) || !(height > 0)) return s
  var g = gcd(Math.round(width * 120), Math.round(height * 120))
  var k = Math.max(1, Math.min(Math.round(s * 120), g))
  while (g % k !== 0) k++
  return Math.round(k / 120 * 1e6) / 1e6
}

// Every clean scale between min and max for a mode.
function validScales(width, height, min, max) {
  var lo = Math.round((min || 1) * 120)
  var hi = Math.round((max || 3) * 120)
  if (!(width > 0) || !(height > 0)) return [1, 1.25, 1.5, 2, 3]
  var g = gcd(Math.round(width * 120), Math.round(height * 120))
  var out = []
  for (var k = lo; k <= hi; k++) if (g % k === 0) out.push(Math.round(k / 120 * 1e6) / 1e6)
  return out
}

function formatScale(s) {
  var n = Number(s)
  return String(Math.round(n * 1000) / 1000)
}

// Logical size of a monitor on the desktop: mode / scale, swapped when rotated.
function logicalSize(spec, fallbackW, fallbackH) {
  var size = modeSize(spec.mode, fallbackW, fallbackH)
  var scale = cleanScale(spec.scale || 1, size.width, size.height) || 1
  var w = Math.round(size.width / scale)
  var h = Math.round(size.height / scale)
  if ((spec.transform || 0) % 2 === 1) { var t = w; w = h; h = t }
  return { width: w, height: h }
}

function overlaps(a, b) {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

// Snap a dropped rect against the others: it attaches to the nearest side of
// some other rect, sliding along that side (kept touching) and clicking into
// edge/centre alignment when close. Returns {x, y}. `others` are rects with
// x, y, width, height in desktop pixels; `threshold` is in the same units.
function snap(rect, others, threshold) {
  if (!others.length) return { x: 0, y: 0 }
  var th = threshold || 40
  var best = null
  function consider(x, y) {
    var cand = { x: Math.round(x), y: Math.round(y), width: rect.width, height: rect.height }
    for (var j = 0; j < others.length; j++) if (overlaps(cand, others[j])) return
    var d = Math.abs(cand.x - rect.x) + Math.abs(cand.y - rect.y)
    if (!best || d < best.d) best = { x: cand.x, y: cand.y, d: d }
  }
  function alignAlong(pos, size, oPos, oSize) {
    var targets = [oPos, oPos + oSize - size, oPos + (oSize - size) / 2]
    for (var t = 0; t < targets.length; t++) if (Math.abs(pos - targets[t]) <= th) return targets[t]
    // Keep at least some shared edge so the monitors stay connected.
    return clamp(pos, oPos - size + 1, oPos + oSize - 1)
  }
  for (var i = 0; i < others.length; i++) {
    var o = others[i]
    var y = alignAlong(rect.y, rect.height, o.y, o.height)
    var x = alignAlong(rect.x, rect.width, o.x, o.width)
    consider(o.x + o.width, y)        // right of o
    consider(o.x - rect.width, y)     // left of o
    consider(x, o.y + o.height)       // below o
    consider(x, o.y - rect.height)    // above o
  }
  return best ? { x: best.x, y: best.y } : { x: rect.x, y: rect.y }
}

// Shift every position so the primary monitor sits at 0x0.
function normalize(positions, primary) {
  var p = positions[primary]
  if (!p) return positions
  var out = {}
  for (var k in positions) out[k] = { x: positions[k].x - p.x, y: positions[k].y - p.y }
  return out
}

// Initial layout for monitors left at "auto": a row, left to right.
function autoRow(rects) {
  var x = 0
  var out = {}
  for (var i = 0; i < rects.length; i++) {
    out[rects[i].name] = { x: x, y: 0 }
    x += rects[i].width
  }
  return out
}

// Any two rects overlapping, or a rect not touching the rest?
function layoutProblems(rects) {
  for (var i = 0; i < rects.length; i++)
    for (var j = i + 1; j < rects.length; j++)
      if (overlaps(rects[i], rects[j])) return "overlap"
  return ""
}

var CM_PRESETS = ["auto", "srgb", "wide", "edid", "dcip3", "dp3", "adobe", "hdr", "hdredid"]

function kindGlyph(kind) {
  if (kind === "internal") return "󰌢"
  if (kind === "hdmi") return "󰡁"
  if (kind === "dp") return "󰍹"
  return "󰍹"
}

function diagonalInches(mmW, mmH) {
  if (!(mmW > 0) || !(mmH > 0)) return 0
  return Math.round(Math.sqrt(mmW * mmW + mmH * mmH) / 25.4 * 10) / 10
}

if (typeof module !== "undefined") {
  module.exports = {
    parseMode: parseMode, resolutions: resolutions, ratesFor: ratesFor, modeSize: modeSize,
    modeHz: modeHz, formatHz: formatHz, validCustomMode: validCustomMode, cleanScale: cleanScale,
    validScales: validScales, formatScale: formatScale, logicalSize: logicalSize, overlaps: overlaps,
    snap: snap, normalize: normalize, autoRow: autoRow, layoutProblems: layoutProblems,
    CM_PRESETS: CM_PRESETS, kindGlyph: kindGlyph, diagonalInches: diagonalInches
  }
}
