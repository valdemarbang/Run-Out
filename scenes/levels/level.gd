extends Node3D

const PLAYER_SCENE := preload("res://scenes/player/FPSController.tscn")
const MAX_PLAYERS := 4
const ROUND_DURATION := 20  # seconds
const WAITING_ROUND_DURATION := 20
const TOUCH_DISTANCE := 1.25

enum Team { HIDER, SEEKER } # HIDER=0, SEEKER=1

var teams: Dictionary = {}        # peer_id -> Team
var players: Dictionary = {}      # peer_id -> CharacterBody3D
var alive_hiders: Dictionary = {} # Set[int] = true for hiders still alive
var round_running: bool = false
var waiting_round: bool = false
var hider_streak: int = 0

@onready var spawn_hiders: Node3D = get_node_or_null("SpawnHiders") as Node3D
@onready var spawn_seekers: Node3D = get_node_or_null("SpawnSeekers") as Node3D

var _spawner: MultiplayerSpawner

func _enter_tree() -> void:
	multiplayer.root_path = get_path()

func _ready() -> void:
	add_to_group("level")  # so players can find the Level safely
	# Make RPC node paths relative to this Level on all peers
	get_tree().get_multiplayer().root_path = get_path()

	# Create a spawner that the server uses to replicate player nodes
	_spawner = MultiplayerSpawner.new()
	_spawner.name = "_PlayerSpawner"
	_spawner.spawn_path = NodePath("..")  # spawn players as children of Level
	_spawner.spawn_function = Callable(self, "_spawn_player_from_spawner")
	add_child(_spawner)

	# Server listens to timer end to decide winners / loop waiting rounds
	if multiplayer.is_server():
		if Global.round_manager and not Global.round_manager.round_ended.is_connected(_on_round_time_up):
			Global.round_manager.round_ended.connect(_on_round_time_up)
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_assign_and_spawn(1) # host
		_maybe_start_round()
	# Clients no longer need to request existing players; the spawner syncs them
	# else:
	# 	request_existing_players.rpc_id(1)

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

	# Show a banner for everyone
	show_round_result_on_clients.rpc("Player %s was caught!" % str(hider_id))

	# Despawn hider on all peers (no collisions linger)
	_despawn_player(hider_id)

	# If no hiders left, seekers win
	if alive_hiders.size() == 0:
		_end_round_seekers_win()

func _despawn_player(id: int) -> void:
	# Free only on the server; MultiplayerSpawner will replicate the despawn
	var node := players.get(id, null) as CharacterBody3D
	if node and is_instance_valid(node) and multiplayer.is_server():
		node.queue_free()
	players.erase(id)
	alive_hiders.erase(id)

func _setup_sync_nodes(player: Node, id: int) -> void:
	var ss := player.get_node_or_null("ServerSynchronizer") as MultiplayerSynchronizer
	if ss:
		ss.root_path = NodePath("..")
		ss.set_multiplayer_authority(id)
	var pi := player.get_node_or_null("PlayerInput") as MultiplayerSynchronizer
	if pi:
		pi.root_path = NodePath(".")
		pi.set_multiplayer_authority(id)

# Spawner's factory: runs on server and clients, guarantees identical path
func _spawn_player_from_spawner(data: Dictionary) -> Node:
	var id: int = int(data.get("id", 0))
	var team: int = int(data.get("team", Team.HIDER))
	var pos: Vector3 = data.get("pos", Vector3.ZERO)

	var player: CharacterBody3D = PLAYER_SCENE.instantiate()
	player.name = str(id)
	player.set_multiplayer_authority(id)
	_setup_sync_nodes(player, id)

	# Initial placement (safe since Level is identity)
	player.transform.origin = pos

	players[id] = player
	if player.has_method("set_team"):
		player.set_team(team)
	if team == Team.HIDER:
		alive_hiders[id] = true

	return player

func _assign_and_spawn(id: int) -> void:
	var team: int = _pick_team()            # typed
	teams[id] = team
	# Compute spawn here and pass to all peers via spawner
	var spawn_pos := _get_spawn_position_for_team(team)
	if multiplayer.is_server():
		_spawner.spawn({"id": id, "team": team, "pos": spawn_pos})

# Decide team (ensure at least one seeker)
func _pick_team() -> int:
	var seeker_count := 0
	for t in teams.values():
		if t == Team.SEEKER:
			seeker_count += 1
	# Ensure at least one seeker; otherwise assign hider
	return Team.SEEKER if seeker_count == 0 else Team.HIDER

