extends Node3D
class_name CrowdSimulation

# When set true by an orchestrator (e.g. tournament.gd) the node skips
# building its own camera, lighting, world environment, debug overlay,
# slider HUD, batch parsing, and input handling. The street/agents/RVO
# still build normally so a tile renders correctly when its parent
# transform offsets it within a grid scene.
@export var embedded_in_grid: bool = false
@export var tile_label: String = ""

signal run_completed(cross_time: float, arrived: int)

const STATE_WAITING := 0
const STATE_WALKING := 1
const STATE_DONE := 2

const CROWD_A := 0
const CROWD_B := 1

const EPSILON := 0.00001

const PERSONALITY_AGGRESSIVE := 0
const PERSONALITY_NEUTRAL := 1
const PERSONALITY_PASSIVE := 2

# Per-personality multipliers applied on top of the global tuning knobs.
# Aggressive agents largely ignore RVO's safe-velocity correction (low
# rvo_compliance), so they hold course while neutral/passive agents route
# around them. Tint is the lerp amount toward black (-) or white (+) used
# for per-instance albedo.
const PERSONALITY_PROFILES := [
	{ "time_horizon_mul": 0.35, "padding_mul": 0.4, "max_lateral_mul": 0.30, "speed_mul": 1.15, "rvo_compliance": 0.20, "tint": -0.30 },
	{ "time_horizon_mul": 1.00, "padding_mul": 1.0, "max_lateral_mul": 1.00, "speed_mul": 1.00, "rvo_compliance": 1.00, "tint":  0.00 },
	{ "time_horizon_mul": 1.60, "padding_mul": 1.4, "max_lateral_mul": 1.60, "speed_mul": 0.90, "rvo_compliance": 1.00, "tint":  0.30 },
]

@export_group("Simulation")
@export_range(10, 10000, 10) var agent_count: int = 100
@export_range(1, 100000, 1) var simulation_seed: int = 42
@export_range(0.0, 10.0, 0.1) var auto_start_seconds: float = 1.0
@export_range(0.0, 3.0, 0.1) var max_start_delay: float = 1.2

@export_group("Street")
@export_range(4.0, 80.0, 0.5) var crosswalk_width: float = 16.0
@export_range(4.0, 80.0, 0.5) var crossing_length: float = 18.0
@export_range(2.0, 40.0, 0.5) var sidewalk_depth: float = 8.0
@export_range(0.0, 4.0, 0.1) var curb_buffer: float = 0.8

@export_group("Pedestrians")
@export_range(0.15, 0.6, 0.01) var body_radius: float = 0.32
@export_range(0.2, 3.0, 0.05) var min_speed: float = 1.05
@export_range(0.2, 3.5, 0.05) var max_speed: float = 1.55
@export_range(0.5, 1.0, 0.05) var right_pass_probability: float = 0.8
@export_range(0.0, 30.0, 0.5) var handedness_bias_degrees: float = 3.0
@export_range(0.05, 1.5, 0.05) var max_lateral_speed: float = 0.35
@export_range(0.0, 1.0, 0.05) var destination_lateral_jitter: float = 0.45
@export_range(2.0, 16.0, 0.1) var waiting_area_width: float = 7.0
@export_range(2.0, 16.0, 0.1) var destination_area_width: float = 7.0
@export_range(0.0, 0.5, 0.01) var offside_destination_chance: float = 0.08
@export_range(0.0, 4.0, 0.1) var offside_destination_extra: float = 1.4
@export_range(0.4, 2.0, 0.05) var spawn_spacing: float = 0.85

@export_group("Personalities")
@export_range(0, 100, 1) var aggressive_percent: int = 0
@export_range(0, 100, 1) var neutral_percent: int = 100
@export_range(0, 100, 1) var passive_percent: int = 0

@export_group("Avoidance (RVO)")
@export_range(1.0, 20.0, 0.5) var rvo_neighbor_distance: float = 5.0
@export_range(2, 32, 1) var rvo_max_neighbors: int = 12
@export_range(0.5, 8.0, 0.1) var rvo_time_horizon: float = 2.0
@export_range(0.0, 0.5, 0.01) var collision_padding: float = 0.08
@export_range(0.0, 0.5, 0.01) var max_overlap_correction: float = 0.03
@export_range(1, 6, 1) var overlap_iterations: int = 1
@export_range(0.5, 8.0, 0.1) var grid_cell_size: float = 1.5

@export_group("Rendering")
@export_range(0.8, 2.4, 0.05) var capsule_height: float = 1.7
@export_range(8.0, 80.0, 1.0) var camera_orthographic_size: float = 34.0

@export_group("Camera Controls")
@export_range(0.001, 0.03, 0.001) var mouse_rotate_sensitivity: float = 0.008
@export_range(0.1, 3.0, 0.05) var mouse_pan_sensitivity: float = 1.0
@export_range(0.05, 0.5, 0.01) var mouse_zoom_step: float = 0.12
@export_range(8.0, 80.0, 1.0) var min_camera_orthographic_size: float = 8.0
@export_range(20.0, 140.0, 1.0) var max_camera_orthographic_size: float = 80.0

var positions := PackedVector2Array()
var velocities := PackedVector2Array()
var desired_dirs := PackedVector2Array()
var destinations := PackedVector2Array()
var start_delay := PackedFloat32Array()
var radii := PackedFloat32Array()
var preferred_speeds := PackedFloat32Array()
var handedness := PackedFloat32Array()
var crowd_ids := PackedInt32Array()
var active := PackedByteArray()
var personalities := PackedInt32Array()
var personal_max_lateral := PackedFloat32Array()
var rvo_compliance := PackedFloat32Array()
var agent_rids: Array[RID] = []
var _position_corrections := PackedVector2Array()

