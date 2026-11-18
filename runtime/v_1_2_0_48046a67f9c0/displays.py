#!/usr/bin/env python3
"""Monitor configuration helper for the eusener.displays plugin.

  displays.py status                 JSON: monitors, saved profiles, pending change
  displays.py apply '<json>'         apply a layout live, revert in REVERT_SECONDS unless kept
  displays.py keep                   save the pending layout to ~/.config/hypr/displays.lua
  displays.py revert                 put the previous layout back
  displays.py watchdog <token>       (internal) revert when the timer runs out
  displays.py notify-new <connector> (internal) "new monitor" notification from the Lua hook
  displays.py init                   create displays.lua and require it from monitors.lua

apply input:
  {"primary": "eDP-1",
   "monitors": [{"name": "eDP-1", "mode": "2880x1800@90", "x": 0, "y": 0,
                 "scale": 2, "vrr": 0, "transform": 0, "mirror": "",
                 "bitdepth": 8, "cm": "srgb", "sdrbrightness": 1,
                 "sdrsaturation": 1, "disabled": false}]}

Saved profiles are keyed by the monitor's EDID description (make, model,
serial), so a monitor keeps its settings on any port or dock. They live in
~/.config/omarchy/displays/profiles.json and are rendered into
~/.config/hypr/displays.lua as desc: rules. Every value is validated before it
is written into Lua, and every string is escaped: EDID text is untrusted.
"""

import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
MONITORS_LUA = CONFIG / "hypr/monitors.lua"
DISPLAYS_LUA = CONFIG / "hypr/displays.lua"
DATA_DIR = CONFIG / "omarchy/displays"
PROFILES = DATA_DIR / "profiles.json"
BACKUP_DIR = DATA_DIR / "backups"
STATE_DIR = STATE_HOME / "eusener-displays"
PENDING = STATE_DIR / "pending.json"
REQUIRE_LINE = 'pcall(require, "hypr.displays") -- eusener.displays: per-monitor settings, keep last'
HELPER = Path(__file__).resolve()
REVERT_SECONDS = 15

NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
MODE_RE = re.compile(r"^(preferred|highres|highrr|\d{3,5}x\d{3,5}(@\d{1,3}(\.\d{1,5})?)?)$")
INTERNAL_RE = re.compile(r"^(eDP|LVDS|DSI)-")
CM_VALUES = ("auto", "srgb", "wide", "edid", "hdr", "hdredid", "dcip3", "dp3", "adobe")


def run(args, check=True):
  return subprocess.run(args, check=check, text=True, capture_output=True)


def hyprctl_json(*args):
  return json.loads(run(["hyprctl", *args, "-j"]).stdout or "[]")


def atomic_write(path, text):
  path = Path(os.path.realpath(path))
  path.parent.mkdir(parents=True, exist_ok=True)
  fd, tmp = tempfile.mkstemp(prefix=".displays-", dir=path.parent)
  try:
    with os.fdopen(fd, "w") as f:
      f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
  finally:
    if os.path.exists(tmp):
      os.unlink(tmp)


def read_json(path, fallback):
  try:
    return json.loads(path.read_text())
  except (OSError, ValueError):
    return fallback


def backup(path):
  if not path.exists():
    return
  dest = BACKUP_DIR / time.strftime("%Y%m%d-%H%M%S")
  dest.mkdir(parents=True, exist_ok=True)
  shutil.copy2(path, dest / path.name)
  # Keep the twenty most recent backups.
  for old in sorted(BACKUP_DIR.iterdir())[:-20]:
    shutil.rmtree(old, ignore_errors=True)


def lua_str(value):
  text = str(value)
  if any(ord(c) < 32 or ord(c) == 127 for c in text) or len(text) > 200:
    raise ValueError("unsafe text: %r" % text[:40])
  return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def num(value):
  # Lua number literal; no exponent, no locale.
  out = ("%.6f" % float(value)).rstrip("0").rstrip(".")
  return out or "0"


def connector_kind(name):
  if INTERNAL_RE.match(name):
    return "internal"
  if name.startswith("HDMI"):
    return "hdmi"
  if name.startswith("DP") or name.startswith("USB"):
    return "dp"
  return "other"


