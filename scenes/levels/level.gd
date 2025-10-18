extends Node3D

const PLAYER_SCENE := preload("res://scenes/player/FPSController.tscn")
const MAX_PLAYERS := 4
const ROUND_DURATION := 60  
const TOUCH_DISTANCE := 1.25

enum Team { HIDER, SEEKER } # HIDER=0, SEEKER=1

var teams: Dictionary = {}       
var players: Dictionary = {}      

var alive_hiders: Dictionary[int, bool] = {}
var alive_seekers: Dictionary[int, bool] = {}

var round_running: bool = false
var waiting_round: bool = false
var hider_streak: int = 0
var player_names: Dictionary = {} 

@onready var spawn_hiders: Node3D = get_node_or_null("SpawnHiders") as Node3D
@onready var spawn_seekers: Node3D = get_node_or_null("SpawnSeekers") as Node3D
@onready var _spawner: MultiplayerSpawner = %PlayerSpawner

func _enter_tree() -> void:
	multiplayer.root_path = get_path()

func _ready() -> void:
	add_to_group("level")  # so players can find the Level safely
	# Make RPC node paths relative to this Level on all peers
	get_tree().get_multiplayer().root_path = get_path()
	
	_spawner.spawn_function = Callable(self, "_spawn_player_from_spawner")
	
	# Server listens to timer end to decide winners / loop waiting rounds
	if multiplayer.is_server():
		if Global.round_manager and not Global.round_manager.round_ended.is_connected(_on_round_time_up):
			Global.round_manager.round_ended.connect(_on_round_time_up)
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_assign_and_spawn(1) # host
		_maybe_start_round()
		

@rpc("any_peer", "call_local")
func request_catch(seeker_id: int, hider_id: int) -> void:
	# Server validates the catch
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Allow local server calls (sender == 0) and client calls from the seeker
	if sender != 0 and sender != seeker_id:
		return

	# Validate teams from the authoritative teams dict
	if teams.get(seeker_id, -1) != Team.SEEKER: return
	if teams.get(hider_id, -1) != Team.HIDER: return

	var seeker := get_node_or_null(str(seeker_id)) as CharacterBody3D
	var hider := get_node_or_null(str(hider_id)) as CharacterBody3D
	if seeker == null or hider == null:
		return

	# Distance check
	if seeker.global_position.distance_to(hider.global_position) > TOUCH_DISTANCE:
		return

	_catch_hider(hider_id)

func _catch_hider(hider_id: int) -> void:
	if not alive_hiders.has(hider_id):
		return
	alive_hiders.erase(hider_id)
	show_round_result_on_clients.rpc("%s was caught!" % _name_of(hider_id))
	set_player_caught_on_clients.rpc(hider_id, true)
	start_map_spectate_on_client.rpc_id(hider_id, hider_id)
	_check_round_end_by_alive()

# runs on server and clients, guarantees identical path
func _spawn_player_from_spawner(data: Dictionary) -> Node:
	var id: int = int(data.get("id", 0))
	var team: int = int(data.get("team", Team.HIDER))
	var pos: Vector3 = data.get("pos", Vector3.ZERO)

	var player: CharacterBody3D = PLAYER_SCENE.instantiate()
	player.name = str(id)
	player.set_multiplayer_authority(id)

	#player.global_position = to_local(pos)
	player.set_deferred("global_position", pos)

	players[id] = player
	if player.has_method("set_team"):
		player.set_team(team)
	if team == Team.HIDER:
		alive_hiders[id] = true

	return player

