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

enum GrowSoundOptionIds {
	NONE,
	CUSTOM,
	SLIDE_WHISTLE,
	BALLOON,
}

## Set to true when loading settings to prevent save loops.
var is_loading = false

var custom_sound_set = false


## Called when the node enters the scene tree for the first time.
func _on_ready() -> void:
	if OS.get_name() == "Web":
		Twitch.auth.oauth_setting.authorization_flow = OAuth.AuthorizationFlow.DEVICE_CODE_FLOW
	## connect to logger signals
	logger.app_logger.log_message.connect(_log_message)
	## connect to twitch signals
	Twitch.auth.token_handler.unauthenticated.connect(_on_token_handler_unauthenticated)
	Twitch.auth.token_handler.token_resolved.connect(_on_token_resolved)
	Twitch.eventsub.event_received.connect(_on_twitch_eventsub_event)
	load_settings()
	## Auto-connect to Twitch if enabled
	if %AutoConnect.button_pressed:
		twitch_setup()
	#Enable/Disable Forget Twitch buttons
	refresh_twitch_token_status()
	## Enable OBS connection
	%Obs.enable_connect()


func _on_token_handler_unauthenticated():
	%TwitchConnect.disabled = false
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
		#version agnostic
		%CanSOViewer.button_pressed = settings.get_value(section, "can_so_viewer", %CanSOViewer.button_pressed)
		_on_can_so_viewer_toggled(%CanSOViewer.button_pressed)
		%CanSOVIP.button_pressed = settings.get_value(section, "can_so_vip", %CanSOVIP.button_pressed)
		_on_can_so_vip_toggled(%CanSOVIP.button_pressed)
		%CanSOSub.button_pressed = settings.get_value(section, "can_so_sub", %CanSOSub.button_pressed)
		_on_can_so_sub_toggled(%CanSOSub.button_pressed)
		%CanSOMod.button_pressed = settings.get_value(section, "can_so_mod", %CanSOMod.button_pressed)
		_on_can_so_mod_toggled(%CanSOMod.button_pressed)
		%CanSOLeadMod.button_pressed = settings.get_value(section, "can_so_lead_mod", %CanSOLeadMod.button_pressed)
		_on_can_so_lead_mod_toggled(%CanSOLeadMod.button_pressed)
		%CanSOStreamer.button_pressed = settings.get_value(section, "can_so_streamer", %CanSOStreamer.button_pressed)
		_on_can_so_streamer_toggled(%CanSOStreamer.button_pressed)
		%UseLinearAnimation.button_pressed = settings.get_value(section, "use_linear_animation", %UseLinearAnimation.button_pressed)
		_on_use_linear_animation_toggled(%UseLinearAnimation.button_pressed)
		%UseInflateAnimation.button_pressed = settings.get_value(section, "use_inflate_animation", %UseInflateAnimation.button_pressed)
		_on_use_inflate_animation_toggled(%UseInflateAnimation.button_pressed)
		%UseTVAnimation.button_pressed = settings.get_value(section, "use_tv_animation", %UseTVAnimation.button_pressed)
		_on_use_tv_animation_toggled(%UseTVAnimation.button_pressed)
		%GrowSoundPath.text = settings.get_value(section, "grow_sound_path", %GrowSoundPath.text)
		%GrowSoundSource.selected = %GrowSoundSource.get_item_index(settings.get_value(section, "grow_sound_source", %GrowSoundSource.get_selected_id()))
		set_grow_sound_from_id(%GrowSoundSource.get_selected_id())
		%UseRandomClipCmd.button_pressed = settings.get_value(section, "use_random_clip", %UseRandomClipCmd.button_pressed)
		%UseQueueSOCmd.button_pressed = settings.get_value(section, "use_queue_so", %UseQueueSOCmd.button_pressed)
		%UseSORandomClipCmd.button_pressed = settings.get_value(section, "use_so_random_clip", %UseSORandomClipCmd.button_pressed)
		%UseClipCmd.button_pressed = settings.get_value(section, "use_clip", %UseClipCmd.button_pressed)
		%UseRaiderClipCmd.button_pressed = settings.get_value(section, "use_raider_clip", %UseRaiderClipCmd.button_pressed)
		%UseRaiderSOCmd.button_pressed = settings.get_value(section, "use_raider_so", %UseRaiderSOCmd.button_pressed)
		%UseRaiderSORandomCmd.button_pressed = settings.get_value(section, "use_raider_so_random_clip", %UseRaiderSORandomCmd.button_pressed)
		%UseClipShowCmd.button_pressed = settings.get_value(section, "use_clip_show", %UseClipShowCmd.button_pressed)
		%UseStopClipShowCmd.button_pressed = settings.get_value(section, "use_stop_clip_show", %UseStopClipShowCmd.button_pressed)
		%UseSelfClipShowCmd.button_pressed = settings.get_value(section, "use_self_clip_show", %UseSelfClipShowCmd.button_pressed)
		%RandomClipCmd.text = settings.get_value(section, "random_clip_cmd", %RandomClipCmd.text)
		_on_random_clip_cmd_text_changed(%RandomClipCmd.text)
		%QueueSOCmd.text = settings.get_value(section, "queue_so_cmd", %QueueSOCmd.text)
		_on_queue_so_cmd_text_changed(%QueueSOCmd.text)
		%SORandomClipCmd.text = settings.get_value(section, "so_random_clip_cmd", %SORandomClipCmd.text)
		_on_so_random_clip_cmd_text_changed(%SORandomClipCmd.text)
		%ClipCmd.text = settings.get_value(section, "clip_cmd", %ClipCmd.text)
		_on_clip_cmd_text_changed(%ClipCmd.text)
		%RaiderClipCmd.text = settings.get_value(section, "raider_clip_cmd", %RaiderClipCmd.text)
		_on_raider_clip_cmd_text_changed(%RaiderClipCmd.text)
		%RaiderSOCmd.text = settings.get_value(section, "raider_so_cmd", %RaiderSOCmd.text)
		_on_raider_so_cmd_text_changed(%RaiderSOCmd.text)
		%RaiderSORandomCmd.text = settings.get_value(section, "raider_so_random_clip_cmd", %RaiderSORandomCmd.text)
		_on_raider_so_random_cmd_text_changed(%RaiderSORandomCmd.text)
		%ClipShowCmd.text = settings.get_value(section, "clip_show_cmd", %ClipShowCmd.text)
		_on_clip_show_cmd_text_changed(%ClipShowCmd.text)
		%StopClipShowCmd.text = settings.get_value(section, "stop_clip_show_cmd", %StopClipShowCmd.text)
		_on_stop_clip_show_cmd_text_changed(%StopClipShowCmd.text)
		%SelfClipShowCmd.text = settings.get_value(section, "self_clip_show_cmd", %SelfClipShowCmd.text)
		_on_self_clip_show_cmd_text_changed(%SelfClipShowCmd.text)

		

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
	settings.set_value(section, "can_so_viewer", %CanSOViewer.button_pressed)
	settings.set_value(section, "can_so_vip", %CanSOVIP.button_pressed)
	settings.set_value(section, "can_so_sub", %CanSOSub.button_pressed)
	settings.set_value(section, "can_so_mod", %CanSOMod.button_pressed)
	settings.set_value(section, "can_so_lead_mod", %CanSOLeadMod.button_pressed)
	settings.set_value(section, "can_so_streamer", %CanSOStreamer.button_pressed)
	settings.set_value(section, "use_linear_animation", %UseLinearAnimation.button_pressed)
	settings.set_value(section, "use_inflate_animation", %UseInflateAnimation.button_pressed)
	settings.set_value(section, "use_tv_animation", %UseTVAnimation.button_pressed)
	settings.set_value(section, "grow_sound_source", %GrowSoundSource.get_selected_id())
	settings.set_value(section, "grow_sound_path", %GrowSoundPath.text)
	settings.set_value(section, "use_linear_animation", %UseLinearAnimation.button_pressed)
	settings.set_value(section, "use_random_clip", %UseRandomClipCmd.button_pressed)
	settings.set_value(section, "use_queue_so", %UseQueueSOCmd.button_pressed)
	settings.set_value(section, "use_so_random_clip", %UseSORandomClipCmd.button_pressed)
	settings.set_value(section, "use_clip", %UseClipCmd.button_pressed)
	settings.set_value(section, "use_raider_clip", %UseRaiderClipCmd.button_pressed)
	settings.set_value(section, "use_raider_so", %UseRaiderSOCmd.button_pressed)
	settings.set_value(section, "use_raider_so_random_clip", %UseRaiderSORandomCmd.button_pressed)
	settings.set_value(section, "use_clip_show", %UseClipShowCmd.button_pressed)
	settings.set_value(section, "use_stop_clip_show", %UseStopClipShowCmd.button_pressed)
	settings.set_value(section, "use_self_clip_show", %UseSelfClipShowCmd.button_pressed)
	settings.set_value(section, "random_clip_cmd", %RandomClipCmd.text)
	settings.set_value(section, "queue_so_cmd", %QueueSOCmd.text)
	settings.set_value(section, "so_random_clip_cmd", %SORandomClipCmd.text)
	settings.set_value(section, "clip_cmd", %ClipCmd.text)
	settings.set_value(section, "raider_clip_cmd", %RaiderClipCmd.text)
	settings.set_value(section, "raider_so_cmd", %RaiderSOCmd.text)
	settings.set_value(section, "raider_so_random_clip_cmd", %RaiderSORandomCmd.text)
	settings.set_value(section, "clip_show_cmd", %ClipShowCmd.text)
	settings.set_value(section, "stop_clip_show_cmd", %StopClipShowCmd.text)
	settings.set_value(section, "self_clip_show_cmd", %SelfClipShowCmd.text)
	

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
	%TwitchConnect.disabled = true
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
		await Twitch.subscribe_event(
			TwitchEventsubDefinition.CHANNEL_RAID,
			{
				"to_broadcaster_user_id": user.id
			},
		)
		return true
	refresh_twitch_token_status()
	logger.log_error("Error connecting to Twitch")
	%TwitchConnect.disabled = false
	return false