# Hyprland only accepts scales where the mode divides into whole logical
# pixels in 1/120 steps (same rule as omarchy-hyprland-monitor-scaling).
def clean_scale(scale, width, height):
  if width <= 0 or height <= 0:
    return round(scale, 6)
  g = math.gcd(int(round(width * 120)), int(round(height * 120)))
  k = int(round(scale * 120))
  k = max(1, min(k, g))
  while g % k:
    k += 1
  return round(k / 120, 6)


def mode_size(mode, fallback):
  m = re.match(r"^(\d+)x(\d+)", mode)
  return (int(m.group(1)), int(m.group(2))) if m else fallback


def nearest_mode(available, width, height, hz):
  best, best_d = None, 1e9
  for item in available:
    mm = re.match(r"^(\d+)x(\d+)@([\d.]+)Hz$", item)
    if mm and int(mm.group(1)) == width and int(mm.group(2)) == height:
      d = abs(float(mm.group(3)) - hz)
      if d < best_d:
        best, best_d = "%sx%s@%s" % mm.groups(), d
  return best if best and best_d < 0.5 else "%dx%d@%s" % (width, height, num(round(hz, 3)))


def live_monitors():
  return hyprctl_json("monitors", "all")


def live_spec(m, profile=None):
  """The settings a monitor runs with now, in apply format."""
  profile = profile or {}
  disabled = bool(m.get("disabled"))
  width, height = m.get("width") or 0, m.get("height") or 0
  if width and height and not disabled:
    mode = nearest_mode(m.get("availableModes") or [], width, height, m.get("refreshRate") or 60)
  else:
    mode = profile.get("mode", "preferred")
  vrr = profile.get("vrr", 1 if m.get("vrr") else 0)
  mirror = m.get("mirrorOf") or "none"
  cm = m.get("colorManagementPreset") or "srgb"
  return {
    "name": m["name"],
    "mode": mode,
    "x": int(m.get("x") or 0),
    "y": int(m.get("y") or 0),
    "scale": round(float(m.get("scale") or 1), 6),
    "vrr": int(vrr),
    "transform": int(m.get("transform") or 0),
    "mirror": "" if mirror == "none" else mirror,
    "bitdepth": 10 if "2101010" in (m.get("currentFormat") or "") else 8,
    "cm": cm if cm in CM_VALUES else "srgb",
    "sdrbrightness": float(m.get("sdrBrightness") or 1),
    "sdrsaturation": float(m.get("sdrSaturation") or 1),
    "disabled": disabled,
  }


def validate(spec, names):
  name = str(spec.get("name", ""))
  if not NAME_RE.match(name) or name not in names:
    raise ValueError("unknown monitor %r" % name)
  mode = str(spec.get("mode") or "preferred").strip()
  if not MODE_RE.match(mode):
    raise ValueError("%s: invalid mode %r" % (name, mode))
  x, y = int(spec.get("x", 0)), int(spec.get("y", 0))
  if not (-32768 <= x <= 32768 and -32768 <= y <= 32768):
    raise ValueError("%s: position out of range" % name)
  scale = float(spec.get("scale", 1))
  if not (0.25 <= scale <= 4):
    raise ValueError("%s: scale must be between 0.25 and 4" % name)
  vrr, transform, bitdepth = int(spec.get("vrr", 0)), int(spec.get("transform", 0)), int(spec.get("bitdepth", 8))
  if vrr not in (0, 1, 2, 3) or transform not in range(8) or bitdepth not in (8, 10):
    raise ValueError("%s: invalid vrr/transform/bitdepth" % name)
  cm = str(spec.get("cm", "srgb"))
  if cm not in CM_VALUES:
    raise ValueError("%s: invalid color preset %r" % (name, cm))
  sdrb, sdrs = float(spec.get("sdrbrightness", 1)), float(spec.get("sdrsaturation", 1))
  if not (0.5 <= sdrb <= 3 and 0 <= sdrs <= 3):
    raise ValueError("%s: SDR brightness/saturation out of range" % name)
  mirror = str(spec.get("mirror") or "")
  if mirror and (mirror == name or mirror not in names):
    raise ValueError("%s: cannot mirror %r" % (name, mirror))
  return {
    "name": name, "mode": mode, "x": x, "y": y, "scale": scale, "vrr": vrr,
    "transform": transform, "mirror": mirror, "bitdepth": bitdepth, "cm": cm,
    "sdrbrightness": round(sdrb, 3), "sdrsaturation": round(sdrs, 3),
    "disabled": bool(spec.get("disabled", False)),
  }


