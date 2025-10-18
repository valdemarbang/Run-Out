extends CharacterBody3D

@export var LOOK_SENSITIVITY : float = 0.006

# Walk settings
const JUMP_VELOCITY = 6.0
const WALK_SPEED = 7.0
const GROUND_ACCEL = 14.0
const GROUND_DECEL = 10.0
const GROUND_FRICTION = 6.0

# Crouch settings
const CROUCH_SMALLER_MODEL = 0.7
const CROUCH_JUMP_ADD = CROUCH_SMALLER_MODEL * 0.9 # for crouch jumps
var is_crouched = false
var _last_crouch_state = false
@onready var _original_player_height = $CollisionShape3D.shape.height

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

# Team information
const TEAM_HIDER := 0
const TEAM_SEEKER := 1

var team_id: int = -1
const TEAM_COLOR_SEEKER := Color(0.25, 0.6, 1.0)
const TEAM_COLOR_HIDER := Color(1.0, 0.3, 0.25)

var is_caught := false
@onready var _mesh: MeshInstance3D = $"WorldModel/MeshInstance3D" if has_node("WorldModel/MeshInstance3D") else null
@onready var _touch_area: Area3D = null

# Fall outside the map
const DEATH_Y := -50.0
var _out_of_bounds_reported := false

var was_on_floor_last_frame : bool = true

@onready var input : MultiplayerSynchronizer = $PlayerInput

# Spectate state
var is_spectating: bool = false
var _spectate_fixed_pos: Vector3 = Vector3.ZERO

# Sound effect
@onready var _footsteps_sfx: AudioStreamPlayer3D = %FootstepsSFX
@onready var _catch_sfx: AudioStreamPlayer3D = %CatchSFX

var _step_timer := 0.0
const STEP_INTERVAL_WALK := 0.4

func start_map_spectating(pos: Vector3, look_at: Vector3) -> void:
	print("spectate", pos, look_at)
	is_spectating = true
	_spectate_fixed_pos = pos
	%Camera3D.look_at(look_at, Vector3.UP)
	%Camera3D.transform = Transform3D.IDENTITY

func stop_spectating() -> void:
	if not is_spectating:
		return
	is_spectating = false

func get_move_speed() -> float:
	if is_crouched:
		return WALK_SPEED * 0.8
	else:
		return WALK_SPEED
		
func _ready() -> void:
	print("=== FPS Controller Ready ===")
	print("Player name: ", name)
	print("My multiplayer ID: ", multiplayer.get_unique_id())
	print("My authority: ", get_multiplayer_authority())
	print("Is multiplayer authority: ", is_multiplayer_authority())
	print("PlayerInput authority: ", $PlayerInput.get_multiplayer_authority())
	
	# Set team if no team is assigned yet.
	if team_id != -1:
		_apply_team_visual()
	
	# Only enable camera for the local player
	%Camera3D.current = is_multiplayer_authority()

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	_reset_models()

	_touch_area = get_node_or_null("TouchArea") as Area3D
	if _touch_area and not _touch_area.body_entered.is_connected(_on_touch_area_body_entered):
		_touch_area.body_entered.connect(_on_touch_area_body_entered)

func _reset_models() -> void:
	if is_multiplayer_authority():
		var world_model := get_node_or_null("%WorldModel")
		if world_model: world_model.visible = false
		var glasses := get_node_or_null("WorldModel/disguise-glasses")
		if glasses: glasses.visible = false

func set_team(team: int) -> void:
	team_id = team
	_apply_team_visual()

func _apply_team_visual() -> void:
	if _mesh:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = TEAM_COLOR_SEEKER if team_id == TEAM_SEEKER else TEAM_COLOR_HIDER
		_mesh.material_override = mat

func set_caught(caught: bool) -> void:
	if is_caught == caught:
		return
	is_caught = caught

	# Hide 3rd-person model when caught (for everyone)
	var wm := get_node_or_null("%WorldModel")
	if wm:
		wm.visible = not caught
	var glasses := get_node_or_null("WorldModel/disguise-glasses")
	if glasses:
		glasses.visible = not caught

	var cs := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs:
		cs.set_deferred("disabled", caught)
	if _touch_area:
		_touch_area.set_deferred("monitoring", not caught)
		_touch_area.set_deferred("monitorable", not caught)

	# Stop any movement so the body doesn’t slide
	velocity = Vector3.ZERO
	_catch_sfx.play()

func _unhandled_input(event: InputEvent) -> void:
	# Only process input for OUR player
	if not is_multiplayer_authority():
		return

	# Handle mouse movement
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * LOOK_SENSITIVITY)
		%Head.rotate_x(-event.relative.y * LOOK_SENSITIVITY)
		%Head.rotation.x = clampf(%Head.rotation.x, -deg_to_rad(89), deg_to_rad(89))
		
	# Allow ESC to release mouse
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return
	
func _handle_air_physics(delta) -> void:
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
	var down_check_result = KinematicCollision3D.new()
	if (self.test_move(step_pos_with_clearance, Vector3(0,-MAX_STEP_HEIGHT*2,0), down_check_result)
	and (down_check_result.get_collider().is_class("StaticBody3D") or down_check_result.get_collider().is_class("CSGShape3D"))):
		var step_height = ((step_pos_with_clearance.origin + down_check_result.get_travel()) - self.global_position).y
		# Note I put the step_height <= 0.01 in just because I noticed it prevented some physics glitchiness
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

