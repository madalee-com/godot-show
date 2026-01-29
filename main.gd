# Godot-show shows clips of streamers you shoutout on Twitch
# Copyright (C) 2026  Madalee

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

extends Control

## Logger instance
@onready var logger = %AppLogger

## Set to true when loading settings to prevent save loops.
var is_loading = false


## Called when the node enters the scene tree for the first time.
func _on_ready() -> void:
	## connect to logger signals
	logger.app_logger.log_message.connect(_log_message)
	## connect to twitch signals
	Twitch.token_handler_unauthenticated.connect(_on_token_handler_unauthenticated)
	load_settings()
	## Auto-connect to Twitch if enabled
	if %AutoConnect.button_pressed:
		twitch_setup()
	#Enable/Disable Forget Twitch buttons
	refresh_twitch_token_status()
	## Enable OBS connection
	%Obs.enable_connect()

func _on_token_handler_unauthenticated():
	refresh_twitch_token_status()

## Settings Load/Save
func load_settings() -> void:
	## Prevent save loops.
	is_loading = true
	# Load settings from file.
	var settings = ConfigFile.new()
	var err = settings.load(ProjectSettings.get_setting("application/config/settings_file"))
	# If the file didn't load, ignore it.
	if err != OK:
		is_loading = false
		return
	# Iterate over all sections of the settings file.
	for section in settings.get_sections():
		# Fetch the data for each section.
		var version = settings.get_value(section, "version")
		%AutoConnect.button_pressed = settings.get_value(section, "auto_connect", %AutoConnect.button_pressed)

		if float(version) >= 0.02:
			%ObsHost.text = settings.get_value(section, "obs_host", %ObsHost.text)
			_on_obs_host_text_changed(%ObsHost.text)
			%ObsPort.value = settings.get_value(section, "obs_port", %ObsPort.value)
			_on_obs_port_value_changed(%ObsPort.value)
			%ObsPassword.text = settings.get_value(section, "obs_password", %ObsPassword.text)
			_on_obs_password_text_changed(%ObsPassword.text)
			%ObsSourceName.text = settings.get_value(section, "obs_source_name", %ObsSourceName.text)
			_on_obs_source_name_text_changed(%ObsSourceName.text)
			%ObsScaleFilterName.text = settings.get_value(section, "obs_scale_filter_name", %ObsScaleFilterName.text)
			_on_obs_scale_filter_name_text_changed(%ObsScaleFilterName.text)
			%ClipMinWidth.value = settings.get_value(section, "clip_min_width", %ClipMinWidth.value)
			_on_clip_min_width_value_changed(%ClipMinWidth.value)
			%ClipMinHeight.value = settings.get_value(section, "clip_min_height", %ClipMinHeight.value)
			_on_clip_min_height_value_changed(%ClipMinHeight.value)
			%ClipMaxWidth.value = settings.get_value(section, "clip_max_width", %ClipMaxWidth.value)
			_on_clip_max_width_value_changed(%ClipMaxWidth.value)
			%ClipMaxHeight.value = settings.get_value(section, "clip_max_height", %ClipMaxHeight.value)
			_on_clip_max_height_value_changed(%ClipMaxHeight.value)
			%ScaleTime.value = settings.get_value(section, "scale_time", %ScaleTime.value)
			_on_scale_time_value_changed(%ScaleTime.value)
			%QueueDelay.value = settings.get_value(section, "queue_delay", %QueueDelay.value)
			_on_queue_delay_value_changed(%QueueDelay.value)
			%ClipClearDelay.value = settings.get_value(section, "clip_clear_delay", %ClipClearDelay.value)
			_on_clip_clear_delay_value_changed(%ClipClearDelay.value)

		if float(version) >= 0.03:
			%AnimationFramerate.value = settings.get_value(section, "scale_framerate", %AnimationFramerate.value)
			_on_animation_framerate_value_changed(%AnimationFramerate.value)

		if float(version) >= 0.04:
			%ObsOpacityFilterName.text = settings.get_value(section, "obs_opacity_filter_name", %ObsOpacityFilterName.text)
			_on_obs_opacity_filter_name_text_changed(%ObsOpacityFilterName.text)
			%ObsScale.button_pressed = settings.get_value(section, "obs_scale", %ObsScale.button_pressed)
			_on_obs_scale_toggled(%ObsScale.button_pressed)
			%ObsFadeIn.button_pressed = settings.get_value(section, "obs_fade_in", %ObsFadeIn.button_pressed)
			_on_obs_fade_in_toggled(%ObsFadeIn.button_pressed)
			%ObsFadeOut.button_pressed = settings.get_value(section, "obs_fade_out", %ObsFadeOut.button_pressed)
			_on_obs_fade_out_toggled(%ObsFadeOut.button_pressed)
			%FadeTime.value = settings.get_value(section, "fade_time", %FadeTime.value)
			_on_fade_time_value_changed(%FadeTime.value)
			%AnimationFramerate.value = settings.get_value(section, "animation_framerate", %AnimationFramerate.value)
			_on_animation_framerate_value_changed(%AnimationFramerate.value)
	## Re-enable saving.
	is_loading = false

