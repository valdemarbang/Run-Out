extends CharacterBody3D

@export var look_sensitivity : float = 0.006

# Walk settings
@export var jump_velocity := 6.0
@export var auto_bhop := true
@export var walk_speed := 7.0
@export var ground_accel := 14.0
@export var ground_decel := 10.0
@export var ground_friction := 6.0

# Air settings
@export var air_cap := 0.85 # Can surf ramps
@export var air_accel := 800.0
@export var air_move_speed := 500.0

# Headbob camera
const HEADBOB_MOVE_AMOUNT = 0.06
const HEADBOB_FREQUENCY = 2.4
var headbob_time := 0.0

# Store inpuit direction for multiple functions
var wish_dir := Vector3.ZERO

func _ready():
	# Hide your own player model from the player camera
	for child in %WorldModel.find_children("*", "VisualInstance3D"):
		child.set_layer_mask_value(1, false)
		child.set_layer_mask_value(2, true)
		
func  _unhandled_input(event: InputEvent) -> void:
	# Check if mouseclick and we can use mouse
	if event is InputEventMouseButton:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event.is_action_pressed("ui_cancel"): # Escape clicked then stop using mouse
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	# Use the mouse to move the camera in the scene
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			rotate_y(-event.relative.x * look_sensitivity)
			%Camera3D.rotate_x(-event.relative.y * look_sensitivity)
			# Prevent backflips with the camera lmao
			%Camera3D.rotation.x = clamp(%Camera3D.rotation.x, deg_to_rad(-90), deg_to_rad(90)) 

func _handle_air_physics(delta) -> void:
	# Delta amount of seconds that passed since the last physics frame, speed up the fall.
	self.velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	
	# Counter-Strike 1.6 movement in air.
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir) # How fast player is moving in curr dir
	
	var capped_speed = min((air_move_speed * wish_dir).length(), air_cap) # Max speed cap
	var add_speed_till_cap = capped_speed - cur_speed_in_wish_dir 
	if add_speed_till_cap > 0:
		var accel_speed = air_accel * air_move_speed * delta
		accel_speed = min(accel_speed, add_speed_till_cap)
		self.velocity += accel_speed * wish_dir
		
	if is_on_wall():
		if is_surface_too_steep(get_wall_normal()):
			self.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		else:
			self.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		clip_velocity(get_wall_normal(), 1, delta) # Allow surfing
	

func _handle_ground_physics(delta) -> void:
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir) # How fast player is moving in curr dir
	var add_speed_till_cap = walk_speed - cur_speed_in_wish_dir
	if add_speed_till_cap > 0:
		var accel_speed = ground_accel * walk_speed * delta
		accel_speed = min(accel_speed, add_speed_till_cap)
		self.velocity += accel_speed * wish_dir
		
	var control = max(self.velocity.length(), ground_decel)
	var drop = control * ground_friction * delta
	var new_speed = max(self.velocity.length() - drop, 0.0)
	if self.velocity.length() > 0:
		new_speed /= self.velocity.length()
	self.velocity *= new_speed
	
	_headbob_effect(delta)
	
func clip_velocity(normal: Vector3, overbounce : float, delta : float) -> void:
	var backoff := self.velocity.dot(normal) * overbounce
	
	if backoff >= 0: return
	
	var change := normal * backoff
	self.velocity -= change
	var adjust := self.velocity.dot(normal)
	if adjust < 0.0:
		self.velocity -= normal * adjust
		
func is_surface_too_steep(normal : Vector3) -> bool:
	var max_slope_ang_dot = Vector3(0, 1, 0).rotated(Vector3(1.0, 0, 0), self.floor_max_angle).dot(Vector3(0, 1, 0))
	if normal.dot(Vector3(0, 1, 0)) < max_slope_ang_dot:
		return true
	return false
	
func _headbob_effect(delta):
	headbob_time += delta * self.velocity.length() # Faster we moving the more bobbing
	# Camera pivot around the head node, as a cos/sin wave in x/y camera dir. 
	%Camera3D.transform.origin = Vector3( 
		cos(headbob_time * HEADBOB_FREQUENCY * 0.5) * HEADBOB_MOVE_AMOUNT, # side to side
		sin(headbob_time * HEADBOB_FREQUENCY) * HEADBOB_MOVE_AMOUNT, # up and down
		0
	)

func _physics_process(delta: float) -> void:
	# Normalize to keep 1.0 or below for multiple keys at the same time.
	var input_dir = Input.get_vector("left", "right", "up", "down").normalized()
	# How we want to character to move in the world.
	wish_dir = self.global_transform.basis * Vector3(input_dir.x, 0., input_dir.y)
	
	if is_on_floor():
		if Input.is_action_just_pressed("jump") or (auto_bhop and Input.is_action_pressed("jump")):
			self.velocity.y = jump_velocity
		_handle_ground_physics(delta)
	else:
		_handle_air_physics(delta)
		
	move_and_slide()
	
func _process(delta: float) -> void:
	pass
