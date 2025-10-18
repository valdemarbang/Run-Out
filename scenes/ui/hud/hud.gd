extends Control

@export var player : CharacterBody3D

@onready var _timer_label: Label = $RoundTimerLabel if has_node("RoundTimerLabel") else null
@onready var _banner_label: Label = $RoundBanner if has_node("RoundBanner") else null
@onready var _spawn_info_label: Label = $SpawnInfo if has_node("SpawnInfo") else null

# Queue rounds banners so they dont overlap or interrupt each other.
var _banner_queue: Array = []
var _banner_showing := false

func _ready() -> void:
	Global.round_manager.round_started.connect(_on_round_started)
	Global.round_manager.time_left_changed.connect(_on_time_left_changed)
	Global.round_manager.round_ended.connect(_on_round_ended)

func _on_round_started(duration: int) -> void:
	_update_timer(duration)

func _on_time_left_changed(seconds_left: int) -> void:
	_update_timer(seconds_left)

func _on_round_ended() -> void:
	_update_timer(0)

func _update_timer(seconds_left: int) -> void:
	if not _timer_label:
		return
	var m: int = int(seconds_left / 60)
	var s: int = seconds_left % 60
	_timer_label.text = "%02d:%02d" % [m, s]

func show_round_banner(text: String, color := Color(1,1,1), duration := 5.0) -> void:
	# Enqueue messages to avoid overlap
	_banner_queue.append({"text": text, "color": color, "duration": duration})
	_try_show_next_banner()

func _try_show_next_banner() -> void:
	if _banner_showing or _banner_label == null or _banner_queue.is_empty():
		return
	var data: Dictionary = _banner_queue.pop_front()
	_show_banner_now(String(data.get("text", "")), data.get("color", Color(1,1,1)), float(data.get("duration", 5.0)))

func _show_banner_now(text: String, color: Color, duration: float) -> void:
	if _banner_label == null:
		return
	_banner_showing = true
	_banner_label.text = text
	_banner_label.add_theme_color_override("font_color", color)
	_banner_label.visible = true
	_banner_label.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(duration)
	tween.tween_property(_banner_label, "modulate:a", 0.0, 0.4).from(1.0)
	tween.finished.connect(func():
		_banner_label.visible = false
		_banner_label.modulate.a = 1.0
		_banner_showing = false
		_try_show_next_banner())

func show_spawn_info(text: String, color := Color(1,1,1), duration := 20.0) -> void:
	if _spawn_info_label == null:
		return
	_spawn_info_label.text = text
	_spawn_info_label.add_theme_color_override("font_color", color)
	_spawn_info_label.visible = true
	_spawn_info_label.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(duration)
	tween.tween_property(_spawn_info_label, "modulate:a", 0.0, 0.4).from(1.0)
	tween.finished.connect(func():
		_spawn_info_label.visible = false
		_spawn_info_label.modulate.a = 1.0)