# Rebalance to 50/50 (or as close as possible)
func _rebalance_teams() -> void:
	var ids: Array[int] = []
	for k in teams.keys():
		ids.append(int(k))
	ids.sort()
	var total: int = ids.size()
	if total == 0: return
	var target_seekers: int = int(total / 2) # 50/50 for even, floor for odd

	# Prefer keeping current seekers when possible
	var current_seekers: Array[int] = []
	var current_hiders: Array[int] = []
	for id in ids:
		if teams[id] == Team.SEEKER:
			current_seekers.append(id)
		else:
			current_hiders.append(id)

	# Trim or promote to hit target
	while current_seekers.size() > target_seekers:
		var moved: int = int(current_seekers.pop_back())
		teams[moved] = Team.HIDER
		current_hiders.append(moved)
	while current_seekers.size() < target_seekers and current_hiders.size() > 0:
		var moved: int = int(current_hiders.pop_front())
		teams[moved] = Team.SEEKER
		current_seekers.append(moved)

	# Rebuild alive hiders for current round logic
	_rebuild_alive_sets()

# Return team-ordered array and index of an id inside that team
func _team_ids(team: int) -> Array[int]:
	var arr: Array[int] = []
	for id in teams.keys():
		if teams[id] == team:
			arr.append(int(id))
	arr.sort()
	return arr

func _team_index_of(id: int, team: int) -> int:
	var arr: Array[int] = _team_ids(team)
	return arr.find(id)

# Golden-angle offset so teammates don’t stack
func _spawn_offset_for_index(idx: int) -> Vector3:
	var angle := float(idx) * 2.39996323
	var radius := 0.8 + 0.3 * float(idx)  # spread slightly with index
	return Vector3(cos(angle), 0.0, sin(angle)) * radius

# Compute final spawn using your base spawn point + offset per team index
func _spawn_pos_for(team: int, id: int) -> Vector3:
	var base: Vector3 = _get_spawn_position_for_team(team)
	var idx: int = _team_index_of(id, team)
	return base + _spawn_offset_for_index(max(0, idx))

func _assign_and_spawn(id: int) -> void:
	# Balance to 50/50 on join
	var seekers := 0
	for t in teams.values():
		if t == Team.SEEKER:
			seekers += 1
	var total_after_join := teams.size() + 1
	var target_seekers := float(total_after_join / 2)
	var team: int = (Team.SEEKER if seekers < target_seekers else Team.HIDER)
	teams[int(id)] = team

	# Ensure global balance (handles fast joins)
	_rebalance_teams()

	# Spawn with per-team offset so players don’t stack
	var spawn_pos := _spawn_pos_for(team, id)
	if multiplayer.is_server():
		_spawner.spawn({"id": id, "team": team, "pos": spawn_pos})

func _on_peer_connected(id: int) -> void:
	# Enforce max players (including host)
	if teams.size() >= MAX_PLAYERS:
		if multiplayer.multiplayer_peer and multiplayer.multiplayer_peer.has_method("disconnect_peer"):
			multiplayer.multiplayer_peer.disconnect_peer(id, 2000)
		return
	_assign_and_spawn(id)
	_maybe_start_round()                    # now exists
	request_name.rpc_id(id) # prompt the new peer to send its name

# When a peer disconnects, despawn their node via spawner
func _on_peer_disconnected(id: int) -> void:
	alive_hiders.erase(id)
	alive_seekers.erase(id)
	teams.erase(id)
	var node := players.get(id, null) as CharacterBody3D
	if node and is_instance_valid(node) and multiplayer.is_server():
		node.queue_free()
	players.erase(id)
	_cleanup_orphans()
	_check_round_end_by_alive()
	_maybe_start_round()

# Decide which round to run (waiting vs real), or stop rounds
func _maybe_start_round() -> void:
	var has_seeker := false
	var has_hider := false
	for t in teams.values():
		if t == Team.SEEKER: has_seeker = true
		if t == Team.HIDER: has_hider = true

	# If both teams exist, ensure a real round is running
	if has_seeker and has_hider:
		if waiting_round and multiplayer.is_server():
			Global.round_manager.stop_round()
			_respawn_everyone()
		if not round_running or waiting_round:
			_start_round()
		return

	# Otherwise: run/loop a waiting round if at least one player is here
	if teams.size() >= 1:
		if not round_running:
			_respawn_everyone()
			_start_waiting_round()
		return

	if round_running and multiplayer.is_server():
		Global.round_manager.stop_round()
	round_running = false
	waiting_round = false

