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

## Override of obs-websocket-gd to add signals for certain events and responses
extends "res://addons/obs-websocket-gd/obs_websocket.gd"

const UUIDUtil = preload('res://addons/gd_uuid/uuid.gd') ## Used to send unique request IDs to OBS

const MediaInputStates := {
	OBS_MEDIA_STATE_NONE = "OBS_MEDIA_STATE_NONE",
	OBS_MEDIA_STATE_PLAYING = "OBS_MEDIA_STATE_PLAYING",
	OBS_MEDIA_STATE_OPENING = "OBS_MEDIA_STATE_OPENING",
	OBS_MEDIA_STATE_BUFFERING = "OBS_MEDIA_STATE_BUFFERING",
	OBS_MEDIA_STATE_PAUSED = "OBS_MEDIA_STATE_PAUSED",
	OBS_MEDIA_STATE_STOPPED = "OBS_MEDIA_STATE_STOPPED",
	OBS_MEDIA_STATE_ENDED = "OBS_MEDIA_STATE_ENDED",
	OBS_MEDIA_STATE_ERROR = "OBS_MEDIA_STATE_ERROR",
}

## Signals
## Emitted when input settings have been successfully set
signal input_settings_set(event_data)
## Emitted when source filter has been successfully enabled
signal source_filter_enabled(event_data)
## Emitted when media input playback starts
signal media_input_playback_started(event_data)
## Emitted when media input playback ends
signal media_input_playback_ended(event_data)
## Emitted when source filter settings have been successfully set
signal source_filter_settings_set(event_data)
## Emitted when source filter data is received
signal got_source_filter(event_data)
## Emitted when media input status is received
signal got_media_input_status(event_data)
## Emitted when input settings are received
signal got_input_settings(event_data)
## Emitted when default input settings are received
signal got_input_default_settings(event_data)
## Emitted when a scene item transform changes
signal scene_item_transform_changed(event_data: Dictionary)
## Emitted when scene item ID is received
signal got_scene_item_id(event_data)
## Emitted when scene item transform data is received
signal got_scene_item_transform(event_data)
## Emitted when scene list is received
signal got_scene_list(event_data)
## Emitted when scene item list is received
signal got_scene_item_list(event_data)
## Emitted when group list is received
signal got_group_list(event_data)
## Emitted when group scene item list is received
signal got_group_scene_item_list(event_data)
## Emitted when a new input is created
signal created_input(event_data)
## Emitted when a new source filter is created
signal created_source_filter(event_data)

## Logger instance
@onready var logger = %AppLogger

## OBS Connection State
var obs_connected = false
## After OBS first connects, if it disconnects, we set this to true
## to prevent multiple log messages about reconnection attempts.
## Once reconnected, it is reset to false.
var obs_disconnected = false
## Time in seconds between OBS connection retries
var obs_retry_time = 1.0
var obs_web_socket_note_shown = false


## Called when the connection to OBS is established
func _on_connection_established() -> void:
	if password == null or password == "":
		set_obs_connected()


## Called when the connection to OBS is authenticated
func _on_connection_authenticated() -> void:
	if password != null and password != "":
		set_obs_connected()


## Called when the connection to OBS is closed
func _on_connection_closed() -> void:
	%SetupOBS.show()
	obs_connected = false

	if not obs_disconnected:
		logger.log_warn("OBS connection closed, will re-attempt each second until reconnected.")
		obs_disconnected = true
	else:
		if !obs_web_socket_note_shown:
			%OBSWebsocketPanel.popup_centered()
			%OBSWebsocketPanel.popup_window = false
			%OBSWebsocketPanel.exclusive = true
			obs_web_socket_note_shown = true
	await get_tree().create_timer(obs_retry_time).timeout
	establish_connection()


