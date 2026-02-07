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
extends Node

const HttpUtil = preload("res://addons/twitcher/lib/http/http_util.gd")
const TWITCH_VIDEO_API_CLIENT = "kd1unb4b3q4t58fwlpcbzcbnm76a8fp"
const TWITCH_VIDEO_API_HASH = "36b89d2507fce29e5ca551df756d27c1cfe079e2609642b4390aa4c35796eb11"

signal bad_clip_state
signal clip_started
signal clip_ended

@onready var logger = %AppLogger
@onready var obs = %Obs

## Queue to hold clips waiting to be played
var clip_queue = []
## Flag indicating if a clip is currently playing
var clip_playing = false
## Flag indicating if clip resizing animation is in progress
var clip_resizing = false
## Flag indicating if clip fade-in animation is in progress
var clip_fading_in = false
## Flag indicating if clip fade-out animation is in progress
var clip_fading_out = false
## Currently playing clip
var current_clip: TwitchClip = null
## Name of the OBS source to use for displaying clips
var source_name = 'Godot-Show'
## Name of the source filter for scaling/aspect ratio
var source_filter_name = 'Scaling/Aspect Ratio'
## Name of the fade filter
var fade_filter_name = 'Color Correction'
## Flag to enable/disable OBS scaling
var obs_scale = true
## Flag to enable/disable fade-in animation
var fade_in = true
## Flag to enable/disable fade-out animation
var fade_out = true
## Minimum size for clip display
var min_size = Vector2(1, 1)
## Maximum size for clip display
var max_size = Vector2(800, 450)
## Current size of the clip display
var cur_size = min_size
## Time in seconds to scale from min to max size
var time_to_scale = 2.0
## Time in seconds to fade in/out
var time_to_fade = 1.0
## Frame rate for clip playback
var clip_frame_rate = 60.0
## Delay between queue processing
var queue_delay = 1.0
## Delay after clip playback ends
var clip_end_delay = 1.5
## Frame time accumulator
var frame_time = 0.0
## Time elapsed during resize animation
var resize_time_elapsed = 0.0
## Flag indicating if initial size has been set
var clip_initial_size_set = false
## Flag indicating if initial fade has been set
var clip_initial_fade_set = false
## Time elapsed during fade animation
var fade_time_elapsed = 0.0
## Current opacity value
var cur_opacity = 0.0
## Previous state of the media input
var last_media_state = null
## Current aspect ratio of the clip
var cur_clip_ratio = 0.0
## Current scene item ID of the clip
var cur_scene_item_id = -1.0
## Current scene name where the clip is displayed
var cur_scene_name = ""
## Whether or not the obs config popup has been shown this session
var obs_config_popup_shown = false
# Flag indicating whether the OBS scaling filter is available
var has_scale_filter = false
# Flag indicating whether the OBS fade filter is available
var has_fade_filter = false
# The name of the first scene encountered, used for initial configuration
var first_scene_name = ""
# Flag indicating whether OBS has been successfully configured
var obs_configured = false
# Flag indicating whether an OBS configuration error message has already been shown
var obs_config_error_shown = false
# Flag indicating whether to wait for a clip transform before conisdering playback to be started
var wait_for_clip_transform = false

var user_clips = { }

var try_clip_play = false


## Main process function that handles frame timing and animation updates
func _process(delta: float) -> void:
	# Update frame time and process animations if enough time has
	# passed since last animation process
	frame_time += delta
	if frame_time < (1 / clip_frame_rate):
		return
	# we're going to reset the frame time, so store the total time elapsed
	# since the last animation process, for the animations to use
	delta = frame_time
	frame_time = 0.0
	process_animations(delta)


## Handles the shoutout command from Twitch
func _on_shoutout_command_received(
		_from_username: String,
		_info: TwitchCommandInfo,
		args: PackedStringArray,
) -> void:
	logger.log("Shoutout triggered")
	# Get a random clip from the specified user
	var clip = await get_random_clip_url(args[0])
	if clip != null:
		# Add the clip to the queue
		clip_queue.append(clip)
		logger.log(
			"Added clip to queue: \"%s\" from %s clipped by %s"
			% [clip.title, clip.broadcaster_name, clip.creator_name],
		)
		# If the queue is not currently processing, start it
		process_queue()


