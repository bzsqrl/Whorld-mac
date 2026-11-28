# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyright 2026 Jeff Matson.
# Written with Claude (Anthropic).
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.

"""Generate the TouchOSC layout for Whorld's OSC remote control:

    python3 mac/tools/build_touchosc.py

writes mac/touchosc/Whorld.tosc: a landscape layout (1280 x 800, for a
tablet or a computer; TouchOSC scales it) with five pages: MAIN (Master,
the Image switches and actions, the origin), PERFORM (the playlist's pads
and banks, cue and Go, Blackout, Auto Advance, modulation and the beat;
2026-11-27), PARAMS (every parameter's value), GLOBALS and MONITOR (names
and frame statistics).

In TouchOSC set any connection to UDP, host = the Whorld Mac's address
(Settings > OSC shows it), send port 8000, receive port 8001. Controls take
Whorld's values on their own addresses, so they follow changes made in
Whorld. The root script pings Whorld every second (/w/ping): Whorld
answers (/w/pong), which keeps its feedback coming and shows "connected";
on load, and after the connection comes back, it asks for everything
(/w/sync). The addresses are whorld::OscRemote's (mac/engine/src/OscRemote.cpp).

A .tosc file is zlib-compressed XML. Standard library only."""
import uuid
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "touchosc" / "Whorld.tosc"
PORT, FEEDBACK = 8000, 8001
CONNECTIONS = range(1, 11)	# send and receive on all of TouchOSC's connections

# The addresses (OscRemote.cpp): parameters in WhorldDef.h order.
PARAMS = [("rg", "Ring Growth"), ("rs", "Ring Spacing"), ("lw", "Line Width"), ("sd", "Ring Sides"),
	("rt", "Rotate Speed"), ("ar", "Aspect Ratio"), ("kr", "Skew Radius"), ("ka", "Skew Angle"),
	("sf", "Star Factor"), ("pn", "Pinwheel"), ("cs", "Color Speed"), ("lt", "Lightness"),
	("st", "Saturation"), ("al", "Alpha"), ("bh", "Bk Hue"), ("bl", "Bk Lightness"),
	("bs", "Bk Saturation"), ("ba", "Bk Alpha"), ("ec", "Even Curve"), ("oc", "Odd Curve"),
	("es", "Even Shear"), ("os", "Odd Shear")]
GLOBALS = ["lw", "sd", "rt", "ar", "kr", "ka", "sf", "pn", "ec", "oc", "es", "os"]
MASTER = [("sp", "Speed"), ("zm", "Zoom"), ("dp", "Damping"), ("tr", "Trail"), ("rn", "Rings"),
	("tp", "Tempo"), ("hs", "Hue Span"), ("cv", "Canvas"), ("cp", "Copies"), ("sr", "Spread"),
	("fd", "Fade")]
SWITCHES = [("fill", "FILL"), ("outline", "OUTLINE"), ("xray", "XRAY"), ("mirror", "MIRROR"), ("reverse", "REVERSE"),
	("convex", "CONVEX"), ("loophue", "LOOP HUE"), ("zoomctr", "ZOOM CTR"), ("aa", "ANTIALIAS"),
	("drag", "ORG DRAG"), ("random", "ORG RANDOM"), ("pause", "PAUSE"), ("invert", "INVERT")]
ACTIONS = [("rndphase", "RANDOM PHASE"), ("rndorg", "RANDOM ORIGIN"), ("clear", "CLEAR"),
	("rothue", "ROTATE HUE")]


def rgb(hex_, a=1.0):
	return tuple(round(int(hex_[i:i + 2], 16) / 255, 3) for i in (1, 3, 5)) + (a,)