var _grid: Dictionary = {}
var _navigation_map: RID
var _rng := RandomNumberGenerator.new()
var _elapsed := 0.0
var _state := STATE_WAITING
var _running := true
var _arrived_count := 0
var _crowd_a_count := 0
var _crowd_b_count := 0
var _last_simulation_ms := 0.0
var _walk_elapsed := 0.0
var _walk_final_seconds := 0.0

var _batch_mode := false
var _batch_configs: Array = []
var _batch_index := 0
var _batch_results: Array = []
var _batch_timeout_seconds := 30.0
var _batch_output_path := "res://batch_results.csv"
var _batch_run_started_msec := 0
var _batch_started_msec := 0
var _batch_seed_count := 100

var _camera: Camera3D
var _camera_target := Vector3.ZERO
var _camera_yaw := 0.0
var _camera_pitch := 0.0
var _camera_distance := 1.0
var _rotating_camera := false
var _panning_camera := false
var _crowd_a_mesh: MultiMeshInstance3D
var _crowd_b_mesh: MultiMeshInstance3D
var _debug_label: Label
var _stop_material: StandardMaterial3D
var _walk_material: StandardMaterial3D
var _crowd_a_base_color := Color(0.11, 0.36, 0.95)
var _crowd_b_base_color := Color(0.88, 0.25, 0.17)
var _aggressive_slider: HSlider
var _neutral_slider: HSlider
var _passive_slider: HSlider
var _aggressive_value_label: Label
var _neutral_value_label: Label
var _passive_value_label: Label
var _suppress_slider_callbacks := false
var _tile_label_3d: Label3D


func _ready() -> void:
	if not embedded_in_grid:
		_parse_batch_args()
	_rng.seed = simulation_seed
	_setup_navigation_map()
	_build_world()
	if _batch_mode and not embedded_in_grid:
		_start_batch()
	else:
		reset_simulation()


func _exit_tree() -> void:
	_free_agent_rids()
	if _navigation_map.is_valid():
		NavigationServer3D.free_rid(_navigation_map)


func _setup_navigation_map() -> void:
	_navigation_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(_navigation_map, true)
	NavigationServer3D.map_set_up(_navigation_map, Vector3.UP)


func _process(_delta: float) -> void:
	_update_agent_visuals()
	_update_debug_label()
	_update_tile_label()


func _update_tile_label() -> void:
	if not is_instance_valid(_tile_label_3d):
		return
	var time_text := "—"
	if _state == STATE_WALKING:
		time_text = "%.1fs · %d/%d" % [_walk_elapsed, _arrived_count, agent_count]
	elif _state == STATE_DONE:
		time_text = "%.2fs · DONE" % _walk_final_seconds
	_tile_label_3d.text = "%s\n%s" % [tile_label, time_text]


func _physics_process(delta: float) -> void:
	if not _running:
		return

	if _state == STATE_WAITING:
		_elapsed += delta
		if _elapsed >= auto_start_seconds:
			_state = STATE_WALKING
			_set_walk_signal(true)
		return

	if _state != STATE_WALKING:
		return

	_walk_elapsed += delta

	var frame_start_usec := Time.get_ticks_usec()

	# Belt-and-suspenders: clean up any residual overlaps from the previous
	# frame's RVO output before feeding positions back to the server.
	_resolve_overlaps()

	for i in range(agent_count):
		if active[i] == 0:
			NavigationServer3D.agent_set_velocity(agent_rids[i], Vector3.ZERO)
			continue

		if start_delay[i] > 0.0:
			start_delay[i] -= delta
			NavigationServer3D.agent_set_position(agent_rids[i], _to_3d(positions[i]))
			NavigationServer3D.agent_set_velocity(agent_rids[i], Vector3.ZERO)
			continue

		_refresh_desired_direction(i)
		var bias := -handedness[i] * deg_to_rad(handedness_bias_degrees)
		var preferred_dir := desired_dirs[i].rotated(bias).normalized()
		var preferred_velocity_2d := preferred_dir * preferred_speeds[i]

		NavigationServer3D.agent_set_position(agent_rids[i], _to_3d(positions[i]))
		NavigationServer3D.agent_set_velocity(agent_rids[i], _to_3d(preferred_velocity_2d))

	# NavigationServer3D processes RVO after this body completes; the
	# avoidance callback fires per agent within the same physics frame and
	# applies the safe velocity to positions.

	_last_simulation_ms = float(Time.get_ticks_usec() - frame_start_usec) / 1000.0

	if _arrived_count >= agent_count:
		_state = STATE_DONE
		_walk_final_seconds = _walk_elapsed
		if _batch_mode:
			_record_batch_result(false)
		else:
			run_completed.emit(_walk_final_seconds, _arrived_count)
		return

	if _batch_mode and _walk_elapsed > _batch_timeout_seconds:
		_state = STATE_DONE
		_walk_final_seconds = _walk_elapsed
		_record_batch_result(true)