## Handles the resetting variables if the clip is in an unexpected state
func _on_bad_clip_state() -> void:
	logger.log_error("Bad clip state, sending back to queue.")
	reset_playback()


## Handles clip ended event
func _on_clip_ended() -> void:
	clip_playing = false
	# reset resizing state
	clip_resizing = false
	# prepare and start the fade process
	clip_initial_fade_set = false
	clip_fading_out = fade_out
	# fading is handled in the animation thread so it will start
	# on it's own, we wait here for the fade animation to complete
	await get_tree().create_timer(clip_end_delay).timeout
	# once the clip no longer shows on the screen, remove it from
	# the media source to prevent looping playback
	clear_clip()
	if obs_scale:
		obs.set_source_filter_enabled(source_name, source_filter_name, false)
		await obs.source_filter_enabled
	# if the clip queue has more clips, play them after a timeout
	if not clip_queue.is_empty():
		await get_tree().create_timer(queue_delay).timeout
		process_queue()


## This function finds the scene and source ID for the clip to be displayed.
## It retrieves the scene list from OBS, then iterates through the scenes
## to find the one that contains the source with the name 'Godot-Show'.
## If the source is not found within a scene, it attempts to configure OBS
## if it hasn't been configured already, and returns false.
## The function returns true if the scene and source ID are successfully found.
func find_scene_and_source_id() -> bool:
	# Get the scene list from OBS
	obs.get_scene_list()
	# Wait for the scene list to be received
	var scene_list = false
	var group_list = false
	var tries = 0
	# Retry up to 5 times if the scene list is not yet available
	while typeof(scene_list) != TYPE_ARRAY and tries < 5:
		tries += 1
		scene_list = await obs.got_scene_list
	# If we've tried too many times, check if OBS is configured
	if tries >= 5:
		check_obs_config()
		return false
	# Get the group list from OBS
	obs.get_group_list()
	# Retry up to 5 times if the scene list is not yet available
	while typeof(group_list) != TYPE_ARRAY and tries < 5:
		tries += 1
		group_list = await obs.got_group_list
	# Reset the scene item ID and scene name
	cur_scene_item_id = -1.0
	cur_scene_name = ""
	# Try to find the source within scenes up to 5 times
	tries = 0
	while (cur_scene_name == "" or cur_scene_item_id == -1.0) and tries < 5:
		# Iterate through each scene in the scene list
		for cur_scene in scene_list:
			tries += 1
			# Get the scene item list for the current scene
			obs.get_scene_item_list(cur_scene.sceneName)
			# Wait for the scene item list to be received
			var scene_item_list = await obs.got_scene_item_list
			# Skip if the scene item list is not yet available
			if typeof(scene_item_list) != TYPE_ARRAY:
				continue
			# Search for the source with the name 'Godot-Show'
			var i = scene_item_list.find_custom(func(e): return e.sourceName == source_name)
			# If found, set the scene item ID and scene name
			if i > -1:
				cur_scene_item_id = scene_item_list[i].sceneItemId
				cur_scene_name = cur_scene.sceneName
				return true
	tries = 0
	while (cur_scene_name == "" or cur_scene_item_id == -1.0) and tries < 5:
		if group_list == []:
			tries = 5
			break
		# Iterate through each scene in the group list
		for cur_scene in group_list:
			tries += 1
			# Get the group item list for the current scene
			obs.get_group_scene_item_list(cur_scene)
			# Wait for the scene item list to be received
			var scene_item_list = await obs.got_group_scene_item_list
			# Skip if the scene item list is not yet available
			if typeof(scene_item_list) != TYPE_ARRAY:
				continue
			# Search for the source with the name 'Godot-Show'
			var i = scene_item_list.find_custom(func(e): return e.sourceName == source_name)
			# If found, set the scene item ID and scene name
			if i > -1:
				cur_scene_item_id = scene_item_list[i].sceneItemId
				cur_scene_name = cur_scene
				return true
	# If we didn't find the source, check if OBS is configured
	check_obs_config()
	return false