BG, PANEL, GREY = rgb("#101014"), rgb("#1b1b22"), rgb("#3a3a48")
ACCENT, TEXT, DIM = rgb("#c0408a"), rgb("#ececf2"), rgb("#8c8c9c")
# PERFORM's lights: a pad with no patch, cued, and Go waiting for the beat's
# resting color (playing is ACCENT, as Whorld's own accent marks it)
EMPTY, CUED, GO = rgb("#1f1f27"), rgb("#2f7fc8"), rgb("#2c7a4b")
PAD_COLORS = [EMPTY, GREY, CUED, ACCENT]	# /w/cue/padN/state: 0 none, 1 a patch, 2 cued, 3 playing


# ── XML ──────────────────────────────────────────────────────────────────────

def cdata(s):
	return f"<![CDATA[{s}]]>"


def prop(ptype, key, value):
	if ptype == "r":
		inner = "".join(f"<{k}>{int(round(v))}</{k}>" for k, v in zip("xywh", value))
	elif ptype == "c":
		inner = "".join(f"<{k}>{v}</{k}>" for k, v in zip("rgba", value))
	elif ptype == "s":
		inner = cdata(value)
	elif ptype == "b":
		inner = str(int(bool(value)))
	else:
		inner = str(value)
	return f"<property type='{ptype}'><key>{cdata(key)}</key><value>{inner}</value></property>"


def value(key, default):
	d = cdata(default) if isinstance(default, str) else default
	return (f"<value><key>{cdata(key)}</key><locked>0</locked>"
		f"<lockedDefaultCurrent>0</lockedDefaultCurrent>"
		f"<default>{d}</default><defaultPull>0</defaultPull></value>")


def partial(ptype, conversion, val, scale=(0, 1)):
	return (f"<partial><type>{ptype}</type><conversion>{conversion}</conversion>"
		f"<value>{cdata(val)}</value>"
		f"<scaleMin>{scale[0]}</scaleMin><scaleMax>{scale[1]}</scaleMax></partial>")


def mask():
	return "".join("1" if i in CONNECTIONS else "0" for i in range(10, 0, -1))


def osc(path, args, trigger="ANY", receive=False, var="x"):
	return ("<osc><enabled>1</enabled><send>1</send>"
		f"<receive>{int(receive)}</receive><feedback>0</feedback><noDuplicates>0</noDuplicates>"
		f"<connections>{mask()}</connections>"
		f"<triggers><trigger><var>{cdata(var)}</var><condition>{trigger}</condition></trigger></triggers>"
		f"<path>{partial('CONSTANT', 'STRING', path)}</path>"
		f"<arguments>{''.join(args)}</arguments></osc>")


def node(ntype, props, values=(), messages=(), children=()):
	return (f"<node ID='{uuid.uuid4()}' type='{ntype}'>"
		f"<properties>{''.join(props)}</properties>"
		f"<values>{''.join(values)}</values>"
		f"<messages>{''.join(messages)}</messages>"
		f"<children>{''.join(children)}</children></node>")


# ── Controls ─────────────────────────────────────────────────────────────────