func forget_twitch():
	await Twitch.unsetup()
	Twitch.auth.token.remove_tokens()
	refresh_twitch_token_status()
	%TwitchConnect.disabled = false


func _on_token_resolved(tokens) -> void:
	if tokens == null:
		%TwitchConnect.disabled = false


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


func _on_about_button_pressed() -> void:
	%AboutPanel.popup_centered()


func refresh_so_permissions() -> void:
	var flag = 0
	if %CanSOVIP.button_pressed:
		flag += TwitchCommandBase.PermissionFlag.VIP
	if %CanSOSub.button_pressed:
		flag += TwitchCommandBase.PermissionFlag.SUB
	if %CanSOMod.button_pressed:
		flag += TwitchCommandBase.PermissionFlag.MOD
	if %CanSOLeadMod.button_pressed:
		flag += TwitchCommandBase.PermissionFlag.LEAD_MOD
	if %CanSOStreamer.button_pressed:
		flag += TwitchCommandBase.PermissionFlag.STREAMER
	if %CanSOViewer.button_pressed:
		flag = 0
	for cur_cmd in $Commands.get_children():
		if cur_cmd.get_class() == "TwitchCommand":
			cur_cmd.permission_level = flag


func _on_can_so_viewer_toggled(_toggled_on: bool) -> void:
	if _toggled_on:
		%CanSOVIP.button_pressed = true
		%CanSOSub.button_pressed = true
		%CanSOMod.button_pressed = true
		%CanSOLeadMod.button_pressed = true
		%CanSOStreamer.button_pressed = true
	refresh_so_permissions()
	save_settings()


