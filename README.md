# Crowd Simulator

> Agent-based pedestrian crowd dynamics in **Godot 4**, with a tunable aggressive / neutral / passive personality mix, RVO avoidance via `NavigationServer3D`, a side-by-side **tournament view** that runs 15 simulations in parallel, and a **headless Monte Carlo batch runner** with a published research note included below.

![Godot 4.6+](https://img.shields.io/badge/Godot-4.6+-478cbf?logo=godotengine&logoColor=white)
![GDScript](https://img.shields.io/badge/GDScript-only-355570)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow)
![Status](https://img.shields.io/badge/status-active-brightgreen)

A two-way crosswalk simulation. Two crowds (north-bound, south-bound) cross a shared crosswalk after the walk signal turns green. Agents are stored in packed arrays and rendered through `MultiMeshInstance3D`, so a thousand pedestrians is cheap. Local avoidance is delegated to Godot 4's built-in RVO via `NavigationServer3D.agent_set_avoidance_callback`, then post-processed in the callback to constrain forward and lateral motion to plausible human gait.

---

## Table of contents

- [Features](#features)
- [Quickstart](#quickstart)
- [Two scenes](#two-scenes)
- [The personality model](#the-personality-model)
- [Research note: personality mix vs crossing time (N=10)](#research-note-personality-mix-vs-crossing-time-n10)
- [Headless batch runner](#headless-batch-runner)
- [Project structure](#project-structure)
- [Performance notes](#performance-notes)
- [Roadmap](#roadmap)
- [Acknowledgments](#acknowledgments)
- [License](#license)

---

## Features

- **Godot 4.6**, **GDScript** only, no add-ons or external dependencies.
- **Per-agent personality**: aggressive / neutral / passive profiles drive RVO time horizon, padding, lateral cap, preferred speed, and a new `rvo_compliance` blend factor that controls how much an agent yields to the avoidance callback.
- **Live runtime sliders** that set the personality mix (auto-rebalanced to sum to 100%, applied on slider release).
- **Per-instance MultiMesh tinting** so each capsule's shade reflects its personality (darker = aggressive, lighter = passive).
- **Tournament view** — `scenes/tournament.tscn` lays out a 5×3 grid of 15 tiles sweeping the personality spectrum end-to-end with a single ortho camera and a live finishers leaderboard.
- **Headless Monte Carlo batch runner** — `--batch` mode runs N seeds × M configs sequentially, writes a CSV (`aggressive,neutral,passive,seed,agents,cross_time,arrived,timed_out,wall_msec`).
- **Deterministic largest-remainder personality allocation** + seeded shuffle so the visible distribution exactly matches the requested percentages and is reproducible from `simulation_seed`.
- **Cross-time tracker** in the debug overlay — pause-aware live timer, frozen final value when the last agent reaches the opposite sidewalk.

## Quickstart

Requires Godot 4.6+ (the Mono build is fine — the project uses GDScript only).

```bash
git clone https://github.com/phalladar/crowd-simulator
cd crowd-simulator

# Open in editor:
godot --path .

# Or run a scene directly:
godot --path . scenes/main.tscn
godot --path . scenes/tournament.tscn

# Headless Monte Carlo batch (writes res://batch_results.csv):
godot --headless --path . -- --batch --seeds 10 --timeout 75
```

## Two scenes

### `scenes/main.tscn` — single sim

A 100-agent crosswalk with the personality slider HUD and debug overlay. Free orbit camera, cross-time tracker, all the tuning knobs exposed on the `CrowdSimulation` node in the inspector.

| Key | Action |
|---|---|
| `R` | Reset the run |
| `Space` | Pause / resume |
| `[` / `]` | Decrease / increase agent count |
| Left-mouse drag | Rotate camera |
| Middle-mouse drag | Pan camera |
| Mouse wheel | Zoom (orthographic) |

### `scenes/tournament.tscn` — 15-tile grid

15 simulations in a 5×3 grid, all running in lockstep with `seed=42`, sweeping the personality spectrum from `100/0/0` (top-left) through `0/100/0` (centre) to `0/0/100` (bottom-right). Each tile shows its config and live cross time floating above the south sidewalk; the top-left HUD lists finishers as they complete.

| Key | Action |
|---|---|
| `R` | Reset all 15 tiles |

Tweak `tile_agent_count`, `tile_spacing_x/z`, `camera_orthographic_size`, `camera_pitch_degrees`, `camera_distance` on the `CrowdTournament` node in the inspector.

## The personality model

Each agent gets a discrete personality at spawn drawn from the requested mix:

| Profile | `rvo_compliance` | `time_horizon_mul` | `padding_mul` | `max_lateral_mul` | `speed_mul` | Visual tint |
|---|---:|---:|---:|---:|---:|---|
| **Aggressive** | 0.20 | 0.35 | 0.4 | 0.30 | 1.15 | 30% darker |
| **Neutral** | 1.00 | 1.00 | 1.0 | 1.00 | 1.00 | base colour |
| **Passive** | 1.00 | 1.60 | 1.4 | 1.60 | 0.90 | 30% lighter |

The key behavioural lever is `rvo_compliance`. In the avoidance callback we compute `final = lerp(preferred_velocity, rvo_safe_velocity, rvo_compliance)`. Aggressive agents at compliance 0.20 use 80% preferred velocity and 20% RVO correction — they barely deviate. NavigationServer3D still sees them as moving obstacles, so neutral and passive agents route around them.

With sliders at `0/100/0` (the default), the simulation is bit-identical to the pre-personality build at the same seed: the personality bag's shuffle is a no-op when uniform, so it doesn't perturb the RNG sequence consumed by spawn jitter.

---

## Research note: personality mix vs crossing time (N=10)

This section is a short research note based on a controlled headless batch experiment on this build. The full dataset is committed as `batch_n10.csv`.

### Abstract

We ran 70 simulated crosswalk crossings — 7 personality-mix configurations × 10 random seeds at 100 agents each — to characterize how the aggressive / neutral / passive blend affects time-to-clear-the-crosswalk. All 70 runs finished naturally within the 75-second timeout (zero timeouts, 100% arrival). The 100/0/0 (all aggressive) configuration was significantly faster than every other tested mix (mean 30.6 s vs 40–46 s; KS test *p* < 0.001 in every comparison). Within the non-aggressive regime, cross time grew roughly monotonically with passive fraction, but adjacent mixes were not always statistically separable at this sample size. We discuss two important caveats: a model artifact at the aggressive endpoint, and statistical power.

### Methodology

**Build.** Godot 4.6.1 mono running headless on Windows 11. Simulation logic is pure GDScript; avoidance via `NavigationServer3D.agent_set_avoidance_callback`. Reproduction command:

```bash
godot --headless --path . -- --batch --seeds 10 --timeout 75 --out res://batch_n10.csv
```

**Configurations.** Seven points sampling the personality simplex:

| ID | Aggressive % | Neutral % | Passive % |
|---|---:|---:|---:|
| C1 | 100 | 0 | 0 |
| C2 | 50 | 50 | 0 |
| C3 | 50 | 0 | 50 |
| C4 | 33 | 34 | 33 |
| C5 | 0 | 100 | 0 |
| C6 | 0 | 50 | 50 |
| C7 | 0 | 0 | 100 |

**Per-run setup.** `agent_count = 100` evenly split between the two crowds. Crosswalk 16 m wide × 18 m long, 8 m sidewalks. Spawn area 7 m wide on each side. Per-agent start delay sampled uniformly from `[0, 1.2 s]` so crowds entered the crosswalk over the first ~1.2 s rather than en masse. Seeds `1..10` per config. Personality assignment used a deterministic largest-remainder allocation followed by a seeded shuffle, so the visible mix exactly matches the requested percentages.

**Outcome metric.** `cross_time` — wall time from the walk signal turning green to the last agent crossing the opposite curb line, accumulated from physics deltas during the WALKING state (pause-aware). Hard timeout at 75 s.

**Statistical test.** Two-sample Kolmogorov-Smirnov on per-config cross-time distributions (`scipy.stats.ks_2samp`).

### Results

Means sorted fastest to slowest:

| Rank | Config | n | Mean (s) | Median (s) | Std (s) | Min (s) | Max (s) | Timeouts |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | 100/0/0 | 10 | **30.57** | 30.54 | 1.74 | 27.52 | 33.00 | 0 |
| 2 | 50/50/0 | 10 | 40.42 | 39.43 | 3.24 | 36.57 | 46.10 | 0 |
| 3 | 50/0/50 | 10 | 40.91 | 40.69 | 2.10 | 37.60 | 44.90 | 0 |
| 4 | 33/34/33 | 10 | 41.39 | 41.45 | 2.28 | 37.17 | 45.33 | 0 |
| 5 | 0/100/0 | 10 | 43.61 | 43.14 | 2.30 | 40.80 | 47.98 | 0 |
| 6 | 0/50/50 | 10 | 44.77 | 44.76 | 2.26 | 40.68 | 49.25 | 0 |
| 7 | 0/0/100 | 10 | **46.16** | 46.33 | 1.72 | 43.10 | 48.68 | 0 |

Pairwise KS tests. `*` = *p* < 0.05; `n.s.` = not significant; `(.05)` = borderline (0.05 ≤ *p* < 0.10):

|  | 50/50/0 | 50/0/50 | 33/34/33 | 0/100/0 | 0/50/50 | 0/0/100 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **100/0/0** | * | * | * | * | * | * |
| **50/50/0** |   | n.s. | n.s. | * | * | * |
| **50/0/50** |   |     | n.s. | (.05) | * | * |
| **33/34/33** |   |     |     | n.s. | * | * |
| **0/100/0** |   |     |     |     | n.s. | (.05) |
| **0/50/50** |   |     |     |     |     | n.s. |

Findings:

1. **All-aggressive is unambiguously fastest.** Every comparison against `100/0/0` returns *p* ≈ 0 and KS statistic *D* = 1.0 (completely non-overlapping distributions). The all-aggressive mix completes the crossing 9.85 seconds faster than the next-best configuration.
2. **Cross time grows roughly monotonically with passive fraction** in the non-aggressive half: 40.4 → 40.9 → 41.4 → 43.6 → 44.8 → 46.2 s along the `50/50/0 → 0/0/100` path.
3. **Mid-range mixes form an indistinguishable cluster at N=10.** `50/50/0`, `50/0/50`, and `33/34/33` all sit in the 40–41 s band with overlapping distributions (pairwise KS *p* > 0.4).
4. **Pure neutral vs pure passive is borderline.** `0/100/0` vs `0/0/100` returns *p* = 0.052 — directionally clear (3-second gap in means) but not significant at α = 0.05 with this sample size.

### Discussion

#### Caveat 1 — model artifact at the aggressive endpoint

The aggressive lead is partially an artifact of how aggressive agents interact with `NavigationServer3D`'s RVO in this build. With `rvo_compliance = 0.20`, the avoidance callback returns `lerp(preferred, safe, 0.20)`, i.e. 80% of the velocity comes from the agent's preferred (straight-toward-destination) vector and only 20% from RVO's collision-avoiding correction. Aggressive agents barely deviate. Two opposing aggressive agents end up walking through each other (modulo a small overlap-resolution pass), which is not what real crowds do. The 100/0/0 advantage therefore overstates the gain a similar mix would provide under a more realistic compliance model. The ranking among mixed configs is more representative than the 100/0/0 outlier.

#### Caveat 2 — statistical power

N=10 cleanly separates widely-spaced configs (any vs all-aggressive) but is insufficient for finer distinctions. To resolve adjacent mixes at α = 0.05 you would want N ≥ 30; to map the simplex finely enough to estimate an optimization landscape you would want N ≥ 100 per cell. The current sequential-run wall budget for N = 100 over a 7-config sweep is roughly an order of magnitude beyond practical without rewriting the avoidance step (see Roadmap).

#### Caveat 3 — single regime tested

Only one regime of agent count, crosswalk geometry, and personality-profile multipliers was tested. Higher densities triggering the pedestrian fundamental diagram, or different walk-signal duration, may rerank the configs.

### Limitations

- Simulation time is bound to the engine physics tick (60 Hz). The headless batch runs at 1× wall clock — 70 runs took 48 minutes.
- `NavigationServer3D` cannot be stepped manually faster than the engine main loop.
- The avoidance callback receives one safe velocity per agent per tick; multi-step lookahead is not modelled.
- Agents are point-masses with capped lateral speed; no rotational state, group-formation behaviour, or fatigue.
- `right_pass_probability = 0.8` bakes in a right-handed convention.

### Reproducing this study

```bash
godot --headless --path . -- --batch --seeds 10 --timeout 75 --out res://batch_n10.csv
```

The dataset analyzed above is `batch_n10.csv` in the repo root. Analysis was done with pandas/scipy; the snippet is short enough to inline in any notebook.

---

## Headless batch runner

Activated by passing `--batch` after the GDScript-arg separator `--`:

```bash
godot --headless --path . -- --batch [options]
```

| Option | Default | Effect |
|---|---|---|
| `--seeds N` | 100 | Number of random seeds per config |
| `--timeout S` | 30 | Per-run wall-time cutoff in simulation seconds |
| `--out PATH` | `res://batch_results.csv` | Output CSV path |
| `--agents N` | 100 | Override `agent_count` for all runs |

The default sweep uses 7 representative configurations × `--seeds` seeds. The CSV columns are:

```
aggressive, neutral, passive, seed, agents, cross_time, arrived, timed_out, wall_msec
```

Smoke-test first with `--seeds 2` (14 runs, ~10 minutes) before kicking off a full overnight run.

## Project structure

```
.
├── README.md
├── batch_n10.csv          # the research-note dataset
├── docs/
│   └── crowd_simulator_design.md
├── scenes/
│   ├── main.tscn          # interactive single-sim with sliders
│   └── tournament.tscn    # 5x3 grid sweeping the personality spectrum
├── scripts/
│   ├── crowd_simulation.gd  # the sim itself + tile + batch runner
│   └── tournament.gd        # grid orchestrator
├── icon.svg
└── project.godot
```

The whole simulation is a single `CrowdSimulation` Node3D (`scripts/crowd_simulation.gd`). It owns the world geometry, the per-agent packed arrays, the RVO setup, the rendering MultiMesh, and either the slider HUD or a tile-label depending on whether `embedded_in_grid` is set.

## Performance notes

The interactive single sim runs at 60 fps with 100 agents on mid-range hardware. The 5×3 tournament with 15 tiles × 70 agents = 1050 agents may dip below 60 fps; if so, lower `tile_agent_count` to 50 in the tournament inspector. The simulation is correct regardless of render fps because Godot keeps physics ticks fixed at 60 Hz.

## Roadmap

1. **Inline avoidance step** — replace `NavigationServer3D` calls with a small ORCA / velocity-obstacle implementation in pure GDScript (or GDExtension). Decouples sim time from engine clock. Unlocks 100–1000× wall-time speedup for Monte Carlo sweeps. The current `batch_n10.csv` is the ground-truth baseline against which the inline implementation will be calibrated (KS test over the same 7 configs).
2. **Higher-N simplex sweep** (N ≥ 100, finer grid) to map the personality-mix optimization landscape and estimate the Pareto front of crossing time vs realism.
3. **Calibration to real pedestrian flow data.** Adjust personality multipliers (especially `rvo_compliance` for aggressive) until the model reproduces published flow-density curves before drawing crowd-management conclusions.
4. **Multi-process parallelism** for the batch runner — one Godot process per CPU core, disjoint seed ranges, cuts wall time linearly.

## Acknowledgments

The model draws on standard literature for multi-agent pedestrian dynamics:

- van den Berg, J., Lin, M., Manocha, D. (2008). *Reciprocal Velocity Obstacles for Real-Time Multi-Agent Navigation.*
- van den Berg, J., Guy, S., Lin, M., Manocha, D. (2011). *Reciprocal n-body Collision Avoidance.* (ORCA.)
- Helbing, D., Molnár, P. (1995). *Social force model for pedestrian dynamics.*
- Moussaïd, M., Helbing, D., Theraulaz, G. (2011). *How simple rules determine pedestrian behaviour and crowd disasters.*

## Keywords

Godot 4 crowd simulation · Godot 4.6 pedestrian dynamics · NavigationServer3D RVO avoidance · ORCA reciprocal velocity obstacle · agent-based pedestrian dynamics · multi-agent simulation · GDScript · MultiMesh crowd rendering · Monte Carlo simulation · personality mix · social force model · pedestrian fundamental diagram · headless batch runner · Kolmogorov-Smirnov test.

## License

[MIT](LICENSE) © 2026 Josh Auriemma.