class Layout:
	def __init__(self):
		self.names = set()
		self.labels = {}	# address -> label names showing its value as text
		self.lights = {}	# address -> (control name, colors by the value: 0, 1, ...)
		self.status = []	# labels showing the connection

	def _name(self, name):
		assert name not in self.names, name
		self.names.add(name)
		return name

	def label(self, name, frame, text, size=16, color=TEXT, background=False, feed=None):
		if feed:
			self.labels.setdefault(feed, []).append(name)
		return node("LABEL", [
			prop("s", "name", self._name(name)),
			prop("r", "frame", frame),
			prop("c", "color", PANEL),
			prop("b", "background", background),
			prop("b", "outline", False),
			prop("b", "interactive", False),
			prop("c", "textColor", color),
			prop("i", "textSize", size),
		], [value("text", text)])

	def caption(self, name, frame, text):
		return self.label(name, frame, text, size=14, color=DIM)

	def switch(self, name, frame, text, address):
		"""A toggle: sends 1 / 0 and shows Whorld's state on the same address."""
		btn = node("BUTTON", [
			prop("s", "name", self._name(name)),
			prop("r", "frame", frame),
			prop("c", "color", ACCENT),
			prop("i", "buttonType", 1),
		], [value("x", 0)], [osc(address, [partial("VALUE", "FLOAT", "x")], receive=True)])
		return btn + self.label(name + "_lbl", frame, text, size=15)

	def push(self, name, frame, text, address):
		"""A momentary button: sends the address with no argument when pressed."""
		btn = node("BUTTON", [
			prop("s", "name", self._name(name)),
			prop("r", "frame", frame),
			prop("c", "color", GREY),
			prop("i", "buttonType", 0),
		], [value("x", 0)], [osc(address, [], trigger="RISE")])
		return btn + self.label(name + "_lbl", frame, text, size=15)

	def pad(self, name, frame, address, feed, light, colors):
		"""A momentary button whose text and color Whorld sets: its label
		shows `feed`, and `light`'s value picks its color from `colors`."""
		btn = node("BUTTON", [
			prop("s", "name", self._name(name)),
			prop("r", "frame", frame),
			prop("c", "color", colors[0]),
			prop("i", "buttonType", 0),
		], [value("x", 0)], [osc(address, [], trigger="RISE")])
		self.lights[light] = (name, colors)
		return btn + self.label(name + "_lbl", frame, "", size=15, feed=feed)

	def lit_push(self, name, frame, text, address, light, colors):
		"""A momentary button with a fixed name, colored by `light`'s value."""
		btn = node("BUTTON", [
			prop("s", "name", self._name(name)),
			prop("r", "frame", frame),
			prop("c", "color", colors[0]),
			prop("i", "buttonType", 0),
		], [value("x", 0)], [osc(address, [], trigger="RISE")])
		self.lights[light] = (name, colors)
		return btn + self.label(name + "_lbl", frame, text, size=24)

	def fader(self, name, frame, text, address):
		"""A horizontal fader under its name; follows Whorld's value."""
		x, y, w, h = frame
		f = node("FADER", [
			prop("s", "name", self._name(name)),
			prop("r", "frame", (x, y + 22, w, h - 22)),
			prop("c", "color", ACCENT),
			prop("i", "orientation", 1),	# horizontal, left to right
		], [value("x", 0)], [osc(address, [partial("VALUE", "FLOAT", "x")], receive=True)])
		return self.caption(name + "_lbl", (x, y, w, 20), text) + f

	def xy(self, name, frame, address):
		"""The origin: x and y in one message (/w/org x y); y down, as Whorld's."""
		return node("XY", [
			prop("s", "name", self._name(name)),
			prop("r", "frame", frame),
			prop("c", "color", ACCENT),
		], [value("x", 0.5), value("y", 0.5)],
			[osc(address, [partial("VALUE", "FLOAT", "x"), partial("VALUE", "FLOAT", "y", (1, 0))])])

	def status_label(self, name, frame):
		self.status.append(name)
		return self.label(name, frame, "not connected", size=13, color=DIM)

	def script(self):
		def lua_list(items):
			return "{ " + ", ".join(f"'{s}'" for s in items) + " }"
		def lua_color(c):
			return "{ " + ", ".join(str(x) for x in c) + " }"
		labels = "{\n" + "".join(f"  ['{k}'] = {lua_list(v)},\n" for k, v in sorted(self.labels.items())) + "}"
		lights = "{\n" + "".join(f"  ['{k}'] = {{ '{n}', {{ " + ", ".join(lua_color(c) for c in cs) + " } },\n"
			for k, (n, cs) in sorted(self.lights.items())) + "}"
		conn = "{ " + ", ".join("true" if i in CONNECTIONS else "false" for i in range(1, 11)) + " }"
		return ROOT_SCRIPT % {"conn": conn, "port": PORT, "feedback": FEEDBACK, "labels": labels,
			"lights": lights, "status": lua_list(self.status)}