## Called when data is received from OBS
## The base OBS class doesn't implement signals for many events so we catch them here and emit our own signals.
func _on_data_received(data: ServerObsMessage) -> void:
	match data.op:
		self.OpCodeEnums.WebSocketOpCode.Event.IDENTIFIER_VALUE:
			var event: Event = data
			match event.event_type:
				"MediaInputPlaybackStarted":
					media_input_playback_started.emit(event.event_data)
				"MediaInputPlaybackEnded":
					media_input_playback_ended.emit(event.event_data)
				"SceneItemTransformChanged":
					scene_item_transform_changed.emit(event.event_data)
		self.OpCodeEnums.WebSocketOpCode.RequestResponse.IDENTIFIER_VALUE:
			var resp: RequestResponse = data
			var success = false
			if resp["d"].requestStatus.result:
				success = true
			match resp.request_type:
				"SetInputSettings":
					if success:
						input_settings_set.emit(true)
					else:
						input_settings_set.emit(false)
				"SetSourceFilterEnabled":
					if success:
						source_filter_enabled.emit(true)
					else:
						source_filter_enabled.emit(false)
				"SetSourceFilterSettings":
					if success:
						source_filter_settings_set.emit(true)
					else:
						source_filter_settings_set.emit(false)
				"GetInputDefaultSettings":
					if success:
						got_input_default_settings.emit(resp["d"])
					else:
						got_input_default_settings.emit(false)
				"GetInputSettings":
					if success:
						got_input_settings.emit(resp["d"])
					else:
						got_input_settings.emit(false)
				"GetSourceFilter":
					if success:
						got_source_filter.emit(resp["d"].responseData)
					else:
						got_source_filter.emit(false)
				"GetSceneList":
					if success:
						got_scene_list.emit(resp["d"].responseData.scenes)
					else:
						got_scene_list.emit(false)
				"GetSceneItemList":
					if success:
						got_scene_item_list.emit(resp["d"].responseData.sceneItems)
					else:
						got_scene_item_list.emit(false)
				"GetSceneItemId":
					if success:
						got_scene_item_id.emit(resp["d"].responseData.sceneItemId)
					else:
						got_scene_item_id.emit(false)
				"GetSceneItemTransform":
					if success:
						got_scene_item_transform.emit(resp["d"].responseData.sceneItemTransform)
					else:
						got_scene_item_transform.emit(false)
				"GetMediaInputStatus":
					if success:
						got_media_input_status.emit(resp["d"].responseData)
					else:
						got_media_input_status.emit(false)
				"CreateInput":
					if success:
						created_input.emit(resp["d"].responseData)
					else:
						created_input.emit(false)
				"CreateSourceFilter":
					if success:
						created_source_filter.emit(true)
					else:
						created_source_filter.emit(false)
				"GetGroupList":
					if success:
						got_group_list.emit(resp["d"].responseData.groups)
					else:
						got_group_list.emit(false)
				"GetGroupSceneItemList":
					if success:
						got_group_scene_item_list.emit(resp["d"].responseData.sceneItems)
					else:
						got_group_scene_item_list.emit(false)


## Sets the OBS connected state to true and performs related actions.
## This function is called when the connection to OBS is established or authenticated.
func set_obs_connected():
	obs_connected = true
	obs_disconnected = false
	## Hide the OBS Websocket panel and SetupOBS panel.
	%OBSWebsocketPanel.hide()
	%SetupOBS.hide()
	logger.log_success("Connection to OBS established")


## Enables the OBS connection, with logging
## While enabled, will attempt to reconnect if the connection is lost.
func enable_connect():
	if not obs_disconnected:
		logger.log("Attempting connection to OBS")
	establish_connection()


### Function: set_input_settings(input_name : String, input_settings : Dictionary) ###
## Set the input settings for a specific input in OBS.
##
## @param input_name The name of the media input to set settings for.
## @param input_settings A dictionary of key-value pairs representing the new input settings.
func set_input_settings(input_name: String, input_settings: Dictionary):
	send_command(
		"SetInputSettings",
		{
			"inputName": input_name,
			"inputSettings": input_settings,
		},
		UUIDUtil.v7(),
	)


### Function: get_input_settings(input_name : String) ###
## Get the input settings for a specific input in OBS.
##
## @param input_name The name of the media input to get settings for.
func get_input_settings(input_name: String):
	send_command(
		"GetInputSettings",
		{
			"inputName": input_name,
		},
		UUIDUtil.v7(),
	)


### Function: get_input_settings(input_name : String) ###
## Get the default input settings for a specific input in OBS.
##
## @param input_name The name of the media input to get settings for.
func get_input_default_settings(input_kind: String):
	send_command(
		"GetInputDefaultSettings",
		{
			"inputKind": input_kind,
		},
		UUIDUtil.v7(),
	)