## Handles clip started event
func _on_clip_started() -> void:
	# Re-enable the scale filter so we can start scaling
	if obs_scale:
		obs.set_source_filter_enabled(source_name, source_filter_name, true)
		if (await obs.source_filter_enabled == false):
			return

	# Restart the media timer with a slower rate now that we are only checkng
	# for bad or missed state changes
	%OBSMediaTimer.start(1.0)
	clip_initial_size_set = false
	clip_resizing = obs_scale
	clip_initial_fade_set = false
	clip_fading_in = fade_in


## Handles OBS media input ended event
func _on_obs_media_input_playback_ended(event_data: Dictionary) -> void:
	# only handle events for the correct source
	if event_data["inputName"] == source_name:
		_on_clip_ended()


## Handles OBS input settings set event
func _on_obs_input_settings_set(result) -> void:
	if !result:
		logger.log_error("Failed to set clip, sending back to queue.")
		reset_playback()
		return
	# once we are sure that the clip has been set, we can clear it from
	# the app
	if current_clip == null:
		return
	current_clip = null
	wait_for_clip_transform = true
	# Restart the media timer at a higher rate so we can start animations
	# as soon as the clip actually starts playing
	%OBSMediaTimer.start(0.05)


## Handles source filter settings error
func _on_source_filter_settings_set(result) -> void:
	# if we fail to set the filter, we need to reset state so the next
	# attempt will work
	if typeof(result) == TYPE_BOOL:
		reset_animations()


## Check the status of the media source.
## This is needed as we could miss a message and because the states that OBS
## sends aren't truly representative of if the clip is truly playing
func _on_obs_media_timer_timeout() -> void:
	if obs.obs_connected:
		if obs_configured:
			obs.get_media_input_status(source_name)
		elif %OBSMediaTimer.wait_time >= 1.0:
			if !await check_obs_config():
				popup_obs_config_if_needed()


## Handles the media input status response from OBS
## This is used to determine if the media source is actually playing
## We can't rely on the state alone as it doesn't always update correctly
## and we need to make sure the media is actually playing
##
## This waits the media to play passed the 0 position before triggering
## the play animation.
##
## @param media_state - The play state of the media input
## @param media_duration - The duration of the clip
## @param media_cursor - The cursor position of the clip
func _on_obs_got_media_input_status(result) -> void:
	if typeof(result) == TYPE_BOOL:
		check_obs_config()
		return
	if result.mediaState == null:
		return
	var media_state = result.mediaState
	if result.mediaDuration == null:
		result.mediaDuration = 0.0
	var media_duration = result.mediaDuration
	if result.mediaCursor == null:
		result.mediaCursor = 0.0
	var media_cursor = result.mediaCursor
	# Check if media is playing
	# Even if the state says it's playing, if the media_duration is 0.0, it's not actually loaded
	# Furthermore if the cursor isn't beyond 0.0, we can't be sure the clip is ready to actually play
	if media_state == obs.MediaInputStates.OBS_MEDIA_STATE_PLAYING and media_duration > 0.0 and media_cursor > 0.0 and cur_clip_ratio != 0.0:
		# If state goes from buffering to playing then start animations
		if !clip_playing:
			clip_playing = true
			try_clip_play = false
			emit_signal("clip_started") # Signal that a clip has started playing
		last_media_state = media_state
		return
	# If we're here, the clip isn't playing
	# If we think a clip is playing, then reset playback
	if !clip_queue.is_empty() and clip_playing:
		emit_signal("bad_clip_state")
	# Check if we're going from playing to not playing
	if clip_playing:
		emit_signal("clip_ended") # Signal that a clip has stopped playing
	clip_playing = false
	last_media_state = media_state