func _on_avoidance(safe_velocity: Vector3, agent_index: int) -> void:
	if active[agent_index] == 0:
		velocities[agent_index] = Vector2.ZERO
		return

	if _state != STATE_WALKING or start_delay[agent_index] > 0.0:
		velocities[agent_index] = Vector2.ZERO
		return

	var safe_2d := Vector2(safe_velocity.x, safe_velocity.z)

	# Aggressive agents (low compliance) mostly use their preferred velocity
	# and ignore RVO's deviation; RVO still treats them as moving obstacles
	# so neutral/passive agents route around them.
	var preferred_2d := desired_dirs[agent_index] * preferred_speeds[agent_index]
	safe_2d = preferred_2d.lerp(safe_2d, rvo_compliance[agent_index])

	# Decompose into goal-relative forward and lateral components.
	# Real humans walk forward; sidestepping is slow and effortful. RVO is
	# happy to pick large lateral velocities when forward is blocked, which
	# reads as unnatural shimmying. Constrain: no backward motion, and cap
	# lateral magnitude tight. When fully blocked the agent just stops.
	var goal_dir := desired_dirs[agent_index]
	var raw_forward := safe_2d.dot(goal_dir)
	var forward_speed := maxf(raw_forward, 0.0)
	var lateral := safe_2d - goal_dir * raw_forward
	var lateral_cap := personal_max_lateral[agent_index]
	if lateral.length_squared() > lateral_cap * lateral_cap:
		lateral = lateral.normalized() * lateral_cap
	safe_2d = goal_dir * forward_speed + lateral

	velocities[agent_index] = safe_2d

	var delta := get_physics_process_delta_time()
	positions[agent_index] += safe_2d * delta
	positions[agent_index].x = clampf(
		positions[agent_index].x,
		-_walkable_half_width() + radii[agent_index],
		_walkable_half_width() - radii[agent_index]
	)

	if _has_reached_opposite_side(agent_index):
		active[agent_index] = 0
		velocities[agent_index] = Vector2.ZERO
		NavigationServer3D.agent_set_avoidance_enabled(agent_rids[agent_index], false)
		_arrived_count += 1


func _to_3d(v: Vector2) -> Vector3:
	return Vector3(v.x, 0.0, v.y)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		_handle_key_input(event as InputEventKey)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)


func _handle_key_input(key_event: InputEventKey) -> void:
	if not key_event.pressed or key_event.echo:
		return

	var handled := true
	match key_event.keycode:
		KEY_SPACE:
			_running = not _running
		KEY_R:
			reset_simulation()
		KEY_BRACKETLEFT:
			agent_count = maxi(10, agent_count - _agent_count_step())
			reset_simulation()
		KEY_BRACKETRIGHT:
			agent_count = mini(10000, agent_count + _agent_count_step())
			reset_simulation()
		_:
			handled = false

	if handled:
		get_viewport().set_input_as_handled()


func _handle_mouse_button(mouse_event: InputEventMouseButton) -> void:
	var handled := true
	match mouse_event.button_index:
		MOUSE_BUTTON_LEFT:
			_rotating_camera = mouse_event.pressed
		MOUSE_BUTTON_MIDDLE:
			_panning_camera = mouse_event.pressed
		MOUSE_BUTTON_WHEEL_UP:
			if mouse_event.pressed:
				_zoom_camera(-1.0)
		MOUSE_BUTTON_WHEEL_DOWN:
			if mouse_event.pressed:
				_zoom_camera(1.0)
		_:
			handled = false

	if handled:
		get_viewport().set_input_as_handled()


func _handle_mouse_motion(mouse_event: InputEventMouseMotion) -> void:
	if _rotating_camera:
		_camera_yaw -= mouse_event.relative.x * mouse_rotate_sensitivity
		_camera_pitch = clampf(
			_camera_pitch - mouse_event.relative.y * mouse_rotate_sensitivity,
			deg_to_rad(24.0),
			deg_to_rad(78.0)
		)
		_apply_camera_transform()
		get_viewport().set_input_as_handled()
	elif _panning_camera:
		_pan_camera(mouse_event.relative)
		get_viewport().set_input_as_handled()


func _zoom_camera(direction: float) -> void:
	if not is_instance_valid(_camera):
		return

	var zoom_multiplier := 1.0 + mouse_zoom_step * direction
	_camera.size = clampf(_camera.size * zoom_multiplier, min_camera_orthographic_size, max_camera_orthographic_size)
	camera_orthographic_size = _camera.size


func _pan_camera(screen_delta: Vector2) -> void:
	if not is_instance_valid(_camera):
		return

	var viewport_height := maxf(1.0, get_viewport().get_visible_rect().size.y)
	var world_units_per_pixel := _camera.size / viewport_height * mouse_pan_sensitivity
	var right := _ground_projected(_camera.global_transform.basis.x, Vector3.RIGHT)
	var up := _ground_projected(_camera.global_transform.basis.y, -_camera.global_transform.basis.z)
	_camera_target -= right * screen_delta.x * world_units_per_pixel
	_camera_target += up * screen_delta.y * world_units_per_pixel
	_camera_target.y = 0.0
	_apply_camera_transform()


func _ground_projected(direction: Vector3, fallback: Vector3) -> Vector3:
	var projected := Vector3(direction.x, 0.0, direction.z)
	if projected.length_squared() <= EPSILON:
		projected = Vector3(fallback.x, 0.0, fallback.z)
	if projected.length_squared() <= EPSILON:
		return Vector3.FORWARD

	return projected.normalized()


func reset_simulation() -> void:
	_free_agent_rids()
	_rng.seed = simulation_seed
	_elapsed = 0.0
	_walk_elapsed = 0.0
	_walk_final_seconds = 0.0
	_state = STATE_WAITING
	_arrived_count = 0
	_crowd_a_count = int(agent_count / 2)
	_crowd_b_count = agent_count - _crowd_a_count

	_resize_agent_arrays(agent_count)
	_spawn_crowd(CROWD_A, 0, _crowd_a_count)
	_spawn_crowd(CROWD_B, _crowd_a_count, _crowd_b_count)
	if not _batch_mode:
		_rebuild_agent_multimeshes()
		_set_walk_signal(false)


