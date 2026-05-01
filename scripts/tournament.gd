extends Node3D
class_name CrowdTournament

# Lays out 9 CrowdSimulation tiles in a 3x3 grid, each with a fixed
# personality mix sweeping aggressive -> neutral -> passive. A single
# top-down ortho camera covers the whole grid; per-tile Label3D shows
# the config and live cross time.

const TILE_COLUMNS := 5

# 15-step path along aggressive -> neutral -> passive. Reading order
# (left-to-right, top-to-bottom) walks the spectrum smoothly. Center
# slot (row 1 col 2, index 7) is pure neutral; left half is the
# aggressive->neutral leg, right half is the neutral->passive leg.
const TILE_CONFIGS := [
	{ "label": "100/0/0", "agg": 100, "neu": 0,   "pas": 0 },
	{ "label": "86/14/0", "agg": 86,  "neu": 14,  "pas": 0 },
	{ "label": "71/29/0", "agg": 71,  "neu": 29,  "pas": 0 },
	{ "label": "57/43/0", "agg": 57,  "neu": 43,  "pas": 0 },
	{ "label": "43/57/0", "agg": 43,  "neu": 57,  "pas": 0 },
	{ "label": "29/71/0", "agg": 29,  "neu": 71,  "pas": 0 },
	{ "label": "14/86/0", "agg": 14,  "neu": 86,  "pas": 0 },
	{ "label": "0/100/0", "agg": 0,   "neu": 100, "pas": 0 },
	{ "label": "0/86/14", "agg": 0,   "neu": 86,  "pas": 14 },
	{ "label": "0/71/29", "agg": 0,   "neu": 71,  "pas": 29 },
	{ "label": "0/57/43", "agg": 0,   "neu": 57,  "pas": 43 },
	{ "label": "0/43/57", "agg": 0,   "neu": 43,  "pas": 57 },
	{ "label": "0/29/71", "agg": 0,   "neu": 29,  "pas": 71 },
	{ "label": "0/14/86", "agg": 0,   "neu": 14,  "pas": 86 },
	{ "label": "0/0/100", "agg": 0,   "neu": 0,   "pas": 100 },
]

@export var tile_agent_count: int = 70
@export var tile_simulation_seed: int = 42
@export_range(25.0, 120.0, 0.5) var tile_spacing_x: float = 38.0
@export_range(30.0, 100.0, 0.5) var tile_spacing_z: float = 38.0
@export_range(20.0, 240.0, 1.0) var camera_orthographic_size: float = 120.0
@export_range(20.0, 90.0, 1.0) var camera_pitch_degrees: float = 65.0
@export_range(60.0, 400.0, 1.0) var camera_distance: float = 160.0

var _tiles: Array[CrowdSimulation] = []
var _camera: Camera3D
var _completion_order: Array[int] = []
var _leaderboard_label: Label


func _ready() -> void:
	_build_environment_and_camera()
	_build_leaderboard()
	_spawn_grid()


func _build_environment_and_camera() -> void:
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

	_camera = Camera3D.new()
	_camera.name = "GridCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = camera_orthographic_size
	add_child(_camera)
	# Isometric-style framing matching the og single-sim camera, scaled
	# so the whole 3x3 grid fits inside the ortho frustum.
	var pitch := deg_to_rad(camera_pitch_degrees)
	var horizontal := cos(pitch) * camera_distance
	var vertical := sin(pitch) * camera_distance
	_camera.position = Vector3(0.0, vertical, horizontal)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	_camera.current = true


func _build_leaderboard() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "Overlay"
	add_child(canvas)

	var title := Label.new()
	title.position = Vector2(16.0, 16.0)
	title.add_theme_font_size_override("font_size", 18)
	title.text = "Tournament — press R to reset all"
	canvas.add_child(title)

	_leaderboard_label = Label.new()
	_leaderboard_label.position = Vector2(16.0, 44.0)
	_leaderboard_label.add_theme_font_size_override("font_size", 14)
	canvas.add_child(_leaderboard_label)


func _spawn_grid() -> void:
	var num_rows: int = (TILE_CONFIGS.size() + TILE_COLUMNS - 1) / TILE_COLUMNS
	var origin_x := -float(TILE_COLUMNS - 1) * 0.5 * tile_spacing_x
	var origin_z := -float(num_rows - 1) * 0.5 * tile_spacing_z
	for i in range(TILE_CONFIGS.size()):
		var col: int = i % TILE_COLUMNS
		var row: int = i / TILE_COLUMNS
		var cfg: Dictionary = TILE_CONFIGS[i]
		var tile := CrowdSimulation.new()
		tile.name = "Tile%d" % i
		tile.embedded_in_grid = true
		tile.tile_label = cfg["label"]
		tile.aggressive_percent = int(cfg["agg"])
		tile.neutral_percent = int(cfg["neu"])
		tile.passive_percent = int(cfg["pas"])
		tile.simulation_seed = tile_simulation_seed
		tile.agent_count = tile_agent_count
		tile.position = Vector3(
			origin_x + float(col) * tile_spacing_x,
			0.0,
			origin_z + float(row) * tile_spacing_z
		)
		add_child(tile)
		tile.run_completed.connect(_on_tile_completed.bind(i))
		_tiles.append(tile)


func _on_tile_completed(_cross_time: float, _arrived: int, tile_index: int) -> void:
	if tile_index in _completion_order:
		return
	_completion_order.append(tile_index)
	_refresh_leaderboard()


func _refresh_leaderboard() -> void:
	if not is_instance_valid(_leaderboard_label):
		return
	var lines: Array[String] = ["Finishers:"]
	for rank in range(_completion_order.size()):
		var i: int = _completion_order[rank]
		var cfg: Dictionary = TILE_CONFIGS[i]
		lines.append("%d. %s — %.2fs" % [rank + 1, cfg["label"], _tiles[i]._walk_final_seconds])
	_leaderboard_label.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_R:
			_reset_all()
			get_viewport().set_input_as_handled()


func _reset_all() -> void:
	_completion_order.clear()
	_refresh_leaderboard()
	for tile in _tiles:
		tile.reset_simulation()
