extends Node
class_name RoundManager

signal round_started(duration: int)
signal time_left_changed(seconds_left: int)
signal round_ended() # time up

var _running: bool = false
var _duration: int = 0
var _seconds_left: int = 0
var _tick_timer: Timer

func _ready() -> void:
	_tick_timer = Timer.new()
	_tick_timer.wait_time = 1.0
	_tick_timer.one_shot = false
	add_child(_tick_timer)
	_tick_timer.timeout.connect(_on_tick)

func start_round(duration: int) -> void:
	# Server starts; clients will get rpc callbacks.
	if not multiplayer.is_server():
		return
	_running = true
	_duration = duration
	_seconds_left = duration
	_emit_and_broadcast_start(duration)
	_tick_timer.start()

func stop_round() -> void:
	if not multiplayer.is_server():
		return
	if not _running:
		return
	_running = false
	_tick_timer.stop()
	_emit_and_broadcast_end()

func _on_tick() -> void:
	if not _running:
		return
	_seconds_left = max(0, _seconds_left - 1)
	emit_signal("time_left_changed", _seconds_left)
	_client_set_time_left.rpc(_seconds_left) # broadcast
	if _seconds_left <= 0:
		stop_round()

# Server -> all peers (and self)
@rpc("authority", "call_local")
func _client_start(duration: int) -> void:
	_running = true
	_duration = duration
	_seconds_left = duration
	emit_signal("round_started", duration)
	emit_signal("time_left_changed", _seconds_left)

@rpc("authority", "call_local", "unreliable")
func _client_set_time_left(seconds_left: int) -> void:
	_seconds_left = seconds_left
	emit_signal("time_left_changed", _seconds_left)

@rpc("authority", "call_local")
func _client_end() -> void:
	_running = false
	emit_signal("round_ended")

func _emit_and_broadcast_start(duration: int) -> void:
	emit_signal("round_started", duration)
	emit_signal("time_left_changed", _seconds_left)
	_client_start.rpc(duration)

func _emit_and_broadcast_end() -> void:
	emit_signal("round_ended")
	_client_end.rpc()
