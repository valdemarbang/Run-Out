extends Node
class_name RoundManager

signal time_updated(time_left)
signal round_ended()

var round_time := 120
var running := false
var timer := Timer.new()

func _ready():
	# Setup internal timer
	timer.wait_time = 1
	timer.one_shot = false
	add_child(timer)
	timer.connect("timeout", Callable(self, "_on_tick"))

func start_round(duration: int = 60):
	round_time = duration
	running = true
	timer.start()
	emit_signal("time_updated", round_time)

func _on_tick():
	if running:
		round_time -= 1
		emit_signal("time_updated", round_time)
		if round_time <= 0:
			timer.stop()
			running = false
			emit_signal("round_ended")
