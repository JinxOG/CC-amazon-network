---
to: SANDBOX
from: SPEC-OWNER
kind: request
subject: Live view - draw the turtles on a map, and drop the STALE badge
date: 2026-10-20
status: open
---

# Live view - draw the turtles on a map, and drop the STALE badge
The user watched `real_world_six_hours` at `--speed 20` through `sandbox/sim view` (port 3101) and
asked why there are no turtles on the map. Two gaps, both yours:

## 1. The map panel is empty

`public/index.html` loads its left panel from `/dynmap-frame`, which on the live bridge proxies
the server's Dynmap (`127.0.0.1:8123`) and gets turtle markers pushed in over RCON (`dmarker`).
The sandbox has neither, so `fileserver.js` returns 404 and the panel shows `{"error":"not found"}`.

**Ruling:** `fileserver.js` serves its own page at `/dynmap-frame`, a top-down 2-D map drawn from
the run's `state.json`, refreshing at the dashboard's rate. It shows:

- every turtle as a dot at its x/z, coloured by role, labelled with its node id;
- the base/depot, and the outline of each active zone with its sectors shaded by state
  (pending / assigned / done) - the same data the JOBS tab reads;
- a corner note: "Sandbox map - simulated world, not Dynmap".

Pan and zoom are nice to have. Drag-to-select zones, and anything else in `index.html` that
reaches into `frame.contentWindow.dynmap`, may stay dead: the view is read-only (design
section 4.1). It must fail silently, not throw in the parent page. Terrain is not needed.

**Do not edit `public/` or `server.js`.** The page lives under `sandbox/bridge/`.

Test: `/dynmap-frame` returns 200 with HTML; a state with N turtles draws N markers (check the
data the page builds, not pixels).

## 2. The STALE badge

The top bar says "synced 134776s ago / STALE" because the page compares the state's timestamp
with the browser's clock, and the run is on simulated time. Find which field the page reads
and how `server.js` sets it, then make the stand-in or the file server present it so a run
being written reads as fresh. Do not change the page. If that is impossible without editing
`public/`, mail me what you found instead of guessing.

## Also

When both are in, mail me one line. I will check it against the same live run before telling
the user. Separately, I am about to review the build; nothing for you to do for that yet.
