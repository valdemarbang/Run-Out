extends CharacterBody3D

@export var LOOK_SENSITIVITY : float = 0.006

# Walk settings
const JUMP_VELOCITY = 6.0
const AUTO_BHOP = true
const WALK_SPEED = 7.0
const GROUND_ACCEL = 14.0
const GROUND_DECEL = 10.0
const GROUND_FRICTION = 6.0

# Crouch settings
const CROUCH_SMALLER_MODEL = 0.7
const CROUCH_JUMP_ADD = CROUCH_SMALLER_MODEL * 0.9 # for crouch jumps
var is_crouched = false

# Stairs settings
const MAX_STEP_HEIGHT = 0.5
var _snapped_to_stairs_last_frame = false
var _last_frame_was_on_floor = -INF

# Store input direction for multiple functions
var wish_dir := Vector3.ZERO

# Air settings
const AIR_CAP = 0.85 # Can surf ramps
const AIR_ACCEL = 800.0
const AIR_MOVE_SPEED = 500.0

# Headbob camera
const HEADBOB_MOVE_AMOUNT = 0.06
const HEADBOB_FREQUENCY = 2.4
var headbob_time := 0.0

func get_move_speed() -> float:
	if is_crouched:
		return WALK_SPEED * 0.8
	else:
		return WALK_SPEED

func _ready():
	# Runs when player model first loads into the world
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Hide your own player model from the player camera
	for child in %WorldModel.find_children("*", "VisualInstance3D"):
		child.set_layer_mask_value(1, false)
		child.set_layer_mask_value(2, true)
		
func  _unhandled_input(event: InputEvent) -> void:
	# Handle all keyboard input to playermodel
	
	# Check if mouseclick and we can use mouse
	if event is InputEventMouseButton:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event.is_action_pressed("ui_cancel"): # Escape clicked then stop using mouse
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	# Use the mouse to move the camera in the scene
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			rotate_y(-event.relative.x * LOOK_SENSITIVITY)
			%Camera3D.rotate_x(-event.relative.y * LOOK_SENSITIVITY)
			# Prevent backflips with the camera lmao
			%Camera3D.rotation.x = clamp(%Camera3D.rotation.x, deg_to_rad(-90), deg_to_rad(90)) 

func _handle_air_physics(delta) -> void:
	# Handle the air physics for the player model
	
	# Delta amount of seconds that passed since the last physics frame, speed up the fall.
	self.velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	
	# Counter-Strike movement in air.
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir) # How fast player is moving in curr dir
	
	# This allows for infinite speed movement when bhopping/strafing in the air.
	# Basically if the player is going 1000 speed foward they can still increase
	# their speed on the right and left direction and then increase their speed forward.
	var capped_speed = min((AIR_MOVE_SPEED * wish_dir).length(), AIR_CAP) # Max speed cap
	var add_speed_till_cap = capped_speed - cur_speed_in_wish_dir 
	if add_speed_till_cap > 0:
		var accel_speed = AIR_ACCEL * AIR_MOVE_SPEED * delta
		accel_speed = min(accel_speed, add_speed_till_cap) # Dont increase it past the speed cap.
		self.velocity += accel_speed * wish_dir
		
	if is_on_wall():
		# Make it possible to surf on steep falls without getting stuck
		if is_surface_too_steep(get_wall_normal()):
			self.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		else:
			self.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		wall_clip_velocity(get_wall_normal()) # Allow surfing in general

func _handle_ground_physics(delta) -> void:
	# Similar how the air phyics works.
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir) # How fast player is moving in curr dir
	var add_speed_till_cap = get_move_speed() - cur_speed_in_wish_dir
	if add_speed_till_cap > 0:
		var accel_speed = GROUND_ACCEL * get_move_speed() * delta
		accel_speed = min(accel_speed, add_speed_till_cap)
		self.velocity += accel_speed * wish_dir
		
	# Apply fritiction to the ground
	var control = max(self.velocity.length(), GROUND_DECEL)
	var velocity_drop_per_frame = control * GROUND_FRICTION * delta
	var new_speed = max(self.velocity.length() - velocity_drop_per_frame, 0.0)
	if self.velocity.length() > 0: # If we are not stopped yet
		new_speed /= self.velocity.length()
	self.velocity *= new_speed
	
	_headbob_effect(delta)
	