def grid(x0, y0, x1, y1, cols, rows, gap):
	"""Frames of a cols x rows grid, filled column by column."""
	w = (x1 - x0 - gap * (cols - 1)) / cols
	h = (y1 - y0 - gap * (rows - 1)) / rows
	return [(x0 + c * (w + gap), y0 + r * (h + gap), w, h) for c in range(cols) for r in range(rows)]


ROOT_SCRIPT = r"""
-- Whorld remote control (generated by Whorld's mac/tools/build_touchosc.py).
-- Any connection: host = the Whorld Mac, send port %(port)d, receive port %(feedback)d.
local CONN = %(conn)s
local PING_MS, LOST_MS = 1000, 3500
local LABELS = %(labels)s
local LIGHTS = %(lights)s
local STATUS = %(status)s
local NOT_CONNECTED = 'not connected: set a connection to the Whorld Mac, send port %(port)d, receive port %(feedback)d'
local lastPing, lastPong, host, shown = -PING_MS, -1, '', nil
local cache = {}

local function ctl(name)
  local c = cache[name]
  if c == nil then
    c = root:findByName(name, true) or false
    cache[name] = c
  end
  return c
end

local function setText(name, text)
  local c = ctl(name)
  if c then c.values.text = text end
end

function init()
  sendOSC('/w/sync', CONN)
end

function update()
  local now = getMillis()
  if now - lastPing < PING_MS then return end
  lastPing = now
  sendOSC('/w/ping', CONN)
  local ok = lastPong >= 0 and now - lastPong < LOST_MS
  if ok ~= shown then
    shown = ok
    local text = ok and ('connected: ' .. host) or NOT_CONNECTED
    for _, name in ipairs(STATUS) do setText(name, text) end
  end
end

function onReceiveOSC(message, connections)
  local path = message[1]
  local arg = message[2] and message[2][1]
  if path == '/w/pong' then
    local now = getMillis()
    if lastPong < 0 or now - lastPong >= LOST_MS then
      shown = nil
      if lastPong >= 0 then sendOSC('/w/sync', CONN) end  -- back after a gap: everything again
    end
    lastPong, host = now, arg and tostring(arg.value) or ''
    return
  end
  local light = LIGHTS[path]
  if light and arg and type(arg.value) == 'number' then
    local c = ctl(light[1])
    local col = light[2][math.floor(arg.value) + 1]
    if c and col then c.color = Color(col[1], col[2], col[3], col[4]) end
  end
  local names = LABELS[path]
  if names and arg then
    local v = arg.value
    local text
    if type(v) == 'number' and math.floor(v) ~= v then text = string.format('%%.1f', v) else text = tostring(v) end
    for _, name in ipairs(names) do setText(name, text) end
  end
end
"""


# ── The layout ───────────────────────────────────────────────────────────────

W, H, TAB, M, GAP = 1280, 800, 56, 16, 10