## Resets playback to the previous clip and restarts queue processing
func reset_playback():
	clip_playing = false
	try_clip_play = false
	if current_clip != null:
		clip_queue.insert(0, current_clip)
	current_clip = null
	await get_tree().create_timer(queue_delay).timeout
	process_queue()


## Resets all animations and states
func reset_animations():
	clip_resizing = false
	clip_initial_size_set = false
	resize_time_elapsed = 0.0
	cur_size = min_size
	cur_opacity = 0.0 if clip_fading_in else 1.0
	clip_fading_in = false
	clip_fading_out = false
	fade_time_elapsed = 0.0


## Animates the scaling of the clip display
func animate_scale(delta: float) -> void:
	# only animate once clip resizing has been started
	if not clip_resizing:
		return
	# if we haven't set the starting size, do so immediately
	# and then exit and wait for the next process time
	if not clip_initial_size_set:
		resize_time_elapsed = 0.0
		cur_size = min_size
		scale_source(cur_size.x, cur_size.y)
		clip_initial_size_set = true
		return

	var maxWidth = max_size.x
	var maxHeight = max_size.y
	if cur_clip_ratio >= 1:
		maxHeight = maxWidth / cur_clip_ratio
	else:
		maxWidth = maxHeight * cur_clip_ratio

	# if we have reached the maximum size, stop animating
	if cur_size.x >= maxWidth and cur_size.y >= maxHeight:
		resize_time_elapsed = 0.0
		clip_resizing = false
		return
	# keep track of the total time spent on the resize animation
	resize_time_elapsed += delta
	# calculate the new size based on the elapsed time
	if cur_size.x < maxWidth:
		var progress_ratio = resize_time_elapsed / time_to_scale
		cur_size.x = min_size.x + ((maxWidth - min_size.x) * progress_ratio)
		if cur_size.x > maxWidth:
			cur_size.x = maxWidth
	if cur_size.y < maxHeight:
		var progress_ratio = resize_time_elapsed / time_to_scale
		cur_size.y = min_size.y + ((maxHeight - min_size.y) * progress_ratio)
		if cur_size.y > maxHeight:
			cur_size.y = maxHeight
	# scale the source to the new size
	scale_source(cur_size.x, cur_size.y)


## Animates the fade effect of the clip display
func animate_fade(delta: float) -> void:
	# only fade once fading in or out has been started
	if not (clip_fading_in or clip_fading_out):
		return
	# if we haven't set the initial fade values, do so now
	# then exit and wait for the next animation process
	if not clip_initial_fade_set:
		fade_time_elapsed = 0.0
		cur_opacity = 0.0 if clip_fading_in else 1.0
		fade_source(cur_opacity)
		clip_initial_fade_set = true
		return
	# if we are done fading, stop the animation and reset values
	if (clip_fading_in and cur_opacity >= 1.0) or (clip_fading_out and cur_opacity <= 0.0):
		fade_time_elapsed = 0.0
		clip_fading_in = false
		clip_fading_out = false
		clip_initial_fade_set = false
		return
	# keep track of the total time spent fading
	fade_time_elapsed += delta
	# calculate the new opacity based on the fade time and
	# fade duration
	if clip_fading_in:
		if cur_opacity < 1.0:
			var progress_ratio = fade_time_elapsed / time_to_fade
			cur_opacity = progress_ratio
			if cur_opacity > 1.0:
				cur_opacity = 1.0
	if clip_fading_out:
		if cur_opacity > 0.0:
			var progress_ratio = fade_time_elapsed / time_to_fade
			cur_opacity = 1.0 - progress_ratio
			if cur_opacity <= 0.0:
				cur_opacity = 0.0
	# set the opacity of the source in OBS
	fade_source(cur_opacity)


## Processes all animations (scale and fade)
func process_animations(delta: float) -> void:
	animate_scale(delta)
	animate_fade(delta)