def rule_lua(output, spec, size=None):
  if spec["disabled"]:
    return "hl.monitor({ output = %s, disabled = true })" % lua_str(output)
  w, h = mode_size(spec["mode"], size or (0, 0))
  scale = clean_scale(spec["scale"], w, h)
  return (
    "hl.monitor({ output = %s, disabled = false, mode = %s, position = %s, scale = %s, "
    "transform = %d, vrr = %d, bitdepth = %d, cm = %s, sdrbrightness = %s, sdrsaturation = %s, mirror = %s })"
  ) % (
    lua_str(output), lua_str(spec["mode"]), lua_str("%dx%d" % (spec["x"], spec["y"])), num(scale),
    spec["transform"], spec["vrr"], spec["bitdepth"], lua_str(spec["cm"]),
    num(spec["sdrbrightness"]), num(spec["sdrsaturation"]), lua_str(spec["mirror"]),
  )


def eval_lua(expr):
  out = run(["hyprctl", "eval", expr], check=False)
  text = (out.stdout + out.stderr).strip()
  if out.returncode != 0 or (text and text != "ok"):
    raise RuntimeError(text or "hyprctl eval failed")


def apply_specs(specs, monitors):
  sizes = {m["name"]: (m.get("width") or 0, m.get("height") or 0) for m in monitors}
  # Turn screens on first and off last, so there is always one lit; mirrors
  # go after the screen they copy.
  order = sorted(specs, key=lambda s: (s["disabled"], bool(s["mirror"])))
  for spec in order:
    eval_lua(rule_lua(spec["name"], spec, sizes.get(spec["name"])))


def gdk_scale_for(specs):
  scales = [s["scale"] for s in specs if not s["disabled"] and not s["mirror"]]
  return max(1, int(math.floor(min(scales) + 0.5))) if scales else 1


# ---------------------------------------------------------------- persistence

def load_profiles():
  data = read_json(PROFILES, {})
  if not isinstance(data, dict):
    data = {}
  data.setdefault("profiles", {})
  data.setdefault("primary", "")
  return data


def render_lua(data):
  lines = [
    "-- Generated by the eusener.displays shell plugin (SUPER + CTRL + F7).",
    "-- Changes made here are overwritten the next time you save in the panel;",
    "-- the source of truth is ~/.config/omarchy/displays/profiles.json.",
    "-- Rules match each monitor by its EDID description, so they follow the",
    "-- monitor to any HDMI/USB-C port or dock.",
    "",
  ]
  known = []
  for desc, spec in sorted(data["profiles"].items()):
    known.append(desc)
    lines.append(rule_lua("desc:" + desc, spec))
  lines.append("")
  if data.get("gdk_scale"):
    lines.append("-- GDK_SCALE follows the lowest monitor scale (GTK only takes whole numbers).")
    lines.append('hl.env("GDK_SCALE", %s)' % lua_str(int(data["gdk_scale"])))
    lines.append("")
  lines.append("local known = {")
  for desc in known:
    lines.append("  [%s] = true," % lua_str(desc))
  lines.append("}")
  lines.append("")
  primary = data.get("primary") or ""
  if primary:
    lines += [
      "-- The primary monitor sits at 0x0 and takes focus when the session starts.",
      'hl.on("hyprland.start", function()',
      "  for _, m in ipairs(hl.get_monitors()) do",
      "    if m.description == %s then" % lua_str(primary),
      "      hl.dispatch(hl.dsp.focus({ monitor = m.name }))",
      "    end",
      "  end",
      "end)",
      "",
    ]
  lines += [
    "-- A monitor without saved settings gets a notification that opens the panel.",
    'hl.on("monitor.added", function(m)',
    "  if not m or not m.name or known[m.description or \"\"] then return end",
    '  if not m.name:match("^[%w%._-]+$") then return end',
    "  hl.exec_cmd(%s .. m.name)" % lua_str("python3 %s notify-new " % HELPER),
    "end)",
    "",
  ]
  return "\n".join(lines)