func _free_agent_rids() -> void:
	for rid in agent_rids:
		if rid.is_valid():
			NavigationServer3D.free_rid(rid)
	agent_rids.clear()


func _refresh_desired_direction(agent_index: int) -> void:
	var to_destination := destinations[agent_index] - positions[agent_index]
	if to_destination.length_squared() > 0.0001:
		desired_dirs[agent_index] = to_destination.normalized()


func _has_reached_opposite_side(agent_index: int) -> bool:
	if crowd_ids[agent_index] == CROWD_A:
		return positions[agent_index].y >= destinations[agent_index].y - 0.05

	return positions[agent_index].y <= destinations[agent_index].y + 0.05


func _resolve_overlaps() -> void:
	for iteration in range(overlap_iterations):
		_rebuild_grid()
		for i in range(agent_count):
			_position_corrections[i] = Vector2.ZERO

		for i in range(agent_count):
			if active[i] == 0:
				continue

			for j in _query_overlap_neighbors(i):
				if j <= i or active[j] == 0:
					continue

				var minimum := radii[i] + radii[j] + collision_padding
				var offset := positions[i] - positions[j]
				var distance_sq := offset.length_squared()
				if distance_sq >= minimum * minimum:
					continue

				var distance := sqrt(maxf(distance_sq, 0.0001))
				var push := (minimum - distance) * 0.3
				var separation_direction := _safe_normalized(offset, Vector2(handedness[i], 0.0))
				_position_corrections[i] += separation_direction * push
				_position_corrections[j] -= separation_direction * push

		for i in range(agent_count):
			if active[i] == 0:
				continue

			var correction := _position_corrections[i]
			if correction.length_squared() > max_overlap_correction * max_overlap_correction:
				correction = correction.normalized() * max_overlap_correction

			positions[i] += correction
			positions[i].x = clampf(positions[i].x, -_walkable_half_width() + radii[i], _walkable_half_width() - radii[i])


func _rebuild_grid() -> void:
	_grid.clear()
	for i in range(agent_count):
		if active[i] == 0:
			continue
		var cell := _cell_for_position(positions[i])
		if not _grid.has(cell):
			_grid[cell] = []
		_grid[cell].append(i)


func _query_overlap_neighbors(agent_index: int) -> Array:
	var result: Array = []
	var origin := positions[agent_index]
	var cell := _cell_for_position(origin)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(cell.x + dx, cell.y + dy)
			if _grid.has(key):
				result.append_array(_grid[key])
	return result


func _cell_for_position(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / grid_cell_size), floori(p.y / grid_cell_size))


func _resize_agent_arrays(size: int) -> void:
	positions.resize(size)
	velocities.resize(size)
	_position_corrections.resize(size)
	desired_dirs.resize(size)
	destinations.resize(size)
	start_delay.resize(size)
	radii.resize(size)
	preferred_speeds.resize(size)
	handedness.resize(size)
	crowd_ids.resize(size)
	active.resize(size)
	personalities.resize(size)
	personal_max_lateral.resize(size)
	rvo_compliance.resize(size)
	agent_rids.resize(size)


func _spawn_crowd(crowd_id: int, start_index: int, count: int) -> void:
	var spawn_half_width := minf(waiting_area_width * 0.5, _walkable_half_width() - body_radius)
	var destination_half_width := minf(destination_area_width * 0.5, _walkable_half_width() - body_radius)
	var columns := maxi(1, int(floor((spawn_half_width * 2.0) / spawn_spacing)))
	var direction_z := 1.0 if crowd_id == CROWD_A else -1.0
	var start_edge_z := -crossing_length * 0.5 - curb_buffer if crowd_id == CROWD_A else crossing_length * 0.5 + curb_buffer
	var destination_z := crossing_length * 0.5 + sidewalk_depth * 0.55 if crowd_id == CROWD_A else -crossing_length * 0.5 - sidewalk_depth * 0.55
	var center_offset := float(columns - 1) * spawn_spacing * 0.5
	var bag := _make_personality_bag(count)

	for local_index in range(count):
		var agent_index := start_index + local_index
		var row := local_index / columns
		var column := local_index % columns
		var x_jitter := _rng.randf_range(-0.3, 0.3)
		var z_jitter := _rng.randf_range(-0.08, 0.08)
		var x := clampf(
			float(column) * spawn_spacing - center_offset + x_jitter,
			-spawn_half_width,
			spawn_half_width
		)
		var z := start_edge_z - direction_z * float(row) * spawn_spacing + z_jitter
		var destination_x := _destination_x_for_start(x, destination_half_width)
		var personality := bag[local_index]
		var profile: Dictionary = PERSONALITY_PROFILES[personality]
		var speed_mul := float(profile["speed_mul"])
		var lateral_mul := float(profile["max_lateral_mul"])
		var padding_mul := float(profile["padding_mul"])
		var horizon_mul := float(profile["time_horizon_mul"])

		positions[agent_index] = Vector2(x, z)
		velocities[agent_index] = Vector2.ZERO
		destinations[agent_index] = Vector2(destination_x, destination_z)
		desired_dirs[agent_index] = Vector2(destination_x - x, destination_z - z).normalized()
		radii[agent_index] = body_radius * _rng.randf_range(0.92, 1.08)
		preferred_speeds[agent_index] = _rng.randf_range(min_speed, max_speed) * speed_mul
		handedness[agent_index] = -1.0 if _rng.randf() < right_pass_probability else 1.0
		start_delay[agent_index] = _rng.randf_range(0.0, max_start_delay)
		crowd_ids[agent_index] = crowd_id
		active[agent_index] = 1
		personalities[agent_index] = personality
		personal_max_lateral[agent_index] = max_lateral_speed * lateral_mul
		rvo_compliance[agent_index] = float(profile["rvo_compliance"])

		var rid := NavigationServer3D.agent_create()
		agent_rids[agent_index] = rid
		NavigationServer3D.agent_set_map(rid, _navigation_map)
		NavigationServer3D.agent_set_avoidance_enabled(rid, true)
		NavigationServer3D.agent_set_use_3d_avoidance(rid, false)
		NavigationServer3D.agent_set_radius(rid, radii[agent_index] + collision_padding * 0.5 * padding_mul)
		NavigationServer3D.agent_set_height(rid, capsule_height)
		NavigationServer3D.agent_set_max_speed(rid, max_speed + 0.5)
		NavigationServer3D.agent_set_neighbor_distance(rid, rvo_neighbor_distance)
		NavigationServer3D.agent_set_max_neighbors(rid, rvo_max_neighbors)
		NavigationServer3D.agent_set_time_horizon_agents(rid, rvo_time_horizon * horizon_mul)
		NavigationServer3D.agent_set_time_horizon_obstacles(rid, rvo_time_horizon * horizon_mul)
		NavigationServer3D.agent_set_position(rid, _to_3d(positions[agent_index]))
		NavigationServer3D.agent_set_velocity_forced(rid, Vector3.ZERO)
		NavigationServer3D.agent_set_avoidance_callback(rid, _on_avoidance.bind(agent_index))