## Scales the source in OBS to the specified width and height.
## @param w The target width.
## @param h The target height.
func scale_source(w: int, h: int):
	if not obs_scale:
		return
	if obs.obs_connected and obs_configured:
		obs.set_source_filter_settings(
			source_name,
			source_filter_name,
			{
				"resolution": "%dx%d" % [w, h],
			},
		)


## Sets the opacity of the fade filter in OBS.
## @param opacity The target opacity value (0.0 to 1.0).
func fade_source(opacity: float):
	if not (fade_in or fade_out):
		return
	if obs.obs_connected and obs_configured:
		obs.set_source_filter_settings(source_name, fade_filter_name, { "opacity": opacity })


## Enables a specified source filter for the current source.
##
## @param filter_name - The name of the filter to enable.
func enable_source_filter(filter_name: String):
	if obs.obs_connected and obs_configured and obs_scale:
		obs.set_source_filter_enabled(source_name, filter_name, true)


## Processes the clip queue by playing the next clip if available.
## Waits for OBS to be ready before attempting to play.
## Does nothing if the queue is empty or if a clip is already playing.
func process_queue():
	if try_clip_play:
		return
	# If OBS isn't fully ready, then try again after the queue timer time
	if !obs.obs_connected or !obs_configured:
		await get_tree().create_timer(queue_delay).timeout
		process_queue()
		return
	# If the queue is empty or a clip is already playing, do nothing
	if clip_queue.is_empty() or clip_playing:
		return
	# Play the next clip from the queue
	play_clip(clip_queue.pop_front())


## This function plays a Twitch clip by setting the OBS input settings to the clip's URL.
## It also initializes the clip's playback and animation settings.
##
## Arguments:
## clip: A TwitchClip object representing the clip to be played.
##
## Example:
## play_clip(clip)
func play_clip(clip: TwitchClip):
	if try_clip_play:
		return
	try_clip_play = true
	logger.log(
		"Playing clip: \"%s\" from %s clipped by %s"
		% [clip.title, clip.broadcaster_name, clip.creator_name],
	)
	current_clip = clip
	# Find the scene and source, incase it somehow changed
	if await find_scene_and_source_id() == false:
		logger.log_error("Failed to find scene and source!")
		reset_playback()
		return
	# Disable the scale filter so that we can get the original resolution
	if obs_scale:
		# First we get the source filter to see if it even needs to be disabled
		obs.get_source_filter(source_name, source_filter_name)
		var source_filter = await obs.got_source_filter
		# Only continue if we actually got the source filter
		if typeof(source_filter) == TYPE_DICTIONARY:
			if source_filter.filterEnabled:
				# Enable the source filter
				obs.set_source_filter_enabled(source_name, source_filter_name, false)
				# Wait till the message goes through, if it fails just continue
				if await obs.source_filter_enabled:
					var event_data
					# Set a 2 second time to call our signal just incase OBS never calls it
					get_tree().create_timer(2.0).timeout.connect(
						func():
							obs.source_filter_enable_state_changed.emit({ "sourceName": cur_scene_item_id })
					)
					# Wait for till we get the event for the proper source or skip if the timer times out
					while true:
						event_data = await obs.source_filter_enable_state_changed
						if event_data.sourceName == source_name:
							break

	# Set the clip URL
	obs.set_input_settings(source_name, { "input": clip.url, "is_local_file": false })


## Shows the OBS configuration panel if it hasn't been shown yet and OBS isn't configured.
## This function is typically called when OBS connection fails or configuration is missing.
func popup_obs_config_if_needed():
	if !obs_config_popup_shown:
		if !obs_configured:
			obs_config_popup_shown = true
			%OBSConfigPanel.popup_centered()
			%OBSConfigPanel.popup_window = false
			%OBSConfigPanel.exclusive = true


## This function clears the current clip by setting the OBS input settings to an empty string.
func clear_clip():
	if obs.obs_connected and obs_configured:
		obs.set_input_settings(source_name, { "input": "" })