## Save settings to file.
func save_settings() -> void:
	## Prevent saving while loading.
	if is_loading:
		return
	## Create a new config file.
	var settings = ConfigFile.new()
	var section = "main"
	settings.set_value(section, "version", ProjectSettings.get_setting("application/config/version"))
	settings.set_value(section, "auto_connect", %AutoConnect.button_pressed)
	settings.set_value(section, "obs_host", %ObsHost.text)
	settings.set_value(section, "obs_port", %ObsPort.value)
	settings.set_value(section, "obs_password", %ObsPassword.text)
	settings.set_value(section, "obs_source_name", %ObsSourceName.text)
	settings.set_value(section, "obs_scale_filter_name", %ObsScaleFilterName.text)
	settings.set_value(section, "clip_min_width", %ClipMinWidth.value)
	settings.set_value(section, "clip_min_height", %ClipMinHeight.value)
	settings.set_value(section, "clip_max_width", %ClipMaxWidth.value)
	settings.set_value(section, "clip_max_height", %ClipMaxHeight.value)
	settings.set_value(section, "scale_time", %ScaleTime.value)
	settings.set_value(section, "queue_delay", %QueueDelay.value)
	settings.set_value(section, "clip_clear_delay", %ClipClearDelay.value)
	settings.set_value(section, "animation_framerate", %AnimationFramerate.value)
	settings.set_value(section, "obs_opacity_filter_name", %ObsOpacityFilterName.text)
	settings.set_value(section, "obs_scale", %ObsScale.button_pressed)
	settings.set_value(section, "obs_fade_in", %ObsFadeIn.button_pressed)
	settings.set_value(section, "obs_fade_out", %ObsFadeOut.button_pressed)
	settings.set_value(section, "fade_time", %FadeTime.value)
	settings.set_value(section, "animation_framerate", %AnimationFramerate.value)
	## Save the settings to file.
	settings.save(ProjectSettings.get_setting("application/config/settings_file"))

func refresh_twitch_token_status():
	Twitch.auth.token.load_tokens()
	if Twitch.auth.token.is_token_valid():
		%ForgetTwitchLogin.disabled = false
	else:
		%ForgetTwitchLogin.disabled = true

## Twitch Setup
func twitch_setup() -> bool:
	logger.log("Attempting connection to Twitch")
	## Setup Twitch connection
	if await Twitch.setup():
		var user = await Twitch.get_current_user()
		logger.log_success("Connected to Twitch")
		%ForgetTwitchLogin.disabled = false
		## Subscribe to chat message events
		await Twitch.subscribe_event(
			TwitchEventsubDefinition.CHANNEL_CHAT_MESSAGE,
			{
				"broadcaster_user_id": user.id,
				"user_id": user.id,
			},
		)
		return true
	refresh_twitch_token_status()
	logger.log_error("Error connecting to Twitch")
	return false

func forget_twitch():
	#Twitch.eventsub.close_connection()
	await Twitch.unsetup()
	Twitch.auth.token.remove_tokens()
	refresh_twitch_token_status()

## Handle Twitch connect button
func _on_twitch_connect_pressed() -> void:
	twitch_setup()

## Logger handlers
func _log_message(message: String, _error: bool):
	logger.append_text("[code]" + logger.ansi_to_bbcode(message) + "[/code]")

func _log_error(
		_function: String,
		_file: String,
		_line: int,
		_code: String,
		_rationale: String,
		_editor_notify: bool,
		_error_type: int,
		_script_backtraces: Array[ScriptBacktrace],
):
	logger.log_error("[code]Error occured[/code]")

## UI Handlers
func _on_auto_connect_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_obs_host_text_changed(new_text: String) -> void:
	save_settings()
	%Obs.host = new_text
	%Obs.break_connection()


func _on_obs_port_value_changed(value: float) -> void:
	save_settings()
	%Obs.port = str(int(value))
	%Obs.break_connection()


func _on_obs_password_text_changed(new_text: String) -> void:
	save_settings()
	%Obs.password = new_text
	%Obs.break_connection()


func _on_obs_source_name_text_changed(new_text: String) -> void:
	save_settings()
	%Commands.source_name = new_text


func _on_obs_scale_filter_name_text_changed(new_text: String) -> void:
	save_settings()
	%Commands.source_filter_name = new_text


func _on_clip_min_width_value_changed(value: float) -> void:
	save_settings()
	%Commands.min_size.x = value


func _on_clip_min_height_value_changed(value: float) -> void:
	save_settings()
	%Commands.min_size.y = value


func _on_clip_max_width_value_changed(value: float) -> void:
	save_settings()
	%Commands.max_size.x = value


func _on_clip_max_height_value_changed(value: float) -> void:
	save_settings()
	%Commands.max_size.y = value


func _on_scale_time_value_changed(value: float) -> void:
	save_settings()
	%Commands.time_to_scale = value


func _on_fade_time_value_changed(value: float) -> void:
	save_settings()
	%Commands.time_to_fade = value


func _on_animation_framerate_value_changed(value: float) -> void:
	save_settings()
	%Commands.clip_frame_rate = value


func _on_queue_delay_value_changed(value: float) -> void:
	save_settings()
	%Commands.queue_delay = value


func _on_clip_clear_delay_value_changed(value: float) -> void:
	save_settings()
	%Commands.clip_end_delay = value


func _on_obs_opacity_filter_name_text_changed(new_text: String) -> void:
	save_settings()
	%Commands.fade_filter_name = new_text


func _on_obs_scale_toggled(toggled_on: bool) -> void:
	save_settings()
	%Commands.obs_scale = toggled_on


func _on_obs_fade_in_toggled(toggled_on: bool) -> void:
	save_settings()
	%Commands.fade_in = toggled_on


func _on_obs_fade_out_toggled(toggled_on: bool) -> void:
	save_settings()
	%Commands.fade_out = toggled_on


func _on_forget_twitch_login_pressed() -> void:
	forget_twitch()