func _build_world() -> void:
	if _batch_mode:
		# Headless: no meshes, no lighting, no camera, no UI. Navigation
		# map is already set up; that's all the sim needs to step.
		set_process(false)
		set_process_unhandled_input(false)
		return
	if embedded_in_grid:
		# Tile inside a tournament grid: street + agents + per-tile label,
		# but no camera, no lighting, no world env, no input, no slider HUD.
		# The orchestrator owns those at the scene level.
		set_process_unhandled_input(false)
		_build_environment_meshes()
		_build_signal_lights()
		_build_tile_label_3d()
		return
	_build_environment_meshes()
	_build_signal_lights()
	_build_camera_and_lighting()
	_build_debug_overlay()


func _build_tile_label_3d() -> void:
	_tile_label_3d = Label3D.new()
	_tile_label_3d.text = tile_label
	_tile_label_3d.font_size = 96
	_tile_label_3d.pixel_size = 0.025
	# Sit above the south sidewalk (screen-up side relative to the iso
	# camera), clear of the crosswalk where agents walk.
	_tile_label_3d.position = Vector3(0.0, 3.5, -(crossing_length * 0.5 + sidewalk_depth * 0.5))
	_tile_label_3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tile_label_3d.outline_size = 16
	_tile_label_3d.modulate = Color(1, 1, 1)
	_tile_label_3d.outline_modulate = Color(0, 0, 0)
	_tile_label_3d.no_depth_test = true
	add_child(_tile_label_3d)


func _build_environment_meshes() -> void:
	var street_material := _make_material(Color(0.08, 0.085, 0.09))
	var sidewalk_material := _make_material(Color(0.42, 0.43, 0.40))
	var stripe_material := _make_material(Color(0.9, 0.88, 0.78))
	var curb_material := _make_material(Color(0.78, 0.78, 0.74))

	_add_box("Street", Vector3(crosswalk_width + 7.0, 0.08, crossing_length), Vector3(0.0, -0.04, 0.0), street_material)
	_add_box("NorthSidewalk", Vector3(crosswalk_width + 7.0, 0.18, sidewalk_depth), Vector3(0.0, 0.0, crossing_length * 0.5 + sidewalk_depth * 0.5), sidewalk_material)
	_add_box("SouthSidewalk", Vector3(crosswalk_width + 7.0, 0.18, sidewalk_depth), Vector3(0.0, 0.0, -crossing_length * 0.5 - sidewalk_depth * 0.5), sidewalk_material)
	_add_box("NorthCurb", Vector3(crosswalk_width + 7.0, 0.16, 0.18), Vector3(0.0, 0.09, crossing_length * 0.5), curb_material)
	_add_box("SouthCurb", Vector3(crosswalk_width + 7.0, 0.16, 0.18), Vector3(0.0, 0.09, -crossing_length * 0.5), curb_material)

	var stripe_count := 8
	for stripe_index in range(stripe_count):
		var z := lerpf(-crossing_length * 0.5 + 1.1, crossing_length * 0.5 - 1.1, float(stripe_index) / float(stripe_count - 1))
		_add_box("CrosswalkStripe", Vector3(crosswalk_width, 0.04, 0.35), Vector3(0.0, 0.04, z), stripe_material)


func _build_signal_lights() -> void:
	_stop_material = _make_emissive_material(Color(0.45, 0.03, 0.02), false)
	_walk_material = _make_emissive_material(Color(0.02, 0.5, 0.12), false)

	_add_signal_pole(Vector3(-crosswalk_width * 0.5 - 1.0, 0.0, -crossing_length * 0.5 - 0.5))
	_add_signal_pole(Vector3(crosswalk_width * 0.5 + 1.0, 0.0, crossing_length * 0.5 + 0.5))