## This function retrieves a random clip URL for a given Twitch username.
## It fetches the user's information, then retrieves a list of their clips.
## It selects a random clip from the list and fetches the clip's access token.
## The function returns a TwitchClip object containing the clip's information.
##
## Arguments:
## username: A string representing the Twitch username.
##
## Returns:
## A TwitchClip object containing the clip's information, or null if no clips are found.
##
## Example:
## var clip = get_random_clip_url("twitchuser")
func get_random_clip_url(username: String) -> TwitchClip:
	# Log the start of the clip retrieval process
	logger.log("Getting clip for user: %s" % username)

	if !user_clips.has(username):
		# Fetch the Twitch user information for the given username
		var so_user: TwitchUser
		so_user = await Twitch.get_user(username)

		# Fetch a list of clips for the user
		var clips: TwitchGetClips.Response
		var clip_options = TwitchGetClips.Opt.from_json(
			{
				"broadcaster_id": so_user.id,
				"first": 100,
			},
		)
		clips = await Twitch.api.get_clips(clip_options)

		# If no clips are found, return null
		if clips.data.is_empty():
			return null
		user_clips[username] = { "unplayed": clips.data, "played": [] }

	# Pick a random clip from the list
	if user_clips[username].unplayed.is_empty():
		user_clips[username].unplayed = user_clips[username].played
	var clip = user_clips[username].unplayed.pick_random()
	user_clips[username].unplayed.erase(clip)
	user_clips[username].played.append(clip)

	# Create a request to get the clip's access token
	# this doesn't use the standard Twitch API, this is the GraphQL API
	var req: BufferedHTTPClient.RequestData = Twitch.api.client.request(
		"https://gql.twitch.tv/gql",
		HTTPClient.METHOD_POST,
		{ "Content-Type": "application/json", "Client-ID": TWITCH_VIDEO_API_CLIENT },
		JSON.stringify(
			{
				"operationName": "VideoAccessToken_Clip",
				"variables": { "slug": clip.id },
				"extensions": {
					"persistedQuery": {
						"version": 1,
						"sha256Hash": TWITCH_VIDEO_API_HASH,
					},
				},
			},
		),
	)

	# Wait for the response from the Twitch API
	var res: BufferedHTTPClient.ResponseData = await Twitch.api.client.wait_for_request(req)

	# If the request was successful, parse the response and construct the clip URL
	if res.response_code == 200:
		var parsed = JSON.parse_string(res.response_data.get_string_from_utf8())

		var clip_url = parsed.data.clip.videoQualities[0].sourceURL + "?token=%s&sig=%s" % [
			parsed.data.clip.playbackAccessToken.value.uri_encode(),
			parsed.data.clip.playbackAccessToken.signature.uri_encode(),
		]
		clip.url = clip_url
		return clip

	return null