func wall_clip_velocity(wall_coll_normal: Vector3) -> void:
	# Adjusts the player's velocity so they don't get stuck when colliding with a sloped wall.
	# 
	# If the player is moving *into* the wall (velocity has a component in the direction
	# of the wall's normal), we "clip" that component away so they can slide along
	# the wall instead of sticking.
	# If they're moving away from the wall, we do nothing.
	
	# If we are moving away from a wall we can return and stop the function
	if self.velocity.dot(wall_coll_normal) >= 0: return
	
	# Two iteration to check so we are not getting stuck on slope wall.
	self.velocity -= wall_coll_normal # substract the velocity that points into the wall, to keep sliding
	var adjust := self.velocity.dot(wall_coll_normal)
	if adjust < 0.0:
		self.velocity -= wall_coll_normal * adjust
		
func is_surface_too_steep(wall_coll_normal : Vector3) -> bool:
	# Compare the wall's normal with the "up" vector (0, 1, 0)
	# If the dot product is smaller, the surface is steeper than allowed
	return wall_coll_normal.angle_to(Vector3.UP) > self.floor_max_angle
	
func _headbob_effect(delta):
	headbob_time += delta * self.velocity.length() # Faster we moving the more bobbing
	# Camera pivot around the head node, as a cos/sin wave in x/y camera dir. 
	%Camera3D.transform.origin = Vector3( 
		cos(headbob_time * HEADBOB_FREQUENCY * 0.5) * HEADBOB_MOVE_AMOUNT, # side to side
		sin(headbob_time * HEADBOB_FREQUENCY) * HEADBOB_MOVE_AMOUNT, # up and down
		0
	)
	
func _run_body_test_motion(from : Transform3D, motion : Vector3, result = null) -> bool:
	# Test the player models in a new position before moving the real player model
	if not result: result = PhysicsTestMotionResult3D.new()
	var params = PhysicsTestMotionParameters3D.new()
	params.from = from # initial position ( current pos of player )
	params.motion = motion # Directly down the stairs below us
	return PhysicsServer3D.body_test_motion(self.get_rid(), params, result)
	
func _snap_up_stairs_check(delta) -> bool:
	if not is_on_floor() and not _snapped_to_stairs_last_frame: return false
	# Don't snap stairs if trying to jump, also no need to check for stairs ahead if not moving
	if self.velocity.y > 0 or (self.velocity * Vector3(1,0,1)).length() == 0: return false
	var expected_move_motion = self.velocity * Vector3(1,0,1) * delta
	var step_pos_with_clearance = self.global_transform.translated(expected_move_motion + Vector3(0, MAX_STEP_HEIGHT * 2, 0))
	# Run a body_test_motion slightly above the pos we expect to move to, towards the floor.
	#  We give some clearance above to ensure there's ample room for the player.
	#  If it hits a step <= MAX_STEP_HEIGHT, we can teleport the player on top of the step
	#  along with their intended motion forward.
	var down_check_result = KinematicCollision3D.new()
	if (self.test_move(step_pos_with_clearance, Vector3(0,-MAX_STEP_HEIGHT*2,0), down_check_result)
	and (down_check_result.get_collider().is_class("StaticBody3D") or down_check_result.get_collider().is_class("CSGShape3D"))):
		var step_height = ((step_pos_with_clearance.origin + down_check_result.get_travel()) - self.global_position).y
		# Note I put the step_height <= 0.01 in just because I noticed it prevented some physics glitchiness
		# 0.02 was found with trial and error. Too much and sometimes get stuck on a stair. Too little and can jitter if running into a ceiling.
		# The normal character controller (both jolt & default) seems to be able to handled steps up of 0.1 anyway
		if step_height > MAX_STEP_HEIGHT or step_height <= 0.01 or (down_check_result.get_position() - self.global_position).y > MAX_STEP_HEIGHT: return false
		%StairsAheadRayCast3D.global_position = down_check_result.get_position() + Vector3(0,MAX_STEP_HEIGHT,0) + expected_move_motion.normalized() * 0.1
		%StairsAheadRayCast3D.force_raycast_update()
		if %StairsAheadRayCast3D.is_colliding() and not is_surface_too_steep(%StairsAheadRayCast3D.get_collision_normal()):
			self.global_position = step_pos_with_clearance.origin + down_check_result.get_travel()
			apply_floor_snap()
			_snapped_to_stairs_last_frame = true
			return true
	_snapped_to_stairs_last_frame = false
	return false
	
