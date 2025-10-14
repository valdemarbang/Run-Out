extends Control

@export var player : CharacterBody3D

@onready var _timer_label: Label = $RoundTimerLabel if has_node("RoundTimerLabel") else null

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

func show_round_banner(text: String, color := Color(1,1,1), duration := 20.0) -> void:
	var label: Label = $RoundBanner if has_node("RoundBanner") else null
	if not label:
		push_warning("HUD RoundBanner label not found")
		return
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.visible = true
	var tween := create_tween()
	tween.tween_interval(duration)
	tween.tween_property(label, "modulate:a", 0.0, 0.4).from(1.0)
	tween.finished.connect(func():
		label.visible = false
		label.modulate.a = 1.0)
