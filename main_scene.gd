extends Node2D

var speed = 300.0
var direction = Vector2.ZERO

var screen_size = Vector2()
var window_size = Vector2.ZERO

var is_dragging = false
var drag_offset = Vector2()
var is_asleep = false
var hover_rect = Rect2()
var last_mouse = Vector2.ZERO
var still_time = 0.0

@onready var animated_sprite = $AnimatedSprite2D
@onready var area = $Area2D

func _ready():
	screen_size = Vector2(DisplayServer.screen_get_size())
	window_size = Vector2(DisplayServer.window_get_size())
	area.input_event.connect(_on_area_input)

	var frame_size = Vector2(32, 40)
	var body_local = Rect2(4, 3, 24, 24)
	var frame_origin = (window_size - frame_size * animated_sprite.scale) / 2
	hover_rect = Rect2(frame_origin + body_local.position * animated_sprite.scale, body_local.size * animated_sprite.scale)

func _physics_process(delta: float) -> void:
	if is_dragging:
		var mouse_pos = Vector2(DisplayServer.mouse_get_position())
		DisplayServer.window_set_position(Vector2i(mouse_pos - drag_offset))
		return

	var mouse = Vector2(DisplayServer.mouse_get_position())
	var window_position = Vector2(DisplayServer.window_get_position())
	var hovering = hover_rect.has_point(mouse - window_position)

	if hovering and mouse == last_mouse:
		still_time += delta
	else:
		still_time = 0.0
	last_mouse = mouse

	var should_sleep = hovering and still_time > 0.3

	if should_sleep != is_asleep:
		is_asleep = should_sleep
		if is_asleep:
			speed = 0.0
			animated_sprite.play("Sleep")
		else:
			animated_sprite.play("Walk_Right")

	if is_asleep:
		return

	var pet_center = window_position + hover_rect.get_center()
	var to_mouse = mouse - pet_center
	direction = to_mouse.normalized()

	if to_mouse.length() > 4.0:
		speed = 300.0
		animated_sprite.flip_h = direction.x < 0
		if animated_sprite.animation != "Walk_Right":
			animated_sprite.play("Walk_Right")
	else:
		speed = 0.0
		if animated_sprite.animation != "Idle":
			animated_sprite.play("Idle")

	window_position += direction * speed * delta
	window_position.x = clamp(window_position.x, 0, screen_size.x - window_size.x)
	window_position.y = clamp(window_position.y, 0, screen_size.y - window_size.y)
	DisplayServer.window_set_position(Vector2i(window_position))

func _on_area_input(_viewport, event, _shape_idx):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			is_dragging = true
			var mouse_pos = Vector2(DisplayServer.mouse_get_position())
			var win_pos = Vector2(DisplayServer.window_get_position())
			drag_offset = mouse_pos - win_pos
		else:
			is_dragging = false
