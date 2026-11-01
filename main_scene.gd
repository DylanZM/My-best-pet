extends Node2D

const DIRECTIONS: Array[String] = ["Right", "DownRight", "Down", "DownLeft", "Left", "UpLeft", "Up", "UpRight"]
const CRY_PATH := "res://assets/litten/sounds/litten_cry.ogg"
const HEART_TEXTURE := "res://assets/litten/fx/heart.png"
const SAVE_PATH := "user://pet_state.cfg"
const CLICK_MENU_DELAY := 0.45
const BASE_SPRITE_SCALE := 6.5
const MIN_PET_SCALE := 0.65
const MAX_PET_SCALE := 1.15
const HOVER_SCALE := 1.06
const SPEECH_LINES: Array[String] = [
	"¡Miau!",
	"¿Jugamos?",
	"Tengo hambre...",
	"Te quiero",
	"¿Qué haces?",
	"¡Hola!",
]

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

var pet_scale := 1.0
var is_hovered := false
var is_thrown := false
var throw_velocity := Vector2.ZERO
var drag_velocity := Vector2.ZERO
var last_drag_mouse := Vector2.ZERO
var idle_speech_timer := 24.0

var wander_direction := Vector2.ZERO
var wander_timer := 0.0

var menu: PopupMenu
var click_timer: Timer
var speech_panel: PanelContainer
var speech_label: Label
var speech_timer: Timer
var hearts: CPUParticles2D
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
	_load_state()
	animated_sprite.scale = Vector2.ONE * BASE_SPRITE_SCALE * pet_scale
	area.input_event.connect(_on_area_input)
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.play("Idle_Left")

	menu = PopupMenu.new()
	menu.add_item("Pose", 1)
	menu.add_item("Pet", 2)
	menu.add_check_item("Follow Cursor", 3)
	menu.add_check_item("Stay Still", 4)
	menu.add_item("Sleep", 5)
	menu.add_item("Wake", 6)
	menu.add_item("Clock", 7)
	menu.add_item("Quit", 8)
	menu.id_pressed.connect(_on_menu_id_pressed)
	menu.popup_hide.connect(_on_menu_closed)
	add_child(menu)
	_sync_menu_checks()

	click_timer = Timer.new()
	click_timer.one_shot = true
	click_timer.wait_time = CLICK_MENU_DELAY
	click_timer.timeout.connect(_on_click_timeout)
	add_child(click_timer)

	_setup_speech()
	_setup_particles()
	idle_speech_timer = randf_range(18.0, 32.0)

	if ResourceLoader.exists(CRY_PATH):
		var stream = load(CRY_PATH)
		if stream:
			cry_player = AudioStreamPlayer.new()
			cry_player.stream = stream
			add_child(cry_player)

	cursor_thread = Thread.new()
	cursor_thread.start(_poll_cursor)

func _exit_tree():
	_save_state()
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

func _process(delta: float) -> void:
	_update_hover_visual(delta)

func _update_hover_visual(delta: float) -> void:
	is_hovered = false if is_menu_open or is_dragging else _is_mouse_over_pet()
	var target_scale := BASE_SPRITE_SCALE * pet_scale
	if is_hovered:
		target_scale *= HOVER_SCALE
	animated_sprite.scale = animated_sprite.scale.lerp(Vector2.ONE * target_scale, minf(1.0, 12.0 * delta))

func _is_mouse_over_pet() -> bool:
	var center: Vector2 = Vector2(DisplayServer.window_get_position()) + window_size / 2.0
	var half: Vector2 = Vector2(24.0, 40.0) * BASE_SPRITE_SCALE * pet_scale * 0.5
	return Rect2(center - half, half * 2.0).grow(4.0).has_point(_mouse_position())

func _change_pet_scale(amount: float) -> void:
	pet_scale = clampf(pet_scale + amount, MIN_PET_SCALE, MAX_PET_SCALE)

func _load_state() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	var saved_pos = config.get_value("pet", "position", null)
	if saved_pos is Vector2:
		var pos := saved_pos as Vector2
		pos.x = clampf(pos.x, 0.0, maxf(0.0, screen_size.x - window_size.x))
		pos.y = clampf(pos.y, 0.0, maxf(0.0, screen_size.y - window_size.y))
		DisplayServer.window_set_position(Vector2i(pos))
	pet_scale = clampf(float(config.get_value("pet", "scale", 1.0)), MIN_PET_SCALE, MAX_PET_SCALE)
	follow_cursor = bool(config.get_value("pet", "follow_cursor", true))
	is_staying = bool(config.get_value("pet", "stay_still", false))
	if is_staying:
		follow_cursor = false

