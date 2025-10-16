# Camera Path "fn" Guide

This doc explains the built-in **function paths** (`"mode": "fn"`) you can author in JSON for the Trackmania Editor camera. All examples are drop-in files for:

```
OpenplanetNext/Plugins/tm_Camera-Timelapse/Storage/paths/
```

Each file should be named like `path.<name>.json`.

---

## Common JSON shape

```jsonc
{
  "version": 1,
  "name": "Human readable name (optional)",
  "mode": "fn",
  "metadata": {
    "units": "world",      // "world" (default) or "blocks"
    "fps": 0,              // 0 = continuous; >0 = quantize keyframes only (fn is continuous)
    "loop": true,          // loop at end
    "speed": 1.0           // playback rate multiplier (the player can also change this)
    // "duration": 360.0   // optional; for fns we can auto-derive (see below)
  },
  "fn": {
    "name": "<fn name>",
    // fn-specific fields...
  }
}
```

### Units

* `"world"`: coordinates are world units (1 block = 32, vertical step = 8).
* `"blocks"`: we convert `[x, y, z]` to world via `(x * 32, (y - 8) * 8, z * 32)`.

### Duration (how long the path runs)

* You may omit `"metadata.duration"` for fn paths; it's auto-derived when possible:

  * `orbital_circle`/`orbital_helix`: `duration = 360 / deg_per_sec`.
  * `target_polyline`: `duration = total_length / speed`.
* You can also specify it explicitly in:

  * `"metadata": { "duration": ... }`, or
  * `"fn": { "duration": ... }`, or
  * top-level `"duration"` (fallback).

### Looping

* `"metadata.loop": true` wraps time and creates a seamless loop.
* Our runtime also keeps angles **continuous** across the loop seam (no twitching).

---

## fn: `orbital_circle`

Orbit around a fixed center at constant radius and vertical angle.

```jsonc
{
  "mode": "fn",
  "metadata": { "units": "blocks", "loop": true, "fps": 0 },
  "fn": {
    "name": "orbital_circle",
    "center": [768, 40, 768], // orbit target (converted from blocks if units=blocks)
    "radius": 1600.0,         // camera distance to target (world units)
    "v_deg": 20.0,            // constant vertical angle (pitch)
    "deg_per_sec": 0.1,       // 360/0.1 = 3600s = 1 hour per revolution
    "start_deg": 0.0,         // initial yaw angle
    "cw": true                // clockwise; false = counter-clockwise
  }
}
```

**Auto-duration:** `360 / deg_per_sec`.
**Use cases:** map fly-around, timelapse "panorama" shots.

**Tips**

* Wider framing: increase `"radius"`.
* Flatter view: decrease `"v_deg"` (e.g., 15°).
* Reverse direction: set `"cw": false` (or enable the global "Invert spin" setting if you added it).

---

## fn: `orbital_helix`

Like `orbital_circle`, but the **vertical angle** changes over time—great for rise/descend shots.
We also support **center drift** so the orbit **position** can move (e.g., rising center Y).

```jsonc
{
  "mode": "fn",
  "metadata": { "units": "blocks", "loop": true, "fps": 0 },
  "fn": {
    "name": "orbital_helix",
    "center": [1024, 0, 1024],         // start center
    "center_end": [1024, 720, 1024],   // optional: end center (enables drifting center)
    "center_lerp_pow": 1.8,            // >1 = starts slower; =1 linear; <1 starts faster
    "radius": 3120.0,
    "v_start_deg": 0.0,                // start pitch
    "v_end_deg": 85.0,                 // end pitch
    "deg_per_sec": 0.2,                // 360/0.2 = 1800s = 30 min per revolution
    "start_deg": 0.0,
    "cw": true
  }
}
```

**Auto-duration:** `360 / deg_per_sec`.

**What center drift does**

* If `center_end` is provided, the **orbit target** moves from `center` → `center_end` over the duration.
* The curve of that motion is shaped by `center_lerp_pow`:

  * `1.0` = linear;
  * `>1` (1.5–2.5) = starts slower (good for subtle lifts);
  * `<1` (0.5–0.8) = starts faster.

**Use cases**

* Start at ground level looking across the map; end overhead looking straight down.
* Slow, majestic rises with a wide radius for big maps.

---

