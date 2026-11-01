extends Node2D

const DIRECTIONS: Array[String] = ["Right", "DownRight", "Down", "DownLeft", "Left", "UpLeft", "Up", "UpRight"]

var speed = 300.0
var direction = Vector2.ZERO
var facing := "Right"

var screen_size = Vector2()
var window_size = Vector2.ZERO

var is_dragging = false
var drag_offset = Vector2()
var is_asleep = false
var hover_rect = Rect2()
var last_mouse = Vector2.ZERO
var still_time = 0.0

var cursor_thread: Thread
var cursor_mutex := Mutex.new()
var polled_mouse := Vector2.ZERO
var polled_valid := false
var poll_running := true

@onready var animated_sprite = $AnimatedSprite2D
@onready var area = $Area2D

func _ready():
	screen_size = Vector2(DisplayServer.screen_get_size())
	window_size = Vector2(DisplayServer.window_get_size())
	area.input_event.connect(_on_area_input)
	animated_sprite.play("Idle_Right")

	var frame_size = Vector2(32, 40)
	var body_local = Rect2(4, 3, 24, 24)
	var frame_origin = (window_size - frame_size * animated_sprite.scale) / 2
	hover_rect = Rect2(frame_origin + body_local.position * animated_sprite.scale, body_local.size * animated_sprite.scale)

	cursor_thread = Thread.new()
	cursor_thread.start(_poll_cursor)

func _exit_tree():
	poll_running = false
	if cursor_thread and cursor_thread.is_started():
		cursor_thread.wait_to_finish()

func _poll_cursor():
	while poll_running:
		var out: Array = []
		var code := OS.execute("hyprctl", ["cursorpos"], out, false)
		if code == 0 and out.size() > 0:
			var parts := String(out[0]).strip_edges().split(",")
			if parts.size() == 2:
				var pos := Vector2(parts[0].to_float(), parts[1].to_float())
				cursor_mutex.lock()
				polled_mouse = pos
				polled_valid = true
				cursor_mutex.unlock()
		OS.delay_msec(50)

func _mouse_position() -> Vector2:
	var fallback := Vector2(DisplayServer.mouse_get_position())
	cursor_mutex.lock()
	var valid := polled_valid
	var pos := polled_mouse
	cursor_mutex.unlock()
	return pos if valid else fallback

func _physics_process(delta: float) -> void:
	if is_dragging:
		var mouse_pos = Vector2(DisplayServer.mouse_get_position())
		DisplayServer.window_set_position(Vector2i(mouse_pos - drag_offset))
		return

	var mouse = _mouse_position()
	var window_position = Vector2(DisplayServer.window_get_position())
	var hovering = hover_rect.has_point(mouse - window_position)
	var pet_center = window_position + hover_rect.get_center()
	var to_mouse = mouse - pet_center
	var distance = to_mouse.length()
	var cursor_still = mouse.distance_squared_to(last_mouse) <= 1.0
	var at_cursor = distance <= 6.0

	if hovering and at_cursor and cursor_still:
		still_time += delta
	else:
		still_time = 0.0
	last_mouse = mouse

	var should_sleep = hovering and at_cursor and cursor_still and still_time > 0.25

	if should_sleep != is_asleep:
		is_asleep = should_sleep
		if is_asleep:
			speed = 0.0
			animated_sprite.play("Sleep")
		else:
			animated_sprite.play("Walk_" + facing)

	if is_asleep:
		return

	if hovering and at_cursor and cursor_still:
		speed = 0.0
		_play("Idle_" + facing)
		return

	direction = to_mouse.normalized()
	if distance > 4.0:
		speed = 300.0
		facing = _direction_name(direction)
		_play("Walk_" + facing)
	else:
		speed = 0.0
		_play("Idle_" + facing)

	window_position += direction * speed * delta
	window_position.x = clamp(window_position.x, 0, screen_size.x - window_size.x)
	window_position.y = clamp(window_position.y, 0, screen_size.y - window_size.y)
	DisplayServer.window_set_position(Vector2i(window_position))

func _play(anim: String) -> void:
	if animated_sprite.animation != anim:
		animated_sprite.play(anim)

func _direction_name(dir: Vector2) -> String:
	if dir == Vector2.ZERO:
		return facing
	var idx := int(round(dir.angle() / (PI / 4.0)))
	if idx < 0:
		idx += 8
	return DIRECTIONS[idx]

func _on_area_input(_viewport, event, _shape_idx):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			is_dragging = true
			var mouse_pos = Vector2(DisplayServer.mouse_get_position())
			var win_pos = Vector2(DisplayServer.window_get_position())
			drag_offset = mouse_pos - win_pos
		else:
			is_dragging = false
