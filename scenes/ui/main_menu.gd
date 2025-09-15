extends Control

@onready var start_button = $VBoxContainer/Start

func _ready() -> void:
	start_button.disabled = not GameState.tutorial_completed
	
func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/levels/MainGame.tscn")

func _on_tutorial_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/levels/Tutorial.tscn")
	
func _on_options_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/options_menu.tscn")
	
func _on_exit_pressed() -> void:
	get_tree().quit()
