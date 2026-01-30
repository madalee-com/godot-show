extends PopupPanel


func _on_ready() -> void:
	%VersionLabel.text = "Version: v%s" % ProjectSettings.get_setting("application/config/version")

func _on_about_close_pressed() -> void:
	hide()