func _on_can_so_vip_toggled(_toggled_on: bool) -> void:
	if !_toggled_on:
		%CanSOViewer.button_pressed = false
	refresh_so_permissions()
	save_settings()


func _on_can_so_sub_toggled(_toggled_on: bool) -> void:
	if !_toggled_on:
		%CanSOViewer.button_pressed = false
	refresh_so_permissions()
	save_settings()


func _on_can_so_mod_toggled(_toggled_on: bool) -> void:
	if !_toggled_on:
		%CanSOViewer.button_pressed = false
	refresh_so_permissions()
	save_settings()


func _on_can_so_lead_mod_toggled(_toggled_on: bool) -> void:
	if !_toggled_on:
		%CanSOViewer.button_pressed = false
	refresh_so_permissions()
	save_settings()


func _on_can_so_streamer_toggled(_toggled_on: bool) -> void:
	if !_toggled_on:
		%CanSOViewer.button_pressed = false
	refresh_so_permissions()
	save_settings()


func _on_setup_obs_pressed() -> void:
	if %Obs.obs_connected:
		%OBSConfigPanel.popup_centered()
		%OBSConfigPanel.popup_window = false
		%OBSConfigPanel.exclusive = true
	else:
		%OBSWebsocketPanel.popup_centered()
		%OBSWebsocketPanel.popup_window = false
		%OBSWebsocketPanel.exclusive = true


func _on_use_inflate_animation_toggled(toggled_on: bool) -> void:
	validate_grow_animation_selection()
	save_settings()
	%Commands.use_inflate_animation = toggled_on


func _on_grow_sound_source_item_selected(_index: int) -> void:
	set_grow_sound_from_id(%GrowSoundSource.get_selected_id())
	if %GrowSoundSource.get_selected_id() != GrowSoundOptionIds.NONE:
		if %GrowSoundSource.get_selected_id() == GrowSoundOptionIds.CUSTOM and !custom_sound_set:
			return
		reset_grow_sound_pitches()
		%GrowSound.play()
	save_settings()


