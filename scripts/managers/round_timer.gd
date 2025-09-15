extends Control

@onready var timer_label = $TimerLabel

func _ready():
	Global.round_manager.connect("time_updated", Callable(self, "_on_time_updated"))
	Global.round_manager.connect("round_ended", Callable(self, "_on_round_ended"))

func _on_time_updated(time_left: int) -> void:
	timer_label.text = format_time(time_left)

func _on_round_ended():
	timer_label.text = "00:00"

func format_time(seconds: int) -> String:
	var minutes = seconds / 60
	var secs = seconds % 60
	return str(minutes).pad_zeros(2) + ":" + str(secs).pad_zeros(2)