func reset_spawn_state() -> void:
	# Physics
	velocity = Vector3.ZERO
	_snapped_to_stairs_last_frame = false
	_last_frame_was_on_floor = -INF
	_out_of_bounds_reported = false

	# Crouch/camera/shape back to defaults
	is_crouched = false
	%WorldModel.visible = true
	%WorldModel.scale.y = 1.0
	var cs := $CollisionShape3D
	cs.shape.height = 2.0
	cs.position.y = 1.0
	$"HeadOriginalPos/Head".position.y = 0.0

	set_caught(false)
	stop_spectating()
	_reset_models()
	
	# Fixes camera bug after replacing model
	%Camera3D.transform = Transform3D.IDENTITY

func _physics_process(delta: float) -> void:
	# Only process physics for OUR player
	if not is_multiplayer_authority():
		return
		
	# Block control if caught or spectating
	if is_caught or is_spectating:
		return

	# Out-of-bounds check (report once per fall)
	if not _out_of_bounds_reported and global_position.y < DEATH_Y:
		_out_of_bounds_reported = true
		var level := get_tree().get_first_node_in_group("level")
		if level:
			var my_id := name.to_int()
			if multiplayer.is_server():
				level.request_out_of_bounds(my_id)
			else:
				level.request_out_of_bounds.rpc_id(1, my_id)
		return
		
	# Get input from the PlayerInput synchronizer
	var input_dir = input.input_direction
	wish_dir = transform.basis * Vector3(input_dir.x, 0., input_dir.y)
	
	# Handle crouching with the proper function
	_handle_crouch(delta)
	
	if is_on_floor() or _snapped_to_stairs_last_frame: # Handle bhopping and jumping
		if input.jumping:
			self.velocity.y = JUMP_VELOCITY
		_handle_ground_physics(delta)
		_last_frame_was_on_floor = Engine.get_physics_frames() # Handle stairs.
	else:
		_handle_air_physics(delta)
		
	if not _snap_up_stairs_check(delta):
		move_and_slide() # Moves the Char based on velocity.
		_snap_down_to_stairs_check()
		
	# Sync crouch state to other clients after processing
	if is_crouched != _last_crouch_state:
		_last_crouch_state = is_crouched
		_sync_crouch.rpc(is_crouched)  # Remove the if multiplayer.is_server() check

func _handle_crouch(delta) -> void:
	var was_crouched_last_frame = is_crouched

	# 1) Read input — crouch while button is held
	if input.crouching:
		is_crouched = true
	elif is_crouched:
		# 2) Test if there's room to stand up
		var stand_motion = Vector3(0, CROUCH_SMALLER_MODEL, 0)
		var test_result = KinematicCollision3D.new()
		var would_collide = self.test_move(self.global_transform, stand_motion, test_result)
		if not would_collide:
			# Room to stand up
			is_crouched = false

	# 3) Handle "crouch-jump" (move player if we change state in the air)
	var translate_y_if_possible = 0.0
	if was_crouched_last_frame != is_crouched and not is_on_floor() and not _snapped_to_stairs_last_frame:
		translate_y_if_possible = CROUCH_JUMP_ADD if is_crouched else -CROUCH_JUMP_ADD

	if translate_y_if_possible != 0.0:
		var result = KinematicCollision3D.new()
		self.test_move(self.transform, Vector3(0, translate_y_if_possible, 0), result)
		self.position.y += result.get_travel().y
		%Head.position.y -= result.get_travel().y
		%Head.position.y = clampf(%Head.position.y, -CROUCH_SMALLER_MODEL, 0)

	# 4) Smooth head/camera transition every frame
	%Head.position.y = move_toward(%Head.position.y, -CROUCH_SMALLER_MODEL if is_crouched else 0, 7.0 * delta)

	# 5) Update collision shape height (based on is_crouched)
	$CollisionShape3D.shape.height = _original_player_height - CROUCH_SMALLER_MODEL if is_crouched else _original_player_height
	$CollisionShape3D.position.y = $CollisionShape3D.shape.height / 2

	# 6) Smooth visual scale
	var target_scale_y = 0.7 if is_crouched else 1.0
	%WorldModel.scale.y = lerp(%WorldModel.scale.y, target_scale_y, clamp(12.0 * delta, 0.0, 1.0))

@rpc("any_peer", "call_local", "reliable")
func _sync_crouch(crouched: bool):
	# This runs on all peers when anyone crouches
	if not is_multiplayer_authority():
		is_crouched = crouched
		# Update visual representation for other players
		var target_scale_y = 0.7 if is_crouched else 1.0
		%WorldModel.scale.y = target_scale_y
		
		# Update collision (important for hit detection)
		$CollisionShape3D.shape.height = (_original_player_height - CROUCH_SMALLER_MODEL) if is_crouched else _original_player_height
		$CollisionShape3D.position.y = $CollisionShape3D.shape.height / 2

func _on_touch_area_body_entered(body: Node) -> void:
	if not is_multiplayer_authority():
		return
	if team_id != TEAM_SEEKER:
		return

	var target_id := -1
	if body is CharacterBody3D and body.name.is_valid_int():
		target_id = body.name.to_int()
	if target_id == -1 or target_id == name.to_int():
		return

	# Find the Level node via group (set in level.gd)
	var level := get_tree().get_first_node_in_group("level")
	if level == null:
		return

	var my_id := name.to_int()
	if multiplayer.is_server():
		level.request_catch(my_id, target_id)               # call directly on server
	else:
		level.request_catch.rpc_id(1, my_id, target_id)      # ask host to validate

func _process(delta: float) -> void:
	# Fixed map spectate: pin camera high above and look down at center
	if is_spectating:
		%Camera3D.global_position = _spectate_fixed_pos
		return
		
	_update_footsteps(delta)
		
func _update_footsteps(delta: float) -> void:
	if _footsteps_sfx == null:
		return
	var on_ground := is_on_floor()
	if on_ground and self.velocity.length() > 0:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_footsteps_sfx.play()
			_step_timer = STEP_INTERVAL_WALK
	else:
		_step_timer = 0.0