### Function: set_source_filter_settings(source_name : String, filter_name : String, filter_settings : Dictionary) ###
## Set the filter settings for a specific filter on a source in OBS.
##
## @param source_name The name of the source containing the filter.
## @param filter_name The name of the filter to set settings for.
## @param filter_settings A dictionary of key-value pairs representing the new filter settings.
func set_source_filter_settings(source_name: String, filter_name: String, filter_settings: Dictionary):
	send_command(
		"SetSourceFilterSettings",
		{
			"sourceName": source_name,
			"filterName": filter_name,
			"filterSettings": filter_settings,
		},
		UUIDUtil.v7(),
	)


### Function: set_source_filter_enabled(source_name : String, filter_name : String, filter_enabled : bool) ###
## Set the enabled state for a specific filter on a source in OBS.
##
## @param source_name The name of the source containing the filter.
## @param filter_name The name of the filter to enable or disable.
## @param filter_enabled A boolean indicating whether the filter should be enabled (true) or disabled (false).
func set_source_filter_enabled(source_name: String, filter_name: String, filter_enabled: bool):
	send_command(
		"SetSourceFilterEnabled",
		{
			"sourceName": source_name,
			"filterName": filter_name,
			"filterEnabled": filter_enabled,
		},
		UUIDUtil.v7(),
	)


## Retrieves the settings for a specific filter on a source in OBS.
##
## @param source_name The name of the source containing the filter.
## @param filter_name The name of the filter to get settings for.
func get_source_filter(source_name: String, filter_name: String):
	send_command(
		"GetSourceFilter",
		{
			"sourceName": source_name,
			"filterName": filter_name,
		},
		UUIDUtil.v7(),
	)


## Retrieves the settings for a specific filter on a source in OBS.
##
## @param input_name The name of the media input to get the status of.
func get_media_input_status(source_name: String):
	send_command(
		"GetMediaInputStatus",
		{
			"inputName": source_name,
		},
		UUIDUtil.v7(),
	)


## Retrieves the ID of a scene item in OBS.
##
## @param scene_name The name of the scene containing the item.
## @param source_name The name of the source item within the scene.
func get_scene_item_id(scene_name: String, source_name: String):
	send_command(
		"GetSceneItemId",
		{
			"sceneName": scene_name,
			"sourceName": source_name,
		},
		UUIDUtil.v7(),
	)


## Retrieves the transform properties of a scene item in OBS.
##
## @param scene_name The name of the scene containing the item.
## @param scene_item_id The ID of the scene item within the scene.
func get_scene_item_transform(scene_name: String, scene_item_id: float):
	send_command(
		"GetSceneItemTransform",
		{
			"sceneName": scene_name,
			"sceneItemId": scene_item_id,
		},
		UUIDUtil.v7(),
	)


## Retrieves the list of scenes in OBS.
func get_scene_list():
	send_command(
		"GetSceneList",
	)


## Retrieves the list of scene items in a specific scene in OBS.
##
## @param scene_name The name of the scene to retrieve items from.
func get_scene_item_list(scene_name: String):
	send_command(
		"GetSceneItemList",
		{
			"sceneName": scene_name,
		},
	)

## Retrieves the list of scenes in OBS.
func get_group_list():
	send_command(
		"GetGroupList",
	)


## Retrieves the list of scene items in a specific group in OBS.
##
## @param scene_name The name of the group to retrieve items from.
func get_group_scene_item_list(group_name: String):
	send_command(
		"GetGroupSceneItemList",
		{
			"sceneName": group_name,
		},
	)

## Creates a new media input source for a specific scene item.
##
## @param scene_name The name of the scene to add an input to.
## @param source_name The name of the source that will be used as the input in OBS.
func create_media_input(scene_name: String, source_name: String):
	send_command(
		"CreateInput",
		{
			"sceneName": scene_name,
			"inputName": source_name,
			"inputKind": "ffmpeg_source",
			"inputSettings": {
				"is_local_file": false,
				"clear_on_media_end": false,
				"restart_on_activate": false,
			},
			"sceneItemEnabled": true,
		},
	)


## Creates a new filter for an existing source in OBS.
##
## @param source_name The name of the source to add a filter to.
## @param filter_name The desired name for the new filter.
## @param filter_kind The kind of filter to create (e.g., "image", "color_correction").
func create_source_filter(source_name: String, filter_name: String, filter_kind: String):
	## Send a command to OBS to create a new filter on the specified source.
	send_command(
		"CreateSourceFilter",
		{
			"sourceName": source_name,
			"filterName": filter_name,
			"filterKind": filter_kind,
		},
	)
