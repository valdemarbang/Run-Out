extends MultiplayerSynchronizer

@export var jumping := false
@export var crouching := false
@export var input_direction := Vector2()

func _ready() -> void:
	set_process(is_multiplayer_authority())

func _process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return
	input_direction = Input.get_vector("left", "right", "up", "down")
	jumping = Input.is_action_pressed("jump")      # hold to bhop
	crouching = Input.is_action_pressed("crouch")  # hold to crouch
