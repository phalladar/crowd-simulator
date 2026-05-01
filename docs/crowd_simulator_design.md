# Crowd Simulator Design

## Goal

Simulate two pedestrian crowds crossing a street from opposite sidewalks after a walk signal. The first implementation is an isometric 3D prototype using upright capsule agents, with behavior constrained to what a person could plausibly do while crossing: walk forward, slow, stop, and sidestep.

## Godot Structure

- `scenes/main.tscn`: boots the simulation controller.
- `scripts/crowd_simulation.gd`: owns the world setup, agent state arrays, spatial hash, local avoidance, and capsule rendering.

The prototype deliberately avoids one `CharacterBody3D` node per pedestrian. Agents are stored in packed arrays and rendered through two `MultiMeshInstance3D` nodes, one for each crowd. That keeps the starting case simple at 100 agents and gives the project a path toward thousands.

## Behavior Model

Each agent stores:

- 2D ground-plane position and velocity.
- Destination on the opposite sidewalk.
- Preferred walking speed.
- Body radius and personal-space padding.
- A small handedness value used to break symmetric avoidance decisions.
- Crowd id.

Every fixed simulation tick:

1. Agents are inserted into a spatial hash grid.
2. Each active agent queries nearby neighbors only.
3. The agent samples candidate walking directions inside a forward visual cone.
4. Each candidate direction is scored by predicted collision-free distance, detour size, turn inertia, and a conflict-only local-gap preference.
5. The chosen speed is reduced when time-to-collision is short and when local density is high.
6. If a head-on crowd conflict would otherwise make the pedestrian stop, a low-speed sidestep release chooses the side with more usable local space.
7. The selected velocity is acceleration-limited and constrained to avoid backward motion.
8. A next-frame contact guard brakes forward motion on predicted contacts, but preserves planned lateral sidestepping.
9. A tiny overlap pass removes residual penetrations without visible popping.

The important constraint is that feasible velocities never include backward motion relative to the current destination direction. If the path is blocked, an agent should slow, stop, or sidestep.

The local avoidance model is now closer to visual pedestrian heuristics than to pure ORCA. Pedestrians prefer a mostly direct route, but they look ahead for likely collisions, choose a clearer nearby direction when needed, and otherwise slow or sidestep. Bidirectional ordering should emerge from local choices rather than from pre-separated starting lanes.

Agents in the same crowd are predicted as moving with the group once the signal changes. That keeps the whole group starting together while still preserving spacing.

Each crowd starts in a compact square-ish waiting area centered on its side of the street, like a group waiting at a block corner. Destination X positions stay near the agent's starting X position, with small jitter and a small chance of aiming slightly outside the main group footprint. That keeps the initial movement mostly forward instead of diagonal.

The contact guard is deliberately conservative. The visual heuristic is the primary planner, but dense crowds can still produce tight contacts. The guard brakes forward motion first; sideways movement comes only from the main steering decision and is acceleration-limited. This keeps blocked pedestrians from freezing in symmetric head-on jams while avoiding lateral impulse pops. The overlap pass accumulates small corrections and caps each agent's per-frame displacement to avoid visible popping.

## Research Notes

The reset is based on a few established pedestrian-modeling principles:

- Social-force models use acceleration toward desired velocity, distance-keeping forces, and self-organization effects.
- Visual heuristic models choose walking direction from unobstructed lines of sight and choose speed from safe stopping distance.
- Real crowd speed should decline as local density rises, matching the pedestrian fundamental diagram.
- ORCA/RVO remains useful for formal collision-free multi-agent motion, but it can look robotic if the preferred velocity and fallback corrections are not constrained by human gait.

## Scaling Plan

The current GDScript version should be fine for the initial 100-agent prototype and useful for tuning behavior. To scale into the thousands:

- Keep `MultiMeshInstance3D` rendering.
- Keep fixed-timestep simulation, but cap per-frame catch-up work so slow frames do not create a backlog spiral.
- Reuse neighbor result buffers to reduce allocations.
- Split simulation updates across frames for non-visible or far-away agents if needed.
- Move the core avoidance loop to C# or GDExtension if GDScript becomes the bottleneck.
- Add a lower-cost far-field model for agents still waiting in the queue.

## Tuning Knobs

The main exported parameters on `CrowdSimulation` are:

- `agent_count`
- `fixed_tick_hz`
- `max_substeps`
- `simulation_budget_ms`
- `crosswalk_width`
- `crossing_length`
- `body_radius`
- `personal_space`
- `min_speed` / `max_speed`
- `max_acceleration`
- `max_side_speed`
- `max_lateral_acceleration`
- `reaction_time`
- `vision_angle_degrees`
- `vision_horizon`
- `direction_sample_count`
- `density_radius`
- `jam_density`
- `destination_lateral_jitter`
- `neighbor_radius`
- `max_opposing_neighbors`
- `max_same_crowd_neighbors`
- `gap_preference_strength`
- `jam_release_side_speed`
- `waiting_area_width`
- `destination_area_width`
- `offside_destination_chance`
- `offside_destination_extra`
- `collision_padding`
- `contact_guard_padding`
- `max_overlap_correction`
- `overlap_iterations`
- `grid_cell_size`

Runtime keys in the prototype:

- `Space`: pause/resume
- `R`: reset
- `[` / `]`: decrease/increase agent count