func _build_camera_and_lighting() -> void:
	_camera = Camera3D.new()
	_camera.name = "IsometricCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = clampf(camera_orthographic_size, min_camera_orthographic_size, max_camera_orthographic_size)
	add_child(_camera)

	var initial_offset := Vector3(18.0, 22.0, 18.0)
	_camera_target = Vector3.ZERO
	_camera_distance = initial_offset.length()
	_camera_yaw = atan2(initial_offset.x, initial_offset.z)
	_camera_pitch = asin(initial_offset.y / _camera_distance)
	_apply_camera_transform()
	_camera.current = true

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.8
	sun.rotation_degrees = Vector3(-48.0, 34.0, 0.0)
	add_child(sun)

	var environment := WorldEnvironment.new()
	environment.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.7, 0.78, 0.86)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.62)
	env.ambient_light_energy = 0.9
	environment.environment = env
	add_child(environment)


func _apply_camera_transform() -> void:
	if not is_instance_valid(_camera):
		return

	var horizontal_distance := cos(_camera_pitch) * _camera_distance
	var offset := Vector3(
		sin(_camera_yaw) * horizontal_distance,
		sin(_camera_pitch) * _camera_distance,
		cos(_camera_yaw) * horizontal_distance
	)
	_camera.position = _camera_target + offset
	_camera.look_at(_camera_target, Vector3.UP)


func _build_debug_overlay() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "Overlay"
	add_child(canvas)

	_debug_label = Label.new()
	_debug_label.position = Vector2(16.0, 16.0)
	_debug_label.add_theme_font_size_override("font_size", 16)
	canvas.add_child(_debug_label)

	_build_personality_panel(canvas)


func _build_personality_panel(canvas: CanvasLayer) -> void:
	var panel := PanelContainer.new()
	panel.name = "PersonalityPanel"
	canvas.add_child(panel)
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 16.0
	panel.offset_top = -184.0
	panel.offset_right = 376.0
	panel.offset_bottom = -16.0

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Personality Mix"
	title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(title)

	_aggressive_slider = HSlider.new()
	_aggressive_value_label = Label.new()
	_build_personality_row(vbox, "Aggressive", _aggressive_slider, _aggressive_value_label, aggressive_percent, 0)

	_neutral_slider = HSlider.new()
	_neutral_value_label = Label.new()
	_build_personality_row(vbox, "Neutral", _neutral_slider, _neutral_value_label, neutral_percent, 1)

	_passive_slider = HSlider.new()
	_passive_value_label = Label.new()
	_build_personality_row(vbox, "Passive", _passive_slider, _passive_value_label, passive_percent, 2)