def ensure_required():
  text = MONITORS_LUA.read_text() if MONITORS_LUA.exists() else ""
  if 'require, "hypr.displays")' in text or 'require("hypr.displays")' in text:
    return
  backup(MONITORS_LUA)
  atomic_write(MONITORS_LUA, text.rstrip("\n") + "\n\n" + REQUIRE_LINE + "\n")


def write_config(data):
  DATA_DIR.mkdir(parents=True, exist_ok=True)
  old_lua = DISPLAYS_LUA.read_text() if DISPLAYS_LUA.exists() else None
  backup(DISPLAYS_LUA)
  atomic_write(PROFILES, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
  atomic_write(DISPLAYS_LUA, render_lua(data))
  ensure_required()
  run(["hyprctl", "reload"], check=False)
  time.sleep(0.4)
  errors = run(["hyprctl", "configerrors"], check=False).stdout.strip()
  if errors and "displays.lua" in errors:
    if old_lua is None:
      DISPLAYS_LUA.unlink(missing_ok=True)
    else:
      atomic_write(DISPLAYS_LUA, old_lua)
    run(["hyprctl", "reload"], check=False)
    raise RuntimeError("Hyprland rejected displays.lua: " + errors.splitlines()[0])


# ------------------------------------------------------------------- commands

def cmd_status():
  monitors = live_monitors()
  data = load_profiles()
  pending = read_json(PENDING, None)
  if pending and pending.get("deadline", 0) < time.time() - 5:
    pending = None
  out = []
  for m in monitors:
    desc = m.get("description") or ""
    profile = data["profiles"].get(desc)
    spec = live_spec(m, profile)
    # Settings Hyprland does not report back (the VRR mode) come from the profile.
    out.append({
      "name": m["name"],
      "description": desc,
      "make": m.get("make") or "",
      "model": m.get("model") or "",
      "serial": m.get("serial") or "",
      "kind": connector_kind(m["name"]),
      "physicalWidth": m.get("physicalWidth") or 0,
      "physicalHeight": m.get("physicalHeight") or 0,
      "width": m.get("width") or 0,
      "height": m.get("height") or 0,
      "refreshRate": m.get("refreshRate") or 0,
      "modes": m.get("availableModes") or [],
      "focused": bool(m.get("focused")),
      "vrrActive": bool(m.get("vrr")),
      "saved": profile is not None,
      "spec": spec,
    })
  print(json.dumps({
    "monitors": out,
    "primary": data.get("primary") or "",
    "pending": {"deadline": pending["deadline"]} if pending else None,
    "revertSeconds": REVERT_SECONDS,
    "configured": DISPLAYS_LUA.exists(),
  }))


def cmd_apply(raw):
  req = json.loads(raw)
  monitors = live_monitors()
  names = {m["name"] for m in monitors}
  specs = [validate(s, names) for s in req.get("monitors", [])]
  if not specs:
    raise ValueError("nothing to apply")
  if all(s["disabled"] for s in specs):
    raise ValueError("at least one monitor must stay on")
  internal_disabled = {m["name"]: bool(m.get("disabled")) for m in monitors}
  for s in specs:
    # A closed/disabled laptop can stay off while an external display changes.
    # Only the transition from enabled to disabled belongs to Omarchy's switch.
    if s["disabled"] and INTERNAL_RE.match(s["name"]) and not internal_disabled[s["name"]]:
      raise ValueError("turn the laptop screen off with the laptop switch, not here")
  primary = str(req.get("primary") or "")
  if primary and primary not in names:
    raise ValueError("unknown primary monitor")

  data = load_profiles()
  existing = read_json(PENDING, None)
  if existing and existing.get("previous"):
    previous = existing["previous"]  # keep the original state across re-applies
  else:
    previous = [live_spec(m, data["profiles"].get(m.get("description") or "")) for m in monitors]

  token = "%d-%d" % (time.time() * 1000, os.getpid())
  STATE_DIR.mkdir(parents=True, exist_ok=True)
  atomic_write(PENDING, json.dumps({
    "token": token,
    "deadline": time.time() + REVERT_SECONDS,
    "previous": previous,
    "proposed": specs,
    "primary": primary,
  }))
  try:
    apply_specs(specs, monitors)
  except Exception:
    apply_specs(previous, monitors)
    PENDING.unlink(missing_ok=True)
    raise
  subprocess.Popen(["python3", str(HELPER), "watchdog", token], start_new_session=True,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
  cmd_status()


def cmd_revert():
  pending = read_json(PENDING, None)
  PENDING.unlink(missing_ok=True)
  if pending and pending.get("previous"):
    apply_specs(pending["previous"], live_monitors())
  cmd_status()


def cmd_watchdog(token):
  pending = read_json(PENDING, None)
  if not pending:
    return
  time.sleep(max(0, pending["deadline"] - time.time()))
  pending = read_json(PENDING, None)
  if pending and pending.get("token") == token:
    PENDING.unlink(missing_ok=True)
    apply_specs(pending["previous"], live_monitors())
    run(["omarchy-notification-send", "-g", "󰍹", "Monitores: configuração revertida",
         "Nenhuma confirmação em %ds." % REVERT_SECONDS], check=False)


def cmd_keep():
  pending = read_json(PENDING, None)
  if not pending:
    raise RuntimeError("no pending change to keep")
  PENDING.unlink(missing_ok=True)
  monitors = live_monitors()
  by_name = {m["name"]: m for m in monitors}
  data = load_profiles()
  for spec in pending["proposed"]:
    m = by_name.get(spec["name"])
    if not m or not m.get("description"):
      continue
    saved = dict(spec)
    saved.pop("name", None)
    # The laptop screen's on/off belongs to Omarchy's own toggle, which turns it
    # back on when the last external monitor goes away.
    if INTERNAL_RE.match(spec["name"]):
      saved["disabled"] = False
    data["profiles"][m["description"]] = saved
  primary = pending.get("primary") or ""
  if primary in by_name:
    data["primary"] = by_name[primary].get("description") or ""
  data["gdk_scale"] = gdk_scale_for(pending["proposed"])
  write_config(data)
  cmd_status()


def cmd_notify_new(name):
  if not NAME_RE.match(name):
    return
  time.sleep(1.5)  # let Hyprland settle the new output first
  m = next((m for m in live_monitors() if m["name"] == name), None)
  if not m:
    return
  label = (m.get("description") or name)[:80]
  run(["omarchy-notification-send", "-g", "󰍹", "Novo monitor: %s" % name, label,
       "--action", "Configurar", "omarchy-shell", "eusener.displays", "open"], check=False)


def cmd_init():
  if not DISPLAYS_LUA.exists():
    data = load_profiles()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    atomic_write(DISPLAYS_LUA, render_lua(data))
  ensure_required()
  print("ok")


def main(argv):
  if not argv:
    print(__doc__)
    return 2
  cmd, args = argv[0], argv[1:]
  try:
    if cmd == "status":
      cmd_status()
    elif cmd == "apply" and args:
      cmd_apply(args[0])
    elif cmd == "keep":
      cmd_keep()
    elif cmd == "revert":
      cmd_revert()
    elif cmd == "watchdog" and args:
      cmd_watchdog(args[0])
    elif cmd == "notify-new" and args:
      cmd_notify_new(args[0])
    elif cmd == "init":
      cmd_init()
    else:
      print(__doc__)
      return 2
  except Exception as e:  # noqa: BLE001 - message goes to the panel
    print(str(e), file=sys.stderr)
    return 1
  return 0


if __name__ == "__main__":
  sys.exit(main(sys.argv[1:]))