func _cleanup_orphans() -> void:
	for child in get_children():
		if child is CharacterBody3D:
			if not child.name.is_valid_int() or int(child.name) not in teams:
				child.queue_free()

func _get_spawn_position_for_team(team: int) -> Vector3:
	if team == Team.SEEKER:
		return spawn_seekers.global_position
	else:
		return spawn_hiders.global_position
	
func _check_round_end_by_alive() -> void:
	# No hiders alive -> seekers win
	if alive_hiders.size() == 0:
		_end_round_seekers_win()
		return
	# No seekers alive -> hiders win
	if alive_seekers.size() == 0:
		_end_round_hiders_win()
		return

# Rebuild the alive players.
func _rebuild_alive_sets() -> void:
	alive_hiders.clear()
	alive_seekers.clear()
	for k in teams.keys():
		var id := int(k)
		var t: int = teams[id]
		if t == Team.HIDER:
			alive_hiders[id] = true
		elif t == Team.SEEKER:
			alive_seekers[id] = true

# Apply team locally on each peer and move to spawn (authority moves itself)
@rpc("authority", "call_local")
func _apply_team_and_spawn(id: int, team: int, pos: Vector3) -> void:
	var p := get_node_or_null(str(id)) as CharacterBody3D
	if p:
		if p.has_method("set_team"):
			p.set_team(team)
		if p.has_method("reset_spawn_state"):
			p.reset_spawn_state()
		# Show team/task info on the local authority's HUD
		if p.is_multiplayer_authority() and p.has_node("Hud"):
			var hud: Control = p.get_node("Hud")
			if hud and hud.has_method("show_spawn_info"):
				var color := Color(0.25, 0.6, 1.0) if team == Team.SEEKER else Color(1.0, 0.3, 0.25)
				var task := "Find and catch the hiders" if team == Team.SEEKER else "Hide and avoid being caught"
				hud.show_spawn_info("You are a %s. %s" % ["Seeker" if team == Team.SEEKER else "Hider", task], color)
		p.set_deferred("global_position", global_transform.origin) # fix spawn bug
		p.set_deferred("global_position", pos)

@rpc("any_peer", "call_local")
func _apply_team_visual_on_clients(id: int, team: int) -> void:
	var p := get_node_or_null(str(id)) as CharacterBody3D
	if p and p.has_method("set_team"):
		p.set_team(team)

# Helper: broadcast visuals for everyone
func _broadcast_team_visuals() -> void:
	for id in teams.keys():
		_apply_team_visual_on_clients.rpc(id, teams[id])

func _respawn_everyone() -> void:
	# Ensure any spectating UI/mode is cleared on clients before respawn
	for id in teams.keys():
		stop_spectate_on_client.rpc_id(id, id)
	# Update team visuals on ALL peers first
	_rebuild_alive_sets()
	_broadcast_team_visuals()
	
	await get_tree().process_frame
	# Ensure everyone is visible/interactive again after being caught in the last round
	for id in teams.keys():
		set_player_caught_on_clients.rpc(int(id), false)
	# Then ask each authority to teleport to its unique team-offset spawn
	for id in teams.keys():
		var team: int = teams[id]
		var pos := _spawn_pos_for(team, id)
		if has_node(str(id)):
			_apply_team_and_spawn.rpc_id(id, id, team, pos)
		else:
			if multiplayer.is_server():
				_spawner.spawn({"id": id, "team": team, "pos": pos})

func _start_round() -> void:
	waiting_round = false
	round_running = true
	if multiplayer.is_server():
		Global.round_manager.start_round(ROUND_DURATION)
	show_round_result_on_clients.rpc("Round started!")

func _start_waiting_round() -> void:
	waiting_round = true
	round_running = true
	if multiplayer.is_server():
		Global.round_manager.start_round(ROUND_DURATION)
	show_round_result_on_clients.rpc("Waiting for players...")

