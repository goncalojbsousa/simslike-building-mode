extends Node3D

# --- Nodes ---
@onready var pitch_arm: Node3D = $PitchArm
@onready var camera: Camera3D = $PitchArm/Camera3D

# --- Orbit settings ---
@export var orbit_speed: float = 0.4         # degrees per pixel dragged
@export var min_pitch: float = 15.0          # don't go below horizon
@export var max_pitch: float = 80.0          # don't go fully overhead

# --- Zoom settings ---
@export var zoom_speed: float = 1.5
@export var min_zoom: float = 5.0
@export var max_zoom: float = 50.0

# --- Pan settings ---
@export var pan_speed: float = 0.01

# --- State ---
var _is_orbiting: bool = false
var _is_panning: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _current_zoom: float = 20.0
var _pitch: float = 45.0
var _yaw: float = 0.0

func _ready() -> void:
	_apply_pitch()
	_apply_zoom()

func _unhandled_input(event: InputEvent) -> void:
	# --- Orbit: middle mouse button drag ---
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_is_orbiting = mb.pressed
			_last_mouse_pos = mb.position

		# --- Zoom: scroll wheel ---
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_current_zoom = clampf(_current_zoom - zoom_speed, min_zoom, max_zoom)
			_apply_zoom()
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_current_zoom = clampf(_current_zoom + zoom_speed, min_zoom, max_zoom)
			_apply_zoom()

		# --- Pan: right mouse button drag ---
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_is_panning = mb.pressed
			_last_mouse_pos = mb.position

	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion

		if _is_orbiting:
			_yaw   -= mm.relative.x * orbit_speed
			_pitch  = clampf(_pitch + mm.relative.y * orbit_speed, min_pitch, max_pitch)
			rotation_degrees.y = _yaw
			_apply_pitch()

		if _is_panning:
			# Pan in the cameras local XZ plane
			var right := camera.global_transform.basis.x
			var forward := Vector3(
				camera.global_transform.basis.z.x,
				0.0,
				camera.global_transform.basis.z.z
			).normalized()
			var delta := mm.relative
			global_position -= right   * delta.x * pan_speed * _current_zoom
			global_position += forward * delta.y * pan_speed * _current_zoom

func _apply_pitch() -> void:
	pitch_arm.rotation_degrees.x = -_pitch

func _apply_zoom() -> void:
	camera.position.z = _current_zoom