def build():
	lay = Layout()

	def page(tab, children):
		return node("GROUP", [
			prop("s", "name", "page_" + tab),
			prop("r", "frame", (0, TAB, W, H - TAB)),
			prop("c", "color", BG),
			prop("b", "background", True),
			prop("s", "tabLabel", tab),
			prop("c", "tabColorOff", PANEL),
			prop("c", "tabColorOn", ACCENT),
			prop("c", "textColorOff", DIM),
			prop("c", "textColorOn", TEXT),
		], children=children)

	def header(p):
		return [lay.label(p + "patch", (M, 10, 760, 40), "Whorld", size=22, background=True, feed="/w/patch/name"),
			lay.status_label(p + "status", (M + 770, 10, W - 2 * M - 770, 40))]

	# MAIN: Master on the left, switches and actions on the right, the origin below them
	c = header("main_")
	c.append(lay.caption("cap_master", (M, 58, 300, 20), "MASTER"))
	# the Master faders, with Hue (a main property, /w/hue) after Hue Span
	faders = [("m_" + code, name, "/w/m/" + code) for code, name in MASTER]
	at = [code for code, _ in MASTER].index("hs") + 1
	faders.insert(at, ("hue", "Hue", "/w/hue"))
	for (cid, name, addr), frame in zip(faders, grid(M, 82, 620, H - TAB - M, 1, len(faders), 6)):
		c.append(lay.fader(cid, frame, name, addr))
	c.append(lay.caption("cap_image", (640, 58, 300, 20), "IMAGE"))
	for (addr, text), frame in zip(SWITCHES, grid(640, 82, W - M, 312, 5, 3, GAP)):	# 5 columns since XRay (2026-11-26)
		if addr:
			c.append(lay.switch("s_" + addr, frame, text, "/w/" + addr))
	for (addr, text), frame in zip(ACTIONS, grid(640, 322, W - M, 382, len(ACTIONS), 1, GAP)):
		c.append(lay.push("a_" + addr, frame, text, "/w/" + addr))
	c.append(lay.caption("cap_origin", (640, 394, 300, 20), "ORIGIN"))
	c.append(lay.xy("origin", (640, 418, W - M - 640, H - TAB - M - 418), "/w/org"))
	pages = [page("MAIN", c)]

	# PERFORM: the pads of the playlist's current bank (Whorld sends each
	# one's patch name and state), cue and Go, and the switches and beat
	# controls a set needs (2026-11-27)
	c = header("per_")
	PX = 800	# the pads' right edge; the controls are right of it
	c.append(lay.caption("cap_pads", (M, 58, 200, 20), "PADS"))
	c.append(lay.push("bank_down", (M, 82, 140, 48), "BANK −", "/w/cue/bankdown"))
	c.append(lay.label("bank", (M + 150, 82, PX - M - 300, 48), "", size=18, background=True, feed="/w/cue/bank"))
	c.append(lay.push("bank_up", (PX - 140, 82, 140, 48), "BANK +", "/w/cue/bankup"))
	for n, frame in enumerate(grid(M, 140, PX, H - TAB - M, 4, 4, GAP)):
		# grid() fills column by column; the pads count across, as on a controller
		col, row = divmod(n, 4)
		k = row * 4 + col + 1
		c.append(lay.pad(f"pad_{k}", frame, f"/w/cue/pad{k}", f"/w/cue/pad{k}/name",
			f"/w/cue/pad{k}/state", PAD_COLORS))
	X0 = PX + 20
	c.append(lay.caption("cap_cue", (X0, 58, 200, 20), "CUE"))
	c.append(lay.label("cue_name", (X0, 82, W - M - X0, 48), "", size=18, background=True, feed="/w/cue/name"))
	for (cid, text, addr), frame in zip([("cue_prev", "◀ CUE", "/w/cue/prev"), ("cue_next", "CUE ▶", "/w/cue/next")],
			grid(X0, 140, W - M, 196, 2, 1, GAP)):
		c.append(lay.push(cid, frame, text, addr))
	c.append(lay.lit_push("go", (X0, 206, W - M - X0, 110), "GO", "/w/cue/go", "/w/cue/wait", [GO, ACCENT]))
	c.append(lay.push("go_now", (X0, 326, W - M - X0, 48), "GO NOW", "/w/cue/gonow"))
	for (cid, text, addr), frame in zip([("blackout", "BLACKOUT", "/w/blackout"), ("advance", "AUTO ADV", "/w/advance"),
			("geometry", "GEOM", "/w/geometry")], grid(X0, 390, W - M, 446, 3, 1, GAP)):
		c.append(lay.switch(cid, frame, text, addr))
	c.append(lay.caption("cap_mod", (X0, 458, 300, 20), "MODULATION"))
	c.append(lay.switch("mod_on", (X0, 482, 110, 56), "MOD", "/w/mod/on"))
	c.append(lay.fader("mod_depth", (X0 + 120, 482, W - M - X0 - 120, 56), "Depth", "/w/mod/depth"))
	c.append(lay.caption("cap_beat", (X0, 550, 300, 20), "BEAT"))
	# column by column (grid's order): 1.1 over ½ beat, then back, then on
	beat = [("downbeat", "1.1", "/w/mod/downbeat"), ("halfbeat", "½ BEAT", "/w/mod/halfbeat"),
		("beatback", "BEAT −", "/w/mod/beatback"), ("barback", "BAR −", "/w/mod/barback"),
		("beatfwd", "BEAT +", "/w/mod/beatfwd"), ("barfwd", "BAR +", "/w/mod/barfwd")]
	for (cid, text, addr), frame in zip(beat, grid(X0, 574, W - M, H - TAB - M, 3, 2, GAP)):
		c.append(lay.push("b_" + cid, frame, text, addr))
	pages.append(page("PERFORM", c))

	# PARAMS: every parameter's value, in two columns
	c = header("par_")
	for (code, name), frame in zip(PARAMS, grid(M, 58, W - M, H - TAB - M, 2, 11, 8)):
		c.append(lay.fader("p_" + code, frame, name, f"/w/p/{code}/v"))
	pages.append(page("PARAMS", c))

	# GLOBALS: the twelve that have one
	names = dict(PARAMS)
	c = header("glb_")
	for code, frame in zip(GLOBALS, grid(M, 58, W - M, H - TAB - M, 2, 6, 10)):
		c.append(lay.fader("g_" + code, frame, names[code], f"/w/p/{code}/g"))
	pages.append(page("GLOBALS", c))

	# MONITOR: names and frame statistics
	c = header("mon_")
	rows = [("Patch", "/w/patch/name"), ("Author", "/w/patch/author"), ("Playlist", "/w/playlist/name"), ("Playing patch", "/w/patch"),
		("Frames per second", "/w/stat/fps"), ("Draw (ms)", "/w/stat/draw"), ("GPU (ms)", "/w/stat/gpu"),
		("Refresh (Hz)", "/w/stat/hz"), ("Missed refreshes", "/w/stat/missed"), ("Rings", "/w/stat/rings"),
		("Renderer", "/w/stat/renderer")]
	for i, (text, addr) in enumerate(rows):
		y = 66 + i * 52
		c.append(lay.caption(f"mon_cap{i}", (M, y + 8, 300, 30), text))
		c.append(lay.label(f"mon_val{i}", (M + 310, y, 600, 42), "", size=20, background=True, feed=addr))
	c.append(lay.label("mon_text", (M, 66 + len(rows) * 52, W - 2 * M, 42), "", size=15, color=DIM,
		background=True, feed="/w/stat/text"))
	pages.append(page("MONITOR", c))

	pager = node("PAGER", [
		prop("s", "name", "pages"),
		prop("r", "frame", (0, 0, W, H)),
		prop("c", "color", BG),
		prop("b", "tabbar", True),
		prop("i", "tabbarSize", TAB),
		prop("b", "tabbarDoubleTap", False),
		prop("b", "tabLabels", True),
		prop("i", "textSizeOff", 18),
		prop("i", "textSizeOn", 20),
	], [value("page", 0)], children=pages)
	root = node("GROUP", [
		prop("s", "name", "whorld"),
		prop("r", "frame", (0, 0, W, H)),
		prop("c", "color", BG),
		prop("b", "background", True),
		prop("s", "script", lay.script()),
	], children=[pager])
	xml = f"<?xml version='1.0' encoding='UTF-8'?><lexml version='3'>{root}</lexml>"
	return zlib.compress(xml.encode("utf-8"))


if __name__ == "__main__":
	OUT.parent.mkdir(exist_ok=True)
	OUT.write_bytes(build())
	print(f"wrote {OUT}")