func _build_personality_row(parent: Control, label_text: String, slider: HSlider, value_label: Label, initial: int, slider_index: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var name_label := Label.new()
	name_label.text = label_text
	name_label.custom_minimum_size = Vector2(80, 0)
	row.add_child(name_label)

	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = float(initial)
	slider.custom_minimum_size = Vector2(180, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	value_label.text = "%d%%" % initial
	value_label.custom_minimum_size = Vector2(40, 0)
	row.add_child(value_label)

	slider.value_changed.connect(_on_personality_slider_changed.bind(slider_index))
	slider.drag_ended.connect(_on_personality_drag_ended)


func _on_personality_slider_changed(value: float, slider_index: int) -> void:
	if _suppress_slider_callbacks:
		return
	_rebalance_sliders(slider_index, int(round(value)))


func _on_personality_drag_ended(_value_changed: bool) -> void:
	reset_simulation()


func _rebalance_sliders(changed_index: int, new_value: int) -> void:
	new_value = clampi(new_value, 0, 100)
	var values := [aggressive_percent, neutral_percent, passive_percent]
	values[changed_index] = new_value

	var remainder := 100 - new_value
	var other_a := (changed_index + 1) % 3
	var other_b := (changed_index + 2) % 3
	var other_sum: int = values[other_a] + values[other_b]

	if other_sum > 0:
		var scaled_a := int(round(float(values[other_a]) * float(remainder) / float(other_sum)))
		scaled_a = clampi(scaled_a, 0, remainder)
		values[other_a] = scaled_a
		values[other_b] = remainder - scaled_a
	else:
		var half_a := remainder / 2
		values[other_a] = half_a
		values[other_b] = remainder - half_a

	aggressive_percent = values[0]
	neutral_percent = values[1]
	passive_percent = values[2]

	_suppress_slider_callbacks = true
	_aggressive_slider.value = float(aggressive_percent)
	_neutral_slider.value = float(neutral_percent)
	_passive_slider.value = float(passive_percent)
	_aggressive_value_label.text = "%d%%" % aggressive_percent
	_neutral_value_label.text = "%d%%" % neutral_percent
	_passive_value_label.text = "%d%%" % passive_percent
	_suppress_slider_callbacks = false


func _make_personality_bag(count: int) -> PackedInt32Array:
	var bag := PackedInt32Array()
	bag.resize(count)
	if count <= 0:
		return bag

	var total := aggressive_percent + neutral_percent + passive_percent
	if total <= 0:
		for i in range(count):
			bag[i] = PERSONALITY_NEUTRAL
		return bag

	var raw := [
		float(aggressive_percent) / float(total) * float(count),
		float(neutral_percent) / float(total) * float(count),
		float(passive_percent) / float(total) * float(count),
	]
	var floors := [int(floor(raw[0])), int(floor(raw[1])), int(floor(raw[2]))]
	var remainders := [raw[0] - floor(raw[0]), raw[1] - floor(raw[1]), raw[2] - floor(raw[2])]
	var deficit: int = count - (floors[0] + floors[1] + floors[2])
	while deficit > 0:
		var best := 0
		for i in range(1, 3):
			if remainders[i] > remainders[best]:
				best = i
		floors[best] += 1
		remainders[best] = -1.0
		deficit -= 1

	var idx := 0
	var nonzero_personalities := 0
	for personality in range(3):
		var f: int = floors[personality]
		if f > 0:
			nonzero_personalities += 1
		for _j in range(f):
			bag[idx] = personality
			idx += 1

	# Only shuffle when the bag actually has more than one personality.
	# A uniform bag is unchanged by shuffling but still consumes RNG state,
	# which would shift downstream randf calls in _spawn_crowd and break
	# behavior parity at the default 0/100/0 mix.
	if nonzero_personalities > 1:
		for i in range(count - 1, 0, -1):
			var j := _rng.randi_range(0, i)
			var tmp: int = bag[i]
			bag[i] = bag[j]
			bag[j] = tmp

	return bag


func _parse_batch_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var arg: String = args[i]
		match arg:
			"--batch":
				_batch_mode = true
				i += 1
			"--seeds":
				_batch_seed_count = int(args[i + 1])
				i += 2
			"--timeout":
				_batch_timeout_seconds = float(args[i + 1])
				i += 2
			"--out":
				_batch_output_path = args[i + 1]
				i += 2
			"--agents":
				agent_count = int(args[i + 1])
				i += 2
			_:
				i += 1


func _start_batch() -> void:
	# Only skip the pre-walk countdown; preserve max_start_delay so agents
	# stagger their entry as in the interactive sim. Zeroing it caused
	# every run to jam (all 100 agents enter the crosswalk on the same tick).
	auto_start_seconds = 0.0
	if _batch_configs.is_empty():
		_batch_configs = _default_batch_matrix()
	_batch_index = 0
	_batch_results.clear()
	_batch_started_msec = Time.get_ticks_msec()
	print("[batch] starting %d runs (timeout=%.1fs, agents=%d) -> %s" % [
		_batch_configs.size(), _batch_timeout_seconds, agent_count, _batch_output_path
	])
	_start_next_batch_run()


func _default_batch_matrix() -> Array:
	var slider_configs := [
		[0, 100, 0],
		[100, 0, 0],
		[0, 0, 100],
		[50, 50, 0],
		[50, 0, 50],
		[0, 50, 50],
		[33, 34, 33],
	]
	var matrix: Array = []
	for cfg in slider_configs:
		for s in range(_batch_seed_count):
			matrix.append({
				"aggressive": cfg[0],
				"neutral": cfg[1],
				"passive": cfg[2],
				"seed": 1 + s,
				"agents": agent_count,
			})
	return matrix


func _start_next_batch_run() -> void:
	if _batch_index >= _batch_configs.size():
		_finish_batch()
		return
	var cfg: Dictionary = _batch_configs[_batch_index]
	aggressive_percent = int(cfg["aggressive"])
	neutral_percent = int(cfg["neutral"])
	passive_percent = int(cfg["passive"])
	simulation_seed = int(cfg["seed"])
	agent_count = int(cfg["agents"])
	_batch_run_started_msec = Time.get_ticks_msec()
	reset_simulation()


func _record_batch_result(timed_out: bool) -> void:
	var cfg: Dictionary = _batch_configs[_batch_index]
	var wall_msec := Time.get_ticks_msec() - _batch_run_started_msec
	_batch_results.append({
		"aggressive": cfg["aggressive"],
		"neutral": cfg["neutral"],
		"passive": cfg["passive"],
		"seed": cfg["seed"],
		"agents": cfg["agents"],
		"cross_time": _walk_final_seconds,
		"arrived": _arrived_count,
		"timed_out": timed_out,
		"wall_msec": wall_msec,
	})
	_batch_index += 1
	if _batch_index % 10 == 0 or _batch_index == _batch_configs.size():
		var total_wall := (Time.get_ticks_msec() - _batch_started_msec) / 1000.0
		print("[batch] %d / %d runs done (%.1fs wall)" % [_batch_index, _batch_configs.size(), total_wall])
	_start_next_batch_run()


func _finish_batch() -> void:
	_write_batch_csv()
	var total_wall := (Time.get_ticks_msec() - _batch_started_msec) / 1000.0
	print("[batch] wrote %d results to %s in %.1fs" % [_batch_results.size(), _batch_output_path, total_wall])
	get_tree().quit()


func _write_batch_csv() -> void:
	var f := FileAccess.open(_batch_output_path, FileAccess.WRITE)
	if f == null:
		push_error("Could not open %s for writing (error=%d)" % [_batch_output_path, FileAccess.get_open_error()])
		return
	f.store_line("aggressive,neutral,passive,seed,agents,cross_time,arrived,timed_out,wall_msec")
	for r in _batch_results:
		f.store_line("%d,%d,%d,%d,%d,%.4f,%d,%s,%d" % [
			r["aggressive"], r["neutral"], r["passive"], r["seed"], r["agents"],
			r["cross_time"], r["arrived"], "true" if r["timed_out"] else "false", r["wall_msec"]
		])
	f.close()


func _rebuild_agent_multimeshes() -> void:
	if is_instance_valid(_crowd_a_mesh):
		_crowd_a_mesh.queue_free()
	if is_instance_valid(_crowd_b_mesh):
		_crowd_b_mesh.queue_free()

	_crowd_a_mesh = _make_agent_multimesh("CrowdA", _crowd_a_count)
	_crowd_b_mesh = _make_agent_multimesh("CrowdB", _crowd_b_count)
	add_child(_crowd_a_mesh)
	add_child(_crowd_b_mesh)
	_apply_instance_colors()


func _make_agent_multimesh(node_name: String, count: int) -> MultiMeshInstance3D:
	var capsule := CapsuleMesh.new()
	capsule.radius = body_radius
	capsule.height = capsule_height
	capsule.radial_segments = 10
	capsule.rings = 4

	var material := _make_material(Color.WHITE)
	material.roughness = 0.6
	material.vertex_color_use_as_albedo = true

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = capsule
	multimesh.instance_count = count

	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.material_override = material
	instance.multimesh = multimesh
	return instance


func _apply_instance_colors() -> void:
	if not is_instance_valid(_crowd_a_mesh) or not is_instance_valid(_crowd_b_mesh):
		return

	for i in range(agent_count):
		var personality := personalities[i]
		var tint := float(PERSONALITY_PROFILES[personality]["tint"])
		var base_color: Color = _crowd_a_base_color if i < _crowd_a_count else _crowd_b_base_color
		var target := Color.WHITE if tint > 0.0 else Color.BLACK
		var blended := base_color.lerp(target, absf(tint))
		if i < _crowd_a_count:
			_crowd_a_mesh.multimesh.set_instance_color(i, blended)
		else:
			_crowd_b_mesh.multimesh.set_instance_color(i - _crowd_a_count, blended)


func _update_agent_visuals() -> void:
	if not is_instance_valid(_crowd_a_mesh) or not is_instance_valid(_crowd_b_mesh):
		return

	var transform := Transform3D.IDENTITY
	for i in range(agent_count):
		transform.origin = Vector3(positions[i].x, capsule_height * 0.5, positions[i].y)

		if i < _crowd_a_count:
			_crowd_a_mesh.multimesh.set_instance_transform(i, transform)
		else:
			_crowd_b_mesh.multimesh.set_instance_transform(i - _crowd_a_count, transform)


func _update_debug_label() -> void:
	if not is_instance_valid(_debug_label):
		return

	var state_text := "Waiting"
	if _state == STATE_WALKING:
		state_text = "Walking"
	elif _state == STATE_DONE:
		state_text = "Done"

	var cross_text := "—"
	if _state == STATE_WALKING:
		cross_text = "%.2f s" % _walk_elapsed
	elif _state == STATE_DONE:
		cross_text = "%.2f s (final)" % _walk_final_seconds

	_debug_label.text = "State: %s\nAgents: %d\nCrossed: %d\nCross time: %s\nFPS: %d\nSim: %.2f ms" % [
		state_text,
		agent_count,
		_arrived_count,
		cross_text,
		Engine.get_frames_per_second(),
		_last_simulation_ms
	]


func _set_walk_signal(walk_enabled: bool) -> void:
	if not is_instance_valid(_stop_material) or not is_instance_valid(_walk_material):
		return

	_stop_material.albedo_color = Color(0.18, 0.02, 0.015) if walk_enabled else Color(0.95, 0.04, 0.025)
	_stop_material.emission_enabled = not walk_enabled
	_stop_material.emission = Color(0.95, 0.04, 0.025)
	_walk_material.albedo_color = Color(0.02, 0.18, 0.045) if not walk_enabled else Color(0.02, 0.95, 0.18)
	_walk_material.emission_enabled = walk_enabled
	_walk_material.emission = Color(0.02, 0.95, 0.18)


func _add_box(node_name: String, size: Vector3, position: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size

	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	add_child(instance)
	return instance


func _add_signal_pole(position: Vector3) -> void:
	var pole_material := _make_material(Color(0.06, 0.06, 0.055))

	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.06
	pole_mesh.bottom_radius = 0.06
	pole_mesh.height = 2.4
	pole_mesh.radial_segments = 8

	var pole := MeshInstance3D.new()
	pole.name = "SignalPole"
	pole.mesh = pole_mesh
	pole.material_override = pole_material
	pole.position = position + Vector3(0.0, 1.2, 0.0)
	add_child(pole)

	_add_signal_lamp(position + Vector3(0.0, 2.25, 0.0), _stop_material)
	_add_signal_lamp(position + Vector3(0.0, 1.78, 0.0), _walk_material)


func _add_signal_lamp(position: Vector3, material: StandardMaterial3D) -> void:
	var lamp_mesh := SphereMesh.new()
	lamp_mesh.radius = 0.18
	lamp_mesh.height = 0.36
	lamp_mesh.radial_segments = 12
	lamp_mesh.rings = 6

	var lamp := MeshInstance3D.new()
	lamp.name = "SignalLamp"
	lamp.mesh = lamp_mesh
	lamp.material_override = material
	lamp.position = position
	add_child(lamp)


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	return material


func _make_emissive_material(color: Color, enabled: bool) -> StandardMaterial3D:
	var material := _make_material(color)
	material.emission_enabled = enabled
	material.emission = color
	material.emission_energy_multiplier = 1.4
	return material


func _walkable_half_width() -> float:
	return crosswalk_width * 0.5


func _destination_x_for_start(start_x: float, destination_half_width: float) -> float:
	var destination_x := start_x + _rng.randf_range(-destination_lateral_jitter, destination_lateral_jitter)
	if _rng.randf() < offside_destination_chance:
		var side := 1.0 if _rng.randf() >= 0.5 else -1.0
		destination_x += side * _rng.randf_range(destination_lateral_jitter, offside_destination_extra)

	return clampf(
		destination_x,
		-minf(destination_half_width, _walkable_half_width() - body_radius),
		minf(destination_half_width, _walkable_half_width() - body_radius)
	)


func _safe_normalized(value: Vector2, fallback: Vector2) -> Vector2:
	var epsilon_sq := EPSILON * EPSILON
	if value.length_squared() > epsilon_sq:
		return value.normalized()
	if fallback.length_squared() > epsilon_sq:
		return fallback.normalized()

	return Vector2.RIGHT


func _agent_count_step() -> int:
	return 10 if agent_count < 200 else 100
