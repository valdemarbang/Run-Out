extends Control

const PORT = 5000

func _ready():
	# Connect to multiplayer signals
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

func _on_tutorial_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/levels/Tutorial.tscn")
	
func _on_options_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/options_menu.tscn")
	
func _on_exit_pressed() -> void:
	get_tree().quit()

func _on_host_mode_pressed() -> void:
	print("host mode pressed")
	var peer = ENetMultiplayerPeer.new()
	peer.create_server(PORT)
	multiplayer.multiplayer_peer = peer
	start_game()
	
func start_game():
	# Both server and client should change scene
	get_tree().change_scene_to_file("res://scenes/levels/Tutorial.tscn")

func change_level(scene: PackedScene):
	# Changes level, but cleans up everything before changing scene.
	var level = $Level
	for c in level.get_children():
		level.remove_child(c)
		c.queue_free()
	level.add_child(scene.instantiate())
	
func _on_connect_client_pressed() -> void:
	print("client mode pressed")
	var ip = "127.0.0.1"
	var peer = ENetMultiplayerPeer.new()
	peer.create_client(ip, PORT)
	multiplayer.multiplayer_peer = peer
	# Don't call start_game() here - wait for connection confirmation

func _on_connected_to_server():
	print("Successfully connected to server!")
	start_game()

func _on_connection_failed():
	print("Failed to connect to server")
	multiplayer.multiplayer_peer = null
