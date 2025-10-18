extends Node

var round_manager: RoundManager
var display_name: String = "Player"

func _ready():
	# Create RoundManager instance and add it as a child
	round_manager = RoundManager.new()
	add_child(round_manager)
	#round_manager.start_round(10)
	
func set_display_name(name: String) -> void:
	name = name.strip_edges()
	if name == "":
		return
	display_name = name.substr(0, 20)  # simple length cap