func _snap_down_to_stairs_check() -> void:
	var did_snap = false
	var floor_below : bool = %StairsBelowRayCast3D.is_colliding() and not is_surface_too_steep(%StairsBelowRayCast3D.get_collision_normal())
	var was_on_floor_last_frame = Engine.get_physics_frames() - _last_frame_was_on_floor == 1
	if not is_on_floor() and velocity.y <= 0 and (was_on_floor_last_frame or _snapped_to_stairs_last_frame) and floor_below:
		var body_test_result = PhysicsTestMotionResult3D.new()
		if _run_body_test_motion(self.global_transform, Vector3(0, -MAX_STEP_HEIGHT, 0), body_test_result):
			var translate_y = body_test_result.get_travel().y
			self.position.y += translate_y
			apply_floor_snap()
			did_snap = true
	_snapped_to_stairs_last_frame = did_snap

func _physics_process(delta: float) -> void:
	# Normalize to keep 1.0 or below for multiple keys at the same time.
	var input_dir = Input.get_vector("left", "right", "up", "down").normalized()
	# How we want to character to move in the world.
	wish_dir = self.global_transform.basis * Vector3(input_dir.x, 0., input_dir.y)
	
	_handle_crouch(delta)
	
	if is_on_floor() or _snapped_to_stairs_last_frame: # Handle bhopping and jumping
		if Input.is_action_just_pressed("jump") or (AUTO_BHOP and Input.is_action_pressed("jump")):
			self.velocity.y = JUMP_VELOCITY
		_handle_ground_physics(delta)
		_last_frame_was_on_floor = Engine.get_physics_frames() # Handle stairs.
	else:
		_handle_air_physics(delta)
		
	if not _snap_up_stairs_check(delta):
		move_and_slide() # Moves the Char based on velocity.
		_snap_down_to_stairs_check()
		
@onready var _original_player_height = $CollisionShape3D.shape.height
func _handle_crouch(delta) -> void:
	var was_crouched_last_frame = is_crouched

	# 1) Läs input — sätt crouch om crouch-knappen hålls ner
	if Input.is_action_pressed("crouch"):
		is_crouched = true
	elif is_crouched:
		# 2) Testa om det finns plats att resa sig (test_move returnerar true om det skulle kollidera)
		var stand_motion = Vector3(0, CROUCH_SMALLER_MODEL, 0)
		var test_result = KinematicCollision3D.new()
		var would_collide = self.test_move(self.global_transform, stand_motion, test_result)
		if not would_collide:
			# finns plats -> stå upp
			is_crouched = false
		else:
			# finns inte plats -> fortsätt crouch
			is_crouched = true

	# 3) Hantera "crouch-jump" (flytta spelaren om vi byter läge i luften)
	var translate_y_if_possible = 0.0
	if was_crouched_last_frame != is_crouched and not is_on_floor() and not _snapped_to_stairs_last_frame:
		translate_y_if_possible = CROUCH_JUMP_ADD if is_crouched else -CROUCH_JUMP_ADD

	if translate_y_if_possible != 0.0:
		var result = KinematicCollision3D.new()
		self.test_move(self.transform, Vector3(0, translate_y_if_possible, 0), result)
		self.position.y += result.get_travel().y
		%Head.position.y -= result.get_travel().y
		%Head.position.y = clampf(%Head.position.y, -CROUCH_SMALLER_MODEL, 0)

	# 4) Mjuk head/camera-övergång varje frame
	%Head.position.y = move_toward(%Head.position.y, -CROUCH_SMALLER_MODEL if is_crouched else 0, 7.0 * delta)

	# 5) Uppdatera collision-shape höjd (baserat på is_crouched)
	#    Viktigt: collision ändras bara baserat på is_crouched som sattes efter klarhets-testet ovan.
	$CollisionShape3D.shape.height = _original_player_height - CROUCH_SMALLER_MODEL if is_crouched else _original_player_height
	$CollisionShape3D.position.y = $CollisionShape3D.shape.height / 2

	# 6) Mjuk visuellt scale (gör inte snap tillbaka till 1.0 om vi inte kan stå)
	var target_scale_y = 0.7 if is_crouched else 1.0
	%WorldModel.scale.y = lerp(%WorldModel.scale.y, target_scale_y, clamp(12.0 * delta, 0.0, 1.0))
