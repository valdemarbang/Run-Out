extends Node

var round_manager: RoundManager

func _ready():
	# Create RoundManager instance and add it as a child
	round_manager = RoundManager.new()
	add_child(round_manager)
	#round_manager.start_round(10)