func _save_state() -> void:
	var config := ConfigFile.new()
	config.set_value("pet", "position", Vector2(DisplayServer.window_get_position()))
	config.set_value("pet", "scale", pet_scale)
	config.set_value("pet", "follow_cursor", follow_cursor)
	config.set_value("pet", "stay_still", is_staying)
	config.save(SAVE_PATH)

func _setup_speech() -> void:
	speech_panel = PanelContainer.new()
	speech_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	speech_panel.z_index = 20
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 1.0, 1.0, 0.94)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.95, 0.45, 0.6)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 9.0
	style.content_margin_top = 5.0
	style.content_margin_right = 9.0
	style.content_margin_bottom = 5.0
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.16)
	style.shadow_size = 3
	style.shadow_offset = Vector2(0.0, 2.0)
	speech_panel.add_theme_stylebox_override("panel", style)
	speech_label = Label.new()
	speech_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	speech_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speech_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	speech_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	speech_label.custom_minimum_size = Vector2(170, 0)
	speech_label.add_theme_color_override("font_color", Color(0.16, 0.12, 0.14))
	speech_label.add_theme_font_size_override("font_size", 15)
	speech_panel.add_child(speech_label)
	add_child(speech_panel)
	speech_panel.hide()
	speech_timer = Timer.new()
	speech_timer.one_shot = true
	speech_timer.timeout.connect(_hide_speech)
	add_child(speech_timer)

func _speak(text: String, duration := 2.5) -> void:
	if speech_panel == null:
		return
	speech_label.text = text
	speech_panel.reset_size()
	speech_panel.position = Vector2((window_size.x - speech_panel.size.x) / 2.0, 4.0)
	speech_panel.show()
	speech_timer.start(duration)

func _hide_speech() -> void:
	if speech_panel:
		speech_panel.hide()

func _setup_particles() -> void:
	if not ResourceLoader.exists(HEART_TEXTURE):
		return
	var tex = load(HEART_TEXTURE)
	if tex == null:
		return
	hearts = CPUParticles2D.new()
	hearts.texture = tex
	hearts.position = Vector2(128, 155)
	hearts.z_index = 10
	hearts.emitting = false
	hearts.one_shot = true
	hearts.amount = 12
	hearts.lifetime = 1.1
	hearts.explosiveness = 0.9
	hearts.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	hearts.emission_sphere_radius = 16.0
	hearts.direction = Vector2(0, -1)
	hearts.spread = 45.0
	hearts.gravity = Vector2(0, -80)
	hearts.initial_velocity_min = 30.0
	hearts.initial_velocity_max = 90.0
	hearts.scale_amount_min = 0.45
	hearts.scale_amount_max = 0.9
	add_child(hearts)

func _emit_hearts() -> void:
	if hearts == null:
		return
	hearts.restart()
	hearts.emitting = true

func _physics_process(delta: float) -> void:
	if is_dragging:
		var mouse_pos = Vector2(DisplayServer.mouse_get_position())
		var instant_velocity: Vector2 = (mouse_pos - last_drag_mouse) / maxf(delta, 0.001)
		drag_velocity = drag_velocity.lerp(instant_velocity, 0.35)
		if mouse_pos.distance_to(last_drag_mouse) < 0.5:
			drag_velocity = drag_velocity.lerp(Vector2.ZERO, 0.2)
		last_drag_mouse = mouse_pos
		DisplayServer.window_set_position(Vector2i(mouse_pos - drag_offset))
		return

	if is_thrown:
		_apply_throw(delta)
		return

	if is_menu_open:
		return

	idle_speech_timer -= delta
	if idle_speech_timer <= 0.0:
		idle_speech_timer = randf_range(22.0, 40.0)
		if not is_asleep and not is_waking and not is_falling_asleep and not is_posing:
			_speak(SPEECH_LINES.pick_random(), 2.0)

	if is_asleep or is_waking or is_falling_asleep or is_posing:
		return

	if is_staying:
		speed = 0.0
		_face_mouse()
		_play("Idle_" + facing)
		return

	if follow_cursor:
		_follow_cursor(delta)
	else:
		_wander(delta)