## Checks the OBS configuration to ensure the required source and filters are set up correctly.
## This function verifies that:
## 1. The scene list is available
## 2. The source exists in one of the scenes
## 3. The required filters (scale and fade) exist on the source
## It also updates the UI with configuration suggestions if issues are found.
## The function returns true if the configuration is valid, false otherwise.
func check_obs_config() -> bool:
	# Initialize variables to track the current scene, scene item ID, and filter status
	cur_scene_name = ""
	cur_scene_item_id = -1.0
	has_scale_filter = false
	has_fade_filter = false
	first_scene_name = ""

	# Request the list of scenes from OBS
	obs.get_scene_list()

	# Wait for the scene list to be retrieved, with a maximum of 5 attempts
	var scene_list = false
	var tries = 0
	while typeof(scene_list) != TYPE_ARRAY and tries < 5:
		tries += 1
		scene_list = await obs.got_scene_list
	# Request the list of groups from OBS
	obs.get_group_list()

	# Wait for the group list to be retrieved, with a maximum of 5 attempts
	var group_list = false
	tries = 0
	while typeof(group_list) != TYPE_ARRAY and tries < 5:
		tries += 1
		group_list = await obs.got_group_list
	if typeof(scene_list) != TYPE_ARRAY:
		# If we couldn't get the scene list after 5 attempts, log an error
		if !obs_config_error_shown:
			logger.log_error("Couldn't get the scene list after 5 tries")
			obs_config_error_shown = true
	else:
		# If we successfully got the scene list, loop through each scene to find our source
		tries = 0
		while (cur_scene_name == "" or cur_scene_item_id == -1.0) and tries < 5:
			if scene_list == []:
				logger.log_error("OBS scene list is empty")
				return false
			# Loop through each scene
			for cur_scene in scene_list:
				tries += 1
				# Keep track of the first scene name for use in suggestions
				if first_scene_name == "":
					first_scene_name = cur_scene.sceneName
				# Request the list of scene items for the current scene
				obs.get_scene_item_list(cur_scene.sceneName)
				# Wait for the scene item list to be retrieved
				var scene_item_list = await obs.got_scene_item_list
				# If we got a valid list, check if our source exists in it
				if typeof(scene_item_list) != TYPE_ARRAY:
					continue
				var i = scene_item_list.find_custom(func(e): return e.sourceName == source_name)
				# If we found our source, save its scene item ID and scene name
				if i > -1:
					cur_scene_item_id = scene_item_list[i].sceneItemId
					cur_scene_name = cur_scene.sceneName
					break
		if cur_scene_name == "" or cur_scene_item_id == -1.0:
			tries = 0
			while (cur_scene_name == "" or cur_scene_item_id == -1.0) and tries < 5:
				if group_list == []:
					tries = 5
					break
				# Loop through each scene
				for cur_scene in group_list:
					tries += 1
					# Keep track of the first scene name for use in suggestions
					if first_scene_name == "":
						first_scene_name = cur_scene
					# Request the list of scene items for the current scene
					obs.get_group_scene_item_list(cur_scene)
					# Wait for the scene item list to be retrieved
					var scene_item_list = await obs.got_group_scene_item_list
					# If we got a valid list, check if our source exists in it
					if typeof(scene_item_list) != TYPE_ARRAY:
						continue
					var i = scene_item_list.find_custom(func(e): return e.sourceName == source_name)
					# If we found our source, save its scene item ID and scene name
					if i > -1:
						cur_scene_item_id = scene_item_list[i].sceneItemId
						cur_scene_name = cur_scene
						break
		# If we couldn't find our source after 5 attempts, log an error
		if cur_scene_name == "" or cur_scene_item_id == -1.0:
			if !obs_config_error_shown:
				logger.log_error("Couldn't get the source in any scenes after %d tries" % tries)
				obs_config_error_shown = true
		else:
			# If we found our source, check for the required filters
			tries = 0
			while !has_scale_filter and tries < 5:
				tries += 1
				# Request the scale filter settings
				obs.get_source_filter(source_name, source_filter_name)
				# Wait for the filter settings to be retrieved
				var source_filter = await obs.got_source_filter
				# If we got valid filter settings, we have the filter
				if typeof(source_filter) == TYPE_DICTIONARY:
					has_scale_filter = true
					break
			tries = 0
			while !has_fade_filter and tries < 5:
				tries += 1
				# Request the fade filter settings
				obs.get_source_filter(source_name, fade_filter_name)
				# Wait for the filter settings to be retrieved
				var source_filter = await obs.got_source_filter
				# If we got valid filter settings, we have the filter
				if typeof(source_filter) == TYPE_DICTIONARY:
					has_fade_filter = true
					break

	# Prepare a list of configuration changes needed
	var config_changes = "[ul]"
	if cur_scene_item_id == -1.0:
		# If the source isn't found, suggest creating it
		config_changes += "[b]Create a Media Source[/b] in scene \"[color=green][b]%s[/b][/color]\" called \"[b]%s[/b]\"." % [first_scene_name, source_name]
		config_changes += "You can move or copy this to other scenes later.\n"
	if !has_scale_filter:
		# If the scale filter isn't found, suggest adding it
		config_changes += "[b]Add an Effects filter[/b] named \"[b]%s[/b]\" to the source named \"[b]%s[/b]\".\n" % [source_filter_name, source_name]
	if !has_fade_filter:
		# If the fade filter isn't found, suggest adding it
		config_changes += "[b]Add an Effects filter[/b] named \"[b]%s[/b]\" to the source named \"[b]%s[/b]\".\n" % [fade_filter_name, source_name]
	config_changes += "[/ul]"

	# Update the UI with the configuration suggestions
	%ConfigChanges.text = config_changes
	if cur_scene_item_id == -1.0 or !has_scale_filter or !has_fade_filter:
		# If there are configuration issues, show the setup button and log an error
		if !%SetupOBS.visible:
			logger.log_error("There is an issue with OBS configuration.  Check the \"[b]Setup OBS[/b]\" button for more details.")
			%SetupOBS.show()
		obs_configured = false
		return false
	# If the configuration is valid, hide the setup button and panel
	if !%SetupOBS.visible:
		logger.log_success("The OBS configuration looks good.")
		%SetupOBS.hide()
	%OBSConfigPanel.hide()
	obs_configured = true
	obs_config_error_shown = false
	return true