func _on_round_time_up() -> void:
	if not round_running:
		return
	if waiting_round:
		# Loop waiting round: respawn and restart until both teams exist
		_respawn_everyone()
		_start_waiting_round()
		return
	# Real round: time up => hiders win
	_end_round_hiders_win()

func _end_round_seekers_win() -> void:
	# Flip flags first so time-up callback won't mis-label the result
	round_running = false
	waiting_round = false
	if multiplayer.is_server():
		Global.round_manager.stop_round()
	hider_streak = 0
	show_round_result_on_clients.rpc("Seekers won!")
	%SeekersWonSFX.play()
	_swap_teams_and_restart()

func _end_round_hiders_win() -> void:
	# Flip flags first so time-up callback won't mis-label the result
	round_running = false
	waiting_round = false
	if multiplayer.is_server():
		Global.round_manager.stop_round()
	hider_streak += 1
	show_round_result_on_clients.rpc("Hiders won! Streak: %d" % hider_streak)
	%HidersWonSFX.play()
	_restart_same_teams()

func _swap_teams_and_restart() -> void:
	for id in teams.keys():
		teams[id] = Team.HIDER if teams[id] == Team.SEEKER else Team.SEEKER
	_rebuild_alive_sets()
	await get_tree().process_frame
	_respawn_everyone()
	_maybe_start_round()

func _restart_same_teams() -> void:
	_rebuild_alive_sets()
	await get_tree().process_frame
	_respawn_everyone()
	_maybe_start_round()
	
# Server tells a viewer to spectate from a fixed map vantage
@rpc("any_peer")
func start_map_spectate_on_client(id: int) -> void:
	var pos := Vector3(25, 15.0, 20)
	var look_at := Vector3(0, 0, 0)
	var p: CharacterBody3D = players.get(id, null)
	p.start_map_spectating(pos, look_at)
	
@rpc("any_peer")
func stop_spectate_on_client(id: int) -> void:
	var p: CharacterBody3D = players.get(id, null)
	p.stop_spectating()
	
@rpc("any_peer")
func request_out_of_bounds(id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != id:
		return
	var team : int = teams.get(id, -1)

	show_round_result_on_clients.rpc("%s fell off the map!" % _name_of(id))
	# Eliminate and start fixed map spectate
	if team == Team.HIDER:
		if alive_hiders.has(id):
			alive_hiders.erase(id)
	else:
		if alive_seekers.has(id):
			alive_seekers.erase(id)
	set_player_caught_on_clients.rpc(id, true)

	start_map_spectate_on_client.rpc_id(id, id) 

	_check_round_end_by_alive()

# Make these message/caught RPCs execute on every peer (not just authority)
@rpc("any_peer", "call_local")
func set_player_caught_on_clients(id: int, caught: bool) -> void:
	var p: CharacterBody3D = players.get(id, null)
	p.set_caught(caught)

@rpc("any_peer", "call_local")
func show_round_result_on_clients(text: String) -> void:
	# Show on the local authoritative player's HUD on each peer
	for child in get_children():
		if child is CharacterBody3D and child.is_multiplayer_authority():
			if child.has_node("Hud"):
				var hud: Control = child.get_node("Hud")
				if hud and hud.has_method("show_round_banner"):
					hud.show_round_banner(text)

# Client -> Server: send my name
@rpc("any_peer")
func register_name(name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	name = name.strip_edges().substr(0, 20)
	player_names[sender] = (name if name != "" else "Player%d" % sender)
	# Broadcast mapping to everyone
	set_name_for_peer.rpc(sender, player_names[sender])

# Server -> Everyone: store mapping locally
@rpc("authority", "call_local")
func set_name_for_peer(id: int, name: String) -> void:
	player_names[id] = name

# Server -> Client: ask this peer to send its name
@rpc("authority", "call_local")
func request_name() -> void:
	if multiplayer.is_server():
		return
	register_name.rpc_id(1, Global.display_name)

func _name_of(id: int) -> String:
	return player_names.get(id, "Player %d" % id)
