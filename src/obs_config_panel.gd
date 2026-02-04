extends PopupPanel

@onready var logger = %AppLogger
@onready var obs = %Obs
@onready var commands = %Commands

func _on_obs_config_close_pressed() -> void:
	hide()