func set_grow_sound_from_id(id: int):
	if id == GrowSoundOptionIds.CUSTOM:
		%GrowSoundSelector.disabled = false
		%GrowSoundPath.editable = true
	else:
		%GrowSoundSelector.disabled = true
		%GrowSoundPath.editable = false

	%Commands.use_grow_sound = true
	match id:
		GrowSoundOptionIds.SLIDE_WHISTLE:
			%GrowSound.stream = AudioStreamOggVorbis.load_from_file("res://assets/audio/cartoon_whistle.ogg")
		GrowSoundOptionIds.BALLOON:
			%GrowSound.stream = AudioStreamOggVorbis.load_from_file("res://assets/audio/balloon-inflate.ogg")
		GrowSoundOptionIds.CUSTOM:
			set_custom_grow_sound()
		GrowSoundOptionIds.NONE:
			%Commands.use_grow_sound = false


func set_custom_grow_sound():
	if FileAccess.file_exists(%GrowSoundPath.text):
		if %GrowSoundPath.text.matchn("*ogg"):
			%GrowSound.stream = AudioStreamOggVorbis.load_from_file(%GrowSoundPath.text)
		elif %GrowSoundPath.text.matchn("*mp3"):
			%GrowSound.stream = AudioStreamMP3.load_from_file(%GrowSoundPath.text)
	else:
		%GrowSound.stream = null
	if %GrowSound.stream != null:
		custom_sound_set = true
		if %GrowSoundSource.get_selected_id() == GrowSoundOptionIds.CUSTOM:
			%Commands.use_grow_sound = true
	else:
		custom_sound_set = false
		%Commands.use_grow_sound = false


func _on_grow_sound_selector_pressed() -> void:
	%GrowSoundSelector/FileDialog.show()


func _on_file_dialog_file_selected(path: String) -> void:
	%GrowSoundPath.text = path
	set_custom_grow_sound()
	save_settings()
	if custom_sound_set:
		reset_grow_sound_pitches()
		%GrowSound.play()


func _on_grow_sound_path_text_changed(_new_text: String) -> void:
	save_settings()
	set_custom_grow_sound()
	if custom_sound_set:
		reset_grow_sound_pitches()
		%GrowSound.play()


func reset_grow_sound_pitches():
	var effectBus = AudioServer.get_bus_index("Effect")
	var effect: AudioEffectPitchShift = AudioServer.get_bus_effect(effectBus, 0)
	effect.pitch_scale = 1.0
	%GrowSound.pitch_scale = 1.0


func _on_use_linear_animation_toggled(toggled_on: bool) -> void:
	validate_grow_animation_selection()
	save_settings()
	%Commands.use_linear_animation = toggled_on


func _on_use_tv_animation_toggled(toggled_on: bool) -> void:
	validate_grow_animation_selection()
	save_settings()
	%Commands.use_tv_animation = toggled_on


func validate_grow_animation_selection():
	if is_loading:
		return
	if %UseLinearAnimation.button_pressed or %UseInflateAnimation.button_pressed or %UseTVAnimation.button_pressed:
		return
	%UseLinearAnimation.button_pressed = true


func _on_random_clip_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/RandomClip.command = new_text if new_text.left(1) != "!" else new_text.substr(1)


func _on_queue_so_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/Shoutout.command = new_text if new_text.left(1) != "!" else new_text.substr(1)


func _on_so_random_clip_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/SORandomClip.command = new_text if new_text.left(1) != "!" else new_text.substr(1)


func _on_clip_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/Clip.command = new_text if new_text.left(1) != "!" else new_text.substr(1)


func _on_raider_clip_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/RaiderRandomClip.command = new_text if new_text.left(1) != "!" else new_text.substr(1)


func _on_raider_so_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/RaiderSO.command = new_text if new_text.left(1) != "!" else new_text.substr(1)


func _on_raider_so_random_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/RaiderSORandomClip.command = new_text if new_text.left(1) != "!" else new_text.substr(1)


func _on_clip_show_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/ClipShow.command = new_text if new_text.left(1) != "!" else new_text.substr(1)


func _on_stop_clip_show_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/StopClipShow.command = new_text if new_text.left(1) != "!" else new_text.substr(1)

func _on_use_random_clip_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_use_queue_so_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_use_so_random_clip_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_use_clip_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_use_raider_clip_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_use_raider_so_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_use_raider_so_random_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_use_clip_show_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_use_stop_clip_show_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()

func _on_twitch_eventsub_event(data: TwitchEventsub.Event) -> void:
	if data.type == TwitchEventsubDefinition.CHANNEL_RAID:
		%Commands.recent_raider = data.data["user_name"]


func _on_use_self_clip_show_cmd_toggled(_toggled_on: bool) -> void:
	save_settings()


func _on_self_clip_show_cmd_text_changed(new_text: String) -> void:
	if new_text.is_empty():
		return
	save_settings()
	$Commands/SelfClipShow.command = new_text if new_text.left(1) != "!" else new_text.substr(1)
