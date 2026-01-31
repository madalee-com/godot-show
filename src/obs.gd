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
signal input_settings_set
## Emitted when source filter has been successfully enabled
signal source_filter_enabled
## Emitted when media input playback starts
signal media_input_playback_started(event_data: Dictionary)
## Emitted when media input playback ends
signal media_input_playback_ended(event_data: Dictionary)
## Emitted when source filter settings have been successfully set
signal source_filter_settings_set
## Emitted when there is an error setting input settings
signal set_input_settings_error
## Emitted when there is an error enabling source filter
signal source_filter_enable_error
## Emitted when there is an error getting source filter
signal get_source_filter_error
## Emitted when there is an error setting source filter settings
signal source_filter_settings_error
## Emitted when source filter data is received
signal got_source_filter
## Emitted when media input status is received
signal got_media_input_status(media_state, media_duration, media_cursor)
## Emitted when input settings are received
signal got_input_settings(input_settings: Dictionary)
## Emitted when default input settings are received
signal got_input_default_settings(input_settings: Dictionary)

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


## Called when the connection to OBS is established
func _on_connection_established() -> void:
	if password == null or password == "":
		obs_connected = true
		obs_disconnected = false
		logger.log_success("Connection to OBS established")


## Called when the connection to OBS is authenticated
func _on_connection_authenticated() -> void:
	if password != null and password != "":
		obs_connected = true
		obs_disconnected = false
		logger.log_success("Connection to OBS established")


## Called when the connection to OBS is closed
## This will attempt to re-establish the connection after a delay.
func _on_connection_closed() -> void:
	obs_connected = false
	if not obs_disconnected:
		logger.log_warn("OBS connection closed, will re-attempt each second until reconnected.")
		obs_disconnected = true
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
		self.OpCodeEnums.WebSocketOpCode.RequestResponse.IDENTIFIER_VALUE:
			var resp: RequestResponse = data
			if resp["d"].requestStatus.result:
				match resp.request_type:
					"SetInputSettings":
						input_settings_set.emit()
					"SetSourceFilterEnabled":
						source_filter_enabled.emit()
					"SetSourceFilterSettings":
						source_filter_settings_set.emit()
					"GetInputDefaultSettings":
						got_input_default_settings.emit(resp["d"])
					"GetInputSettings":
						got_input_settings.emit(resp["d"])
					"GetSourceFilter":
						got_source_filter.emit(resp["d"].responseData)
					"GetMediaInputStatus":
						got_media_input_status.emit(resp["d"].responseData.mediaState, resp["d"].responseData.mediaDuration, resp["d"].responseData.mediaCursor)
			else:
				logger.log("Got error from OBS: %s" % resp["d"].requestStatus.comment)
				match resp.request_type:
					"SetInputSettings":
						set_input_settings_error.emit()
					"SetSourceFilterEnabled":
						source_filter_enable_error.emit()
					"SetSourceFilterSettings":
						source_filter_settings_error.emit()
					"GetSourceFilter":
						get_source_filter_error.emit()


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
