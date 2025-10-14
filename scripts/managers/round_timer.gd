extends Control

@onready var timer_label = $TimerLabel

func _ready() -> void:
	var rm = Global.round_manager
	if rm:
		if not rm.round_started.is_connected(_on_round_started):
			rm.round_started.connect(_on_round_started)
		if not rm.time_left_changed.is_connected(_on_time_left_changed):
			rm.time_left_changed.connect(_on_time_left_changed)
		if not rm.round_ended.is_connected(_on_round_ended):
			rm.round_ended.connect(_on_round_ended)

func _on_round_started(duration: int) -> void:
	_on_time_left_changed(duration)

func _on_time_left_changed(seconds_left: int) -> void:
	timer_label.text = format_time(seconds_left)

func _on_round_ended() -> void:
	_on_time_left_changed(0)

func format_time(seconds: int) -> String:
	var minutes = seconds / 60
	var secs = seconds % 60
	return str(minutes).pad_zeros(2) + ":" + str(secs).pad_zeros(2)