func _spawn_or_reposition_player(team: int, id: int) -> void:
	# Not used for initial spawns; kept for compatibility if you call it elsewhere
	if has_node(str(id)):
		var p := get_node(str(id)) as CharacterBody3D
		players[id] = p
		_setup_sync_nodes(p, id)
		var offset := Vector3(randf() - 0.5, 0.0, randf() - 0.5) * 0.6
		p.global_position = _get_spawn_position_for_team(team) + offset
		if p.has_method("reset_spawn_state"):
			p.call_deferred("reset_spawn_state")
		return
	# If called by mistake, fall back to real spawn
	_assign_and_spawn(id)

func _on_peer_connected(id: int) -> void:
	# Enforce max players (including host)
	if teams.size() >= MAX_PLAYERS:
		if multiplayer.multiplayer_peer and multiplayer.multiplayer_peer.has_method("disconnect_peer"):
			multiplayer.multiplayer_peer.disconnect_peer(id, 2000)
		return
	_assign_and_spawn(id)
	_maybe_start_round()                    # now exists

# When a peer disconnects, despawn their node via spawner
func _on_peer_disconnected(id: int) -> void:
	alive_hiders.erase(id)
	teams.erase(id)
	var node := players.get(id, null) as CharacterBody3D
	if node and is_instance_valid(node) and multiplayer.is_server():
		node.queue_free()
	players.erase(id)
	_cleanup_orphans()
	_maybe_start_round()                    # now exists

# Remove this if it's no longer used anywhere
@rpc("authority", "call_local")
func remove_player_on_clients(id: int) -> void:
	# Deprecated: we now despawn by freeing on the server
	if has_node(str(id)):
		get_node(str(id)).queue_free()

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
			# Transition from waiting to real round
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

	# No players: stop any running round
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
		if spawn_seekers and spawn_seekers.is_inside_tree():
			return spawn_seekers.global_position
		return Vector3(6, 2, 0)
	if spawn_hiders and spawn_hiders.is_inside_tree():
		return spawn_hiders.global_position
	return Vector3(0, 2, 0)

# Rebuild the authoritative set of alive hiders from teams
func _rebuild_alive_hiders() -> void:
	alive_hiders.clear()
	for id in teams.keys():
		if teams[id] == Team.HIDER:
			alive_hiders[id] = true

# Apply team locally on each peer and move to spawn (authority moves itself)
@rpc("authority", "call_local")
func _apply_team_and_spawn(id: int, team: int, pos: Vector3) -> void:
	var p := get_node_or_null(str(id)) as CharacterBody3D
	if p:
		if p.has_method("set_team"):
			p.set_team(team)
		p.global_position = pos
		if p.has_method("reset_spawn_state"):
			p.reset_spawn_state()

# NEW: apply team visuals on all peers (not authority-restricted)
@rpc("any_peer", "call_local")
func _apply_team_visual_on_clients(id: int, team: int) -> void:
	var p := get_node_or_null(str(id)) as CharacterBody3D
	if p and p.has_method("set_team"):
		p.set_team(team)

# Helper: broadcast visuals for everyone
func _broadcast_team_visuals() -> void:
	for id in teams.keys():
		_apply_team_visual_on_clients.rpc(id, teams[id])

# Respawn: re-spawn missing players, update team + position for existing ones
func _respawn_everyone() -> void:
	_cleanup_orphans()
	await get_tree().process_frame
	# Update team visuals on ALL peers first
	_broadcast_team_visuals()
	# Then ask each authority to teleport to its spawn
	for id in teams.keys():
		var team: Team = teams[id]
		var pos := _get_spawn_position_for_team(team)
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
		Global.round_manager.start_round(WAITING_ROUND_DURATION)
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
	if multiplayer.is_server():
		Global.round_manager.stop_round()
	round_running = false
	waiting_round = false
	hider_streak = 0
	show_round_result_on_clients.rpc("Seekers won!")
	_swap_teams_and_restart()

func _end_round_hiders_win() -> void:
	if multiplayer.is_server():
		Global.round_manager.stop_round()
	round_running = false
	waiting_round = false
	hider_streak += 1
	show_round_result_on_clients.rpc("Hiders won! Streak: %d" % hider_streak)
	_restart_same_teams()

func _swap_teams_and_restart() -> void:
	for id in teams.keys():
		teams[id] = Team.HIDER if teams[id] == Team.SEEKER else Team.SEEKER
	_rebuild_alive_hiders()
	_respawn_everyone()
	_maybe_start_round()

func _restart_same_teams() -> void:
	_rebuild_alive_hiders()
	_respawn_everyone()
	_maybe_start_round()

# Make these message/caught RPCs execute on every peer (not just authority)
@rpc("any_peer", "call_local")
func set_player_caught_on_clients(id: int, caught: bool) -> void:
	var p: CharacterBody3D = players.get(id, null)
	if p and p.has_method("set_caught"):
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
