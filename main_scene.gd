extends Node2D

const DIRECTIONS: Array[String] = ["Right", "DownRight", "Down", "DownLeft", "Left", "UpLeft", "Up", "UpRight"]

var speed = 300.0
var direction = Vector2.ZERO
var facing := "Left"

var screen_size = Vector2()
var window_size = Vector2.ZERO

var is_dragging = false
var drag_offset = Vector2()
var drag_start_mouse = Vector2.ZERO
var is_asleep := true
var is_waking := false
var is_falling_asleep := false
var is_sitting := false
var is_posing := false
var manual_sleep := false
var is_menu_open := false
var mouse_initialized := false
var startup_time := 0.0
var hover_rect = Rect2()
var last_mouse = Vector2.ZERO
var still_time = 0.0

var menu: PopupMenu

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
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.play("Sleep")

	menu = PopupMenu.new()
	menu.add_item("Sentarse", 1)
	menu.add_item("Pose", 2)
	menu.add_item("Levantarse", 3)
	menu.add_item("Dormir", 4)
	menu.add_item("Despertar", 5)
	menu.id_pressed.connect(_on_menu_id_pressed)
	menu.popup_hide.connect(_on_menu_closed)
	add_child(menu)

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

	if is_menu_open:
		return

	var mouse = _mouse_position()
	var window_position = Vector2(DisplayServer.window_get_position())
	var hovering = hover_rect.has_point(mouse - window_position)
	var pet_center = window_position + hover_rect.get_center()
	var to_mouse = mouse - pet_center
	var distance = to_mouse.length()
	var cursor_still = mouse.distance_squared_to(last_mouse) <= 1.0
	var at_cursor = distance <= 6.0

	if not mouse_initialized:
		startup_time += delta
		last_mouse = mouse
		if startup_time > 0.5:
			mouse_initialized = true
		return

	if is_asleep:
		last_mouse = mouse
		if not cursor_still and not manual_sleep:
			is_asleep = false
			is_waking = true
			speed = 0.0
			still_time = 0.0
			is_sitting = false
			is_posing = false
			_play("Wake_Left")
		return

	if is_waking or is_falling_asleep:
		last_mouse = mouse
		return

	if is_posing:
		last_mouse = mouse
		return

	if is_sitting:
		speed = 0.0
		_play("Sit")
		last_mouse = mouse
		return

	if hovering and at_cursor and cursor_still:
		still_time += delta
	else:
		still_time = 0.0
	last_mouse = mouse

	if hovering and at_cursor and cursor_still and still_time > 0.25:
		manual_sleep = false
		is_falling_asleep = true
		speed = 0.0
		facing = "Left"
		_play("Sleep_Start_Left")
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

func _on_animation_finished() -> void:
	if is_posing:
		is_posing = false
		_play("Idle_" + facing)
		return
	if is_waking:
		is_waking = false
		_play("Idle_" + facing)
	elif is_falling_asleep:
		is_falling_asleep = false
		is_asleep = true
		_play("Sleep")

func _play(anim: String) -> void:
	if animated_sprite.animation != anim:
		animated_sprite.play(anim)

func _open_menu(at: Vector2) -> void:
	menu.reset_size()
	var msize := Vector2i(menu.get_contents_minimum_size())
	if msize.x <= 0:
		msize.x = 140
	if msize.y <= 0:
		msize.y = 120
	var pos := Vector2i(at)
	pos.x = clampi(pos.x, 0, max(0, int(window_size.x) - msize.x))
	pos.y = clampi(pos.y, 0, max(0, int(window_size.y) - msize.y))
	menu.position = pos
	is_menu_open = true
	menu.popup()

func _on_menu_closed() -> void:
	is_menu_open = false

func _on_menu_id_pressed(id: int) -> void:
	match id:
		1:
			manual_sleep = false
			is_asleep = false
			is_waking = false
			is_falling_asleep = false
			is_posing = false
			is_sitting = true
			speed = 0.0
			still_time = 0.0
			_play("Sit")
		2:
			manual_sleep = false
			is_asleep = false
			is_waking = false
			is_falling_asleep = false
			is_sitting = false
			is_posing = true
			facing = "Down"
			speed = 0.0
			still_time = 0.0
			_play("Pose_Down")
		3:
			manual_sleep = false
			is_sitting = false
			is_posing = false
			is_falling_asleep = false
			speed = 0.0
			still_time = 0.0
			if is_asleep:
				is_asleep = false
				is_waking = true
				_play("Wake_Left")
			else:
				is_waking = false
				_play("Idle_" + facing)
		4:
			manual_sleep = true
			is_sitting = false
			is_posing = false
			if not is_asleep and not is_falling_asleep:
				is_waking = false
				is_falling_asleep = true
				speed = 0.0
				facing = "Left"
				_play("Sleep_Start_Left")
		5:
			manual_sleep = false
			if is_asleep or is_falling_asleep:
				is_asleep = false
				is_falling_asleep = false
				is_sitting = false
				is_posing = false
				is_waking = true
				speed = 0.0
				still_time = -1.5
				_play("Wake_Left")

func _direction_name(dir: Vector2) -> String:
	if dir == Vector2.ZERO:
		return facing
	var idx := int(round(dir.angle() / (PI / 4.0)))
	if idx < 0:
		idx += 8
	return DIRECTIONS[idx]

func _on_area_input(_viewport, event, _shape_idx):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_open_menu(event.position)
			return
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			is_dragging = true
			drag_start_mouse = Vector2(DisplayServer.mouse_get_position())
			var mouse_pos = Vector2(DisplayServer.mouse_get_position())
			var win_pos = Vector2(DisplayServer.window_get_position())
			drag_offset = mouse_pos - win_pos
		else:
			is_dragging = false
			if Vector2(DisplayServer.mouse_get_position()).distance_to(drag_start_mouse) < 4.0:
				_open_menu(event.position)
