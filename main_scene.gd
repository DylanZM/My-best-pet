extends Node2D

const DIRECTIONS: Array[String] = ["Right", "DownRight", "Down", "DownLeft", "Left", "UpLeft", "Up", "UpRight"]
const CRY_PATH := "res://assets/litten/sounds/litten_cry.ogg"
const CLICK_MENU_DELAY := 0.45

var speed = 300.0
var direction = Vector2.ZERO
var facing := "Left"

var screen_size = Vector2()
var window_size = Vector2.ZERO

var is_dragging = false
var drag_offset = Vector2()
var drag_start_mouse = Vector2.ZERO
var is_asleep := false
var is_waking := false
var is_falling_asleep := false
var is_posing := false
var is_staying := false
var follow_cursor := true
var is_menu_open := false

var wander_direction := Vector2.ZERO
var wander_timer := 0.0

var menu: PopupMenu
var click_timer: Timer
var pending_menu := false
var pending_menu_at := Vector2.ZERO
var suppress_menu_release := false
var cry_player: AudioStreamPlayer

var cursor_thread: Thread
var cursor_mutex := Mutex.new()
var polled_mouse := Vector2.ZERO
var polled_valid := false
var poll_running := true

@onready var animated_sprite = $AnimatedSprite2D
@onready var area = $Area2D

func _ready():
	randomize()
	screen_size = Vector2(DisplayServer.screen_get_size())
	window_size = Vector2(DisplayServer.window_get_size())
	area.input_event.connect(_on_area_input)
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.play("Idle_Left")

	menu = PopupMenu.new()
	menu.add_item("Pose", 1)
	menu.add_check_item("Follow Cursor", 2)
	menu.add_check_item("Stay Still", 3)
	menu.add_item("Sleep", 4)
	menu.add_item("Wake", 5)
	menu.id_pressed.connect(_on_menu_id_pressed)
	menu.popup_hide.connect(_on_menu_closed)
	add_child(menu)
	_sync_menu_checks()

	click_timer = Timer.new()
	click_timer.one_shot = true
	click_timer.wait_time = CLICK_MENU_DELAY
	click_timer.timeout.connect(_on_click_timeout)
	add_child(click_timer)

	if ResourceLoader.exists(CRY_PATH):
		var stream = load(CRY_PATH)
		if stream:
			cry_player = AudioStreamPlayer.new()
			cry_player.stream = stream
			add_child(cry_player)

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

	if is_asleep or is_waking or is_falling_asleep or is_posing:
		return

	if is_staying:
		speed = 0.0
		_play("Idle_" + facing)
		return

	if follow_cursor:
		_follow_cursor(delta)
	else:
		_wander(delta)

func _follow_cursor(delta: float) -> void:
	var mouse = _mouse_position()
	var window_position = Vector2(DisplayServer.window_get_position())
	var pet_center = window_position + window_size / 2.0
	var to_mouse = mouse - pet_center
	var distance = to_mouse.length()
	direction = to_mouse.normalized()

	if distance > 4.0:
		speed = 300.0
		facing = _direction_name(direction)
		_play("Walk_" + facing)
	else:
		speed = 0.0
		_play("Idle_" + facing)

	window_position += direction * speed * delta
	window_position.x = clamp(window_position.x, 0.0, max(0.0, screen_size.x - window_size.x))
	window_position.y = clamp(window_position.y, 0.0, max(0.0, screen_size.y - window_size.y))
	DisplayServer.window_set_position(Vector2i(window_position))

func _wander(delta: float) -> void:
	var window_position = Vector2(DisplayServer.window_get_position())
	wander_timer -= delta
	if wander_timer <= 0.0 or wander_direction == Vector2.ZERO:
		wander_direction = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		if wander_direction.length_squared() < 0.01:
			wander_direction = Vector2.LEFT
		wander_direction = wander_direction.normalized()
		wander_timer = randf_range(1.5, 3.5)

	speed = 300.0
	facing = _direction_name(wander_direction)
	_play("Walk_" + facing)

	var max_x = max(0.0, screen_size.x - window_size.x)
	var max_y = max(0.0, screen_size.y - window_size.y)
	var next = window_position + wander_direction * speed * delta
	if next.x < 0.0 or next.x > max_x:
		wander_direction.x *= -1.0
	if next.y < 0.0 or next.y > max_y:
		wander_direction.y *= -1.0

	window_position += wander_direction * speed * delta
	window_position.x = clamp(window_position.x, 0.0, max_x)
	window_position.y = clamp(window_position.y, 0.0, max_y)
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
	_sync_menu_checks()
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

func _on_click_timeout() -> void:
	if pending_menu:
		pending_menu = false
		_open_menu(pending_menu_at)

func _schedule_menu(at: Vector2) -> void:
	pending_menu = true
	pending_menu_at = at
	click_timer.start()

func _on_menu_id_pressed(id: int) -> void:
	match id:
		1:
			is_asleep = false
			is_waking = false
			is_falling_asleep = false
			is_posing = true
			facing = "Down"
			speed = 0.0
			_play("Pose_Down")
		2:
			follow_cursor = not follow_cursor
			if follow_cursor:
				is_staying = false
			else:
				wander_timer = 0.0
			_sync_menu_checks()
		3:
			is_staying = not is_staying
			if is_staying:
				follow_cursor = false
			else:
				wander_timer = 0.0
			_sync_menu_checks()
		4:
			if not is_asleep and not is_falling_asleep:
				is_posing = false
				is_waking = false
				is_falling_asleep = true
				speed = 0.0
				facing = "Left"
				_play("Sleep_Start_Left")
		5:
			if is_asleep or is_falling_asleep:
				is_asleep = false
				is_falling_asleep = false
				is_posing = false
				is_waking = true
				speed = 0.0
				_play("Wake_Left")

func _sync_menu_checks() -> void:
	var follow_idx := menu.get_item_index(2)
	var stay_idx := menu.get_item_index(3)
	if follow_idx >= 0:
		menu.set_item_checked(follow_idx, follow_cursor)
	if stay_idx >= 0:
		menu.set_item_checked(stay_idx, is_staying)

func _play_cry() -> void:
	if cry_player and cry_player.stream:
		cry_player.play()

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
			pending_menu = false
			click_timer.stop()
			_open_menu(event.position)
			return
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			if event.double_click:
				pending_menu = false
				click_timer.stop()
				suppress_menu_release = true
				is_dragging = false
				_play_cry()
				return
			is_dragging = true
			drag_start_mouse = Vector2(DisplayServer.mouse_get_position())
			var mouse_pos = Vector2(DisplayServer.mouse_get_position())
			var win_pos = Vector2(DisplayServer.window_get_position())
			drag_offset = mouse_pos - win_pos
		else:
			is_dragging = false
			if suppress_menu_release:
				suppress_menu_release = false
				return
			if Vector2(DisplayServer.mouse_get_position()).distance_to(drag_start_mouse) < 4.0:
				_schedule_menu(event.position)