func _face_mouse() -> void:
	var center: Vector2 = Vector2(DisplayServer.window_get_position()) + window_size / 2.0
	var to_mouse: Vector2 = _mouse_position() - center
	if to_mouse.length() > 8.0:
		facing = _direction_name(to_mouse)

func _start_throw(velocity: Vector2) -> void:
	throw_velocity = velocity.limit_length(1600.0)
	is_thrown = true
	is_asleep = false
	is_waking = false
	is_falling_asleep = false
	is_posing = false
	facing = _direction_name(throw_velocity)
	_play("Walk_" + facing)
	_speak("¡Wheee!", 1.2)

func _apply_throw(delta: float) -> void:
	var window_position := Vector2(DisplayServer.window_get_position())
	var max_x := maxf(0.0, screen_size.x - window_size.x)
	var max_y := maxf(0.0, screen_size.y - window_size.y)
	var next := window_position + throw_velocity * delta
	if next.x < 0.0 or next.x > max_x:
		throw_velocity.x *= -0.65
		next.x = clampf(next.x, 0.0, max_x)
	if next.y < 0.0 or next.y > max_y:
		throw_velocity.y *= -0.65
		next.y = clampf(next.y, 0.0, max_y)
	throw_velocity *= exp(-2.2 * delta)
	window_position = next
	DisplayServer.window_set_position(Vector2i(window_position))
	if throw_velocity.length() < 35.0:
		throw_velocity = Vector2.ZERO
		is_thrown = false
		speed = 0.0
		_play("Idle_" + facing)
		_speak("¡Uy!", 1.2)
		_emit_hearts()
		_save_state()
	else:
		direction = throw_velocity.normalized()
		facing = _direction_name(direction)
		_play("Walk_" + facing)

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
	if is_thrown:
		is_thrown = false
		throw_velocity = Vector2.ZERO
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
			_pet_interaction()
		3:
			follow_cursor = not follow_cursor
			if follow_cursor:
				is_staying = false
			else:
				wander_timer = 0.0
			_sync_menu_checks()
		4:
			is_staying = not is_staying
			if is_staying:
				follow_cursor = false
			else:
				wander_timer = 0.0
			_sync_menu_checks()
		5:
			if not is_asleep and not is_falling_asleep:
				is_posing = false
				is_waking = false
				is_falling_asleep = true
				speed = 0.0
				facing = "Left"
				_play("Sleep_Start_Left")
				_speak("Zzz...", 1.5)
		6:
			if is_asleep or is_falling_asleep:
				is_asleep = false
				is_falling_asleep = false
				is_posing = false
				is_waking = true
				speed = 0.0
				_play("Wake_Left")
				_speak("¡Hola!", 1.5)
		7:
			var now := Time.get_time_dict_from_system()
			_speak("Son las %02d:%02d" % [now.hour, now.minute], 3.0)
		8:
			get_tree().quit()
	_save_state()

func _pet_interaction() -> void:
	_emit_hearts()
	if is_asleep or is_falling_asleep or is_waking:
		_speak("Zzz...", 1.5)
	else:
		_speak(SPEECH_LINES.pick_random(), 2.0)
		_play_cry()

func _sync_menu_checks() -> void:
	var follow_idx := menu.get_item_index(3)
	var stay_idx := menu.get_item_index(4)
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
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_change_pet_scale(0.05 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.05)
				_save_state()
				get_viewport().set_input_as_handled()
			return
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
				drag_velocity = Vector2.ZERO
				_play_cry()
				_emit_hearts()
				_speak("¡Miau!", 1.2)
				return
			pending_menu = false
			click_timer.stop()
			is_dragging = true
			drag_velocity = Vector2.ZERO
			drag_start_mouse = Vector2(DisplayServer.mouse_get_position())
			last_drag_mouse = drag_start_mouse
			var win_pos = Vector2(DisplayServer.window_get_position())
			drag_offset = drag_start_mouse - win_pos
		else:
			var was_dragging: bool = is_dragging
			is_dragging = false
			if suppress_menu_release:
				suppress_menu_release = false
				return
			var mouse_pos = Vector2(DisplayServer.mouse_get_position())
			if mouse_pos.distance_to(drag_start_mouse) < 4.0:
				_schedule_menu(event.position)
			elif was_dragging and drag_velocity.length() > 250.0:
				_start_throw(drag_velocity)
			else:
				drag_velocity = Vector2.ZERO
				_save_state()