## fn: `target_polyline`

Move the **target** along a polyline and auto-orient the camera to look **ahead** along the path.
Keeps a constant camera distance (like a chase cam around a moving point).

```jsonc
{
  "mode": "fn",
  "metadata": { "units": "blocks", "loop": true, "fps": 0 },
  "fn": {
    "name": "target_polyline",
    "points": [
      [ 0, 10,  0],
      [ 0, 10, 48],
      [48, 10, 48],
      [48, 10,  0]
    ],
    "closed": true,        // connect the last point to the first
    "interpolation": "catmullrom", // or "linear" (position sampling is linear; CR helps corner shape)
    "speed": 64.0,         // world units per second (= 2 blocks/s)
    "dist": 1200.0,        // camera distance to the moving target
    "look_ahead": 64.0,    // where we look along the path (world units)
    "height_offset": 0.0   // add to target.y after sampling
  }
}
```

**Auto-duration:** computed from total polyline length and `speed`.

**Use cases**

* Perimeter loops around a track while keeping the camera pointed inward.
* Fly-throughs with smoother cornering (increase `look_ahead` to reduce yaw jitter).

---

## Authoring Tips

### 1) Smoothest motion (fn paths)

* Use `"fps": 0` in metadata (continuous evaluation).
* In the plugin Settings, leave "Snap to FPS frames" **off** for fn paths.
* "Step blend duration" is **not used** for continuous fn paths (you can leave it at 0).

### 2) Angle continuity

We keep yaw/pitch **continuous** frame-to-frame and wrap them to [-π, π] internally, so loops are seamless and there's no "flip to shortest path."

### 3) Looping behavior

* With `"loop": true`, time wraps seamlessly; for polylines use `"closed": true` for a clean loop.
* For helix + center drift: when looping, the path jumps back to the starting `center` and `v_start_deg`.
  If you want **up-and-down ping-pong**, author two profiles (rise / descend) or ask us to add a `*_pingpong` variant.

### 4) Deriving duration

* Circle/helix: `duration = 360 / deg_per_sec`.

  * 1 hour circle → `deg_per_sec = 0.1`.
  * 30 minute helix → `deg_per_sec = 0.2`.
* Polyline: `duration = length / speed`. Increase `speed` to shorten the run.

### 5) Direction

* Set `"cw": false` for counter-clockwise.

---

## Quick Reference (fields by fn)

### `orbital_circle`

| Field         | Type  | Required | Notes                        |
| ------------- | ----- | -------: | ---------------------------- |
| `center`      | vec3  |        ✔ | Orbit target (units applied) |
| `radius`      | float |        ✔ | Camera distance              |
| `v_deg`       | float |        ✔ | Constant pitch               |
| `deg_per_sec` | float |        ✔ | Angular speed (yaw)          |
| `start_deg`   | float |        ✖ | Initial yaw                  |
| `cw`          | bool  |        ✖ | Default `true`               |

### `orbital_helix`

| Field             | Type  | Required | Notes                       |
| ----------------- | ----- | -------: | --------------------------- |
| `center`          | vec3  |        ✔ | Start target                |
| `center_end`      | vec3  |        ✖ | End target (enables drift)  |
| `center_lerp_pow` | float |        ✖ | Drift easing; default `1.5` |
| `radius`          | float |        ✔ | Camera distance             |
| `v_start_deg`     | float |        ✔ | Start pitch                 |
| `v_end_deg`       | float |        ✔ | End pitch                   |
| `deg_per_sec`     | float |        ✔ | Yaw speed                   |
| `start_deg`       | float |        ✖ | Initial yaw                 |
| `cw`              | bool  |        ✖ | Default `true`              |

### `target_polyline`

| Field           | Type   | Required | Notes                        |
| --------------- | ------ | -------: | ---------------------------- |
| `points`        | vec3[] |        ✔ | At least 2 points            |
| `closed`        | bool   |        ✖ | Default `false`              |
| `interpolation` | string |        ✖ | `"linear"` or `"catmullrom"` |
| `speed`         | float  |        ✔ | Units/sec                    |
| `dist`          | float  |        ✔ | Camera distance              |
| `look_ahead`    | float  |        ✖ | Default `64.0`               |
| `height_offset` | float  |        ✖ | Default `0.0`                |
