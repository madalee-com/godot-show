extends Node

func _on_o_auth_device_code_requested(device_code: OAuth.OAuthDeviceCodeResponse) -> void:
	var err = OS.shell_open(device_code.verification_uri)
	if err != OK:
		push_error("Can't open browser cause of: ", error_string(err))
