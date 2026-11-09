// node tests/layout.test.js
const assert = require("assert")
const L = require("../Layout.js")

const modes = ["2880x1800@90.00Hz", "2880x1800@60.00Hz", "1920x1080@144.00Hz", "1920x1080@59.94Hz", "bogus"]
assert.deepStrictEqual(L.resolutions(modes), ["2880x1800", "1920x1080"])
assert.deepStrictEqual(L.ratesFor(modes, "1920x1080").map(r => r.mode), ["1920x1080@144.00", "1920x1080@59.94"])
assert.strictEqual(L.formatHz(59.94), "59.94 Hz")
assert.strictEqual(L.formatHz(90.001), "90 Hz")

assert.ok(L.validCustomMode("2560x1440@75"))
assert.ok(!L.validCustomMode("2560x1440@75; rm -rf"))
assert.ok(!L.validCustomMode('1"x2'))

// clean scales match omarchy-hyprland-monitor-scaling
assert.strictEqual(L.cleanScale(1.6, 2880, 1800), 1.6)
assert.strictEqual(L.cleanScale(1.25, 1920, 1080), 1.25)
assert.strictEqual(L.cleanScale(1.3, 1920, 1080), 1.333333)
const s = L.validScales(2880, 1800, 1, 3)
assert.ok(s.includes(1) && s.includes(1.6) && s.includes(2) && s.includes(3))
assert.ok(!s.includes(1.75))

assert.deepStrictEqual(L.logicalSize({ mode: "2880x1800@90", scale: 2, transform: 0 }), { width: 1440, height: 900 })
assert.deepStrictEqual(L.logicalSize({ mode: "1920x1080@60", scale: 1, transform: 1 }), { width: 1080, height: 1920 })

// snapping: drop an external roughly right of the laptop, it attaches flush, top-aligned
const laptop = { x: 0, y: 0, width: 1440, height: 900 }
let p = L.snap({ x: 1500, y: 20, width: 1920, height: 1080 }, [laptop], 40)
assert.deepStrictEqual(p, { x: 1440, y: 0 })
// dropped above-left: attaches above, aligned to the laptop's centre when close
p = L.snap({ x: -230, y: -1200, width: 1920, height: 1080 }, [laptop], 40)
assert.deepStrictEqual(p, { x: -240, y: -1080 })
// never overlaps
p = L.snap({ x: 100, y: 100, width: 1920, height: 1080 }, [laptop], 40)
assert.ok(!L.overlaps({ ...p, width: 1920, height: 1080 }, laptop))

assert.deepStrictEqual(L.normalize({ a: { x: 1440, y: 0 }, b: { x: 0, y: 100 } }, "a"), { a: { x: 0, y: 0 }, b: { x: -1440, y: 100 } })
assert.strictEqual(L.diagonalInches(300, 190), 14)

console.log("layout tests ok")