## Handles the button press event for setting up OBS.
## This function attempts to create the necessary source and filters in OBS
## if they don't already exist. It retries up to 5 times for each operation.
## After attempting all necessary operations, it hides the setup panel and button
## if everything is successful.
func _on_setup_obs_button_pressed() -> void:
	var tries = 0
	# Check if the media source needs to be created
	if cur_scene_item_id == -1.0:
		# Create source in scene
		while cur_scene_item_id == -1.0 and tries < 5:
			tries += 1
			obs.create_media_input(first_scene_name, source_name)
			var result = await obs.created_input
			if !typeof(result) == TYPE_DICTIONARY:
				continue
			cur_scene_item_id = result.sceneItemId
			logger.log_success("Created new media source: \"%s\" in scene: \"%s\"" % [source_name, first_scene_name])
		if cur_scene_item_id == -1.0:
			logger.log_error("Failed to create media source: \"%s\" in scene: \"%s\"" % [source_name, first_scene_name])

	# Check if the scale filter needs to be created
	if !has_scale_filter:
		# Create scale filter in scene
		tries = 0
		while !has_scale_filter and tries < 5:
			tries += 1
			obs.create_source_filter(source_name, source_filter_name, "scale_filter")
			if !await obs.created_source_filter:
				continue
			has_scale_filter = true
			logger.log_success("Created scale filter on source: \"%s\"" % source_name)
		if !has_scale_filter:
			logger.log_error("Failed to create scale filter on source: \"%s\"" % source_name)

	# Check if the fade filter needs to be created
	if !has_fade_filter:
		# Create fade filter in scene
		tries = 0
		while !has_fade_filter and tries < 5:
			tries += 1
			obs.create_source_filter(source_name, fade_filter_name, "color_filter_v2")
			if !await obs.created_source_filter:
				continue
			has_fade_filter = true
			logger.log_success("Created fade filter on source: \"%s\"" % source_name)
		if !has_fade_filter:
			logger.log_error("Failed to create fade filter on source: \"%s\"" % source_name)

	# After all operations, hide the setup panel and button if successful
	if cur_scene_item_id != -1.0 and has_scale_filter and has_fade_filter:
		%OBSConfigPanel.hide()
	%SetupOBS.hide()


## Handles the event when the scene item transform changes.
## This function updates the clip ratio based on the new scene item transform.
## It is called whenever the scene item's source width or height changes.
func _on_obs_scene_item_transform_changed(event_data: Dictionary) -> void:
	if wait_for_clip_transform and event_data.sceneItemId == cur_scene_item_id:
		if event_data.sceneItemTransform.sourceWidth > 0.0 and event_data.sceneItemTransform.sourceHeight > 0.0:
			wait_for_clip_transform = false
			cur_clip_ratio = event_data.sceneItemTransform.sourceWidth / event_data.sceneItemTransform.sourceHeight
