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
const SHOUTOUT_COOLDOWN = 120
const PER_USER_SHOUTOUT_COOLDOWN = 3600

enum ClipAnimations {
	LINEAR,
	INFLATE,
	TV,
}

signal bad_clip_state
signal clip_started
signal clip_ended
signal obs_scale_filter_enable_state_changed

@onready var logger = %AppLogger
@onready var obs = %Obs

## Queue to hold clips waiting to be played
var clip_queue = []
## Queue to hold shoutouts waiting to be played
var so_queue = []
## Keeps up with the cooldowns for individual user shoutouts
var user_so_cooldowns = []
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
# Holds the clips for each user once they've been retrieved from Twitch
var user_clips = { }
# True if we are trying to play a clip right now
var try_clip_play = false
# Flag to enable/disable grow sound effect
var use_grow_sound = false
# Flag to control the clip animation type
var use_linear_animation = true
# Flag to control the inflate animation type
var use_inflate_animation = false
# Flag to control the TV animation type
var use_tv_animation = false
# Variable to track the current animation type
var cur_animation_type = ClipAnimations.LINEAR
# Flag to track if shoutout is on cooldown
var so_on_cooldown = false
# Variable to track the recent raider
var recent_raider = ""
# Flag to track if clip show is running
var clip_show_running = false
# Flag to track if self clip show is running
var self_clip_show_running = false


## Main process function that handles frame timing and animation updates
func _process(delta: float) -> void:
	process_ui(delta)
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


## Updates the UI elements related to shoutouts, such as countdown bars and text.
func process_ui(_delta: float):
	if so_on_cooldown:
		%SOCountDownBar.value = %SOCountdownTimer.time_left
		%SOCountDown.text = "%d seconds" % %SOCountdownTimer.time_left
	else:
		%SOCountDownBar.value = 0
		%SOCountDown.text = "Ready for Shoutout"


## Handles the resetting variables if the clip is in an unexpected state
func _on_bad_clip_state() -> void:
	logger.log_error("Bad clip state, sending back to queue.")
	reset_playback()


## Handles clip ended event
func _on_clip_ended() -> void:
	logger.log_debug("Got clip ended event from OBS")
	clip_playing = false
	# reset resizing state
	clip_resizing = false
	# prepare and start the fade process
	clip_initial_fade_set = false
	if fade_out:
		clip_fading_out = true
	# fading is handled in the animation thread so it will start
	# on it's own, we wait here for the fade animation to complete
	logger.log_debug("await clip_end_delay seconds: %f" % clip_end_delay)
	await get_tree().create_timer(clip_end_delay).timeout
	if !fade_out:
		fade_source(0.0)
	# once the clip no longer shows on the screen, remove it from
	# the media source to prevent looping playback
	clear_clip()
	if obs_scale:
		logger.log_debug("Disable scale filter")
		obs.set_source_filter_enabled(source_name, source_filter_name, false)
		await obs.source_filter_enabled
		logger.log_debug("Call to disable scale filter succeeded")

	if clip_queue.is_empty():
		if clip_show_running:
			await add_random_clip_from_cache(1)
		elif self_clip_show_running:
			await add_random_self_clip(1)

	# if the clip queue has more clips, play them after a timeout
	if not clip_queue.is_empty():
		logger.log_debug("Queue is not empty, processing queue after queue delay of %f seconds" % queue_delay)
		await get_tree().create_timer(queue_delay).timeout
		process_clip_queue()


## This function finds the scene and source ID for the clip to be displayed.
## It retrieves the scene list from OBS, then iterates through the scenes
## to find the one that contains the source with the name 'Godot-Show'.
## If the source is not found within a scene, it attempts to configure OBS
## if it hasn't been configured already, and returns false.
## The function returns true if the scene and source ID are successfully found.
func find_scene_and_source_id() -> bool:
	logger.log_debug("Searching for scene and source")
	# Get the scene list from OBS
	obs.get_scene_list()
	# Wait for the scene list to be received
	var scene_list = false
	var group_list = false
	var tries = 0
	# Retry up to 5 times if the scene list is not yet available
	while typeof(scene_list) != TYPE_ARRAY and tries < 5:
		logger.log_debug("Try %d for getting OBS scene list" % tries)
		tries += 1
		scene_list = await obs.got_scene_list
	# If we've tried too many times, check if OBS is configured
	if tries >= 5:
		logger.log_debug("Failed to get the scene list")
		check_obs_config()
		return false
	# Get the group list from OBS
	obs.get_group_list()
	# Retry up to 5 times if the scene list is not yet available
	while typeof(group_list) != TYPE_ARRAY and tries < 5:
		logger.log_debug("Try %d for getting OBS group list" % tries)
		tries += 1
		group_list = await obs.got_group_list
	# Reset the scene item ID and scene name
	cur_scene_item_id = -1.0
	cur_scene_name = ""
	# Try to find the source within scenes up to 5 times
	tries = 0
	logger.log_debug("Itterating scene and group lists now")
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
				logger.log_debug("Found scene and source")
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
				logger.log_debug("Found scene and source")
				return true
	logger.log_debug("Failed to find scene and source, check config")
	# If we didn't find the source, check if OBS is configured
	check_obs_config()
	return false


## Handles clip started event
func _on_clip_started() -> void:
	logger.log_debug("We think the clip truley started")
	# Re-enable the scale filter so we can start scaling
	if obs_scale:
		logger.log_debug("OBS Scale is enabled, try setting scale filter enabled")
		# Prepare a function to set the clip url if
		var handle_clip_end_if_filter_enabled = func(event_data):
			if !event_data.filterEnabled:
				logger.log("Scale filter got set to diabled after trying to enable it")
			else:
				handle_clip_started()
		# Connect to the filter state changed function to detect the disable event
		obs_scale_filter_enable_state_changed.connect(handle_clip_end_if_filter_enabled, CONNECT_ONE_SHOT)
		# Set a timout of 2 seconds to wait for the source filter to get enabled
		get_tree().create_timer(2.0).timeout.connect(
			func():
				# If the function is still connected to the signal after 2 seconds, we failed
				if obs_scale_filter_enable_state_changed.is_connected(handle_clip_end_if_filter_enabled):
					logger.log_debug("Timer expired, no message received from OBS")
					obs_scale_filter_enable_state_changed.disconnect(handle_clip_end_if_filter_enabled)
		)
		# Enable the source filter
		obs.set_source_filter_enabled(source_name, source_filter_name, true)
		# Wait till the message goes through, if it fails just continue
		if await obs.source_filter_enabled:
			logger.log_debug("Command to enable scale filter succeeded")
			# Don't handle the scaling until the OBS event says the filter was disabled
			return
		logger.log_debug("Error enabling scale filter")
	handle_clip_started()


## This function handles the clip started event and performs necessary actions
func handle_clip_started():
	logger.log_debug("Set media state timer to 1 second")
	# Restart the media timer with a slower rate now that we are only checkng
	# for bad or missed state changes
	%OBSMediaTimer.start(1.0)
	clip_initial_size_set = false
	clip_resizing = obs_scale
	clip_initial_fade_set = false
	if fade_in:
		clip_fading_in = true


## Handles OBS media input ended event
func _on_obs_media_input_playback_ended(event_data: Dictionary) -> void:
	# only handle events for the correct source
	if event_data["inputName"] == source_name:
		logger.log_debug("Got event saying the media input has ended")
		_on_clip_ended()


## Handles OBS input settings set event
func _on_obs_input_settings_set(result) -> void:
	logger.log_debug("Got event saying input settings have been set")
	if !result:
		logger.log_error("Failed to set clip, sending back to queue.")
		reset_playback()
		return
	# once we are sure that the clip has been set, we can clear it from
	# the app
	if current_clip == null:
		logger.log_debug("Current clip is not set, skip")
		return
	current_clip = null
	cur_clip_ratio = 0.0
	wait_for_clip_transform = true
	logger.log_debug("Starting to wait for confirmation that clip is actually starting, will poll ever 0.05 seconds now")
	# Restart the media timer at a higher rate so we can start animations
	# as soon as the clip actually starts playing
	%OBSMediaTimer.start(0.05)


## Handles source filter settings error
func _on_source_filter_settings_set(result) -> void:
	# if we fail to set the filter, we need to reset state so the next
	# attempt will work
	if typeof(result) == TYPE_BOOL:
		logger.log_debug("Failed to set the filter settings")
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
	logger.log_debug("Check if media playing, media_duration: %f media_cursor: %f cur_clip_ratio: %f" % [media_duration, media_cursor, cur_clip_ratio])
	if media_state == obs.MediaInputStates.OBS_MEDIA_STATE_PLAYING and media_duration > 0.0 and media_cursor > 0.0 and cur_clip_ratio != 0.0:
		# If state goes from buffering to playing then start animations
		if !clip_playing:
			logger.log_debug("Looks like we are truly playing the clip now")
			clip_playing = true
			try_clip_play = false
			emit_signal("clip_started") # Signal that a clip has started playing
		last_media_state = media_state
		return
	# If we're here, the clip isn't playing
	# If we think a clip is playing, then reset playback
	if !clip_queue.is_empty() and clip_playing and media_state in [
		obs.MediaInputStates.OBS_MEDIA_STATE_PAUSED,
		obs.MediaInputStates.OBS_MEDIA_STATE_STOPPED,
		obs.MediaInputStates.OBS_MEDIA_STATE_ENDED,
		obs.MediaInputStates.OBS_MEDIA_STATE_ERROR,
		obs.MediaInputStates.OBS_MEDIA_STATE_NONE,
	]:
		emit_signal("bad_clip_state")
	# Check if we're going from playing to not playing
	if clip_playing:
		emit_signal("clip_ended") # Signal that a clip has stopped playing
	clip_playing = false
	last_media_state = media_state


## Resets playback to the previous clip and restarts queue processing
func reset_playback():
	logger.log_debug("Resetting playback")
	clip_playing = false
	try_clip_play = false
	if current_clip != null:
		logger.log_debug("Add clip back to front of queue")
		clip_queue.insert(0, current_clip)
		%ClipQueueList.move_item(%ClipQueueList.add_item("%s - %s" % [current_clip.broadcaster_name, current_clip.title]), 0)

	fade_source(0.0)
	await obs.source_filter_settings_set
	clear_clip()
	
	current_clip = null
	logger.log_debug("Wait for %f seconds before processing queue" % queue_delay)
	await get_tree().create_timer(queue_delay).timeout
	process_clip_queue()


## Resets all animations and states
func reset_animations():
	logger.log_debug("Resetting animations")
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
		logger.log_debug("Clip initial size not set yet, doing so now with cur_clip_ratio: %f" % cur_clip_ratio)
		var anim_list = []
		if use_linear_animation:
			anim_list.append(ClipAnimations.LINEAR)
		if use_inflate_animation:
			anim_list.append(ClipAnimations.INFLATE)
		if use_tv_animation:
			anim_list.append(ClipAnimations.TV)
		cur_animation_type = anim_list.pick_random()
		if use_grow_sound:
			var effectBus = AudioServer.get_bus_index("Effect")
			var effect: AudioEffectPitchShift = AudioServer.get_bus_effect(effectBus, 0)
			var slen = %GrowSound.stream.get_length()
			effect.pitch_scale = (time_to_scale / slen)
			%GrowSound.pitch_scale = 1 / (time_to_scale / slen)
			%GrowSound.play()
		resize_time_elapsed = 0.0
		cur_size = min_size
		scale_source(cur_size.x, cur_size.y)
		clip_initial_size_set = true
		if !fade_in:
			fade_source(1.0)
		return

	var maxWidth = max_size.x
	var maxHeight = max_size.y
	if cur_clip_ratio >= 1:
		maxHeight = maxWidth / cur_clip_ratio
	else:
		maxWidth = maxHeight * cur_clip_ratio

	# if we have finished the animation time, stop the animation and reset variables.
	if resize_time_elapsed >= time_to_scale:
		logger.log_debug("Clip has reached maximum time, stopping scale animation.")
		resize_time_elapsed = 0.0
		clip_resizing = false
		if use_grow_sound:
			if %GrowSound.playing:
				%GrowSound.stop()
		return
	# keep track of the total time spent on the resize animation
	resize_time_elapsed += delta
	# calculate the new size based on the elapsed time
	var progress_ratio: float = resize_time_elapsed / time_to_scale
	match cur_animation_type:
		ClipAnimations.LINEAR:
			cur_size.x = min_size.x + ((maxWidth - min_size.x) * progress_ratio)
			cur_size.y = min_size.y + ((maxHeight - min_size.y) * progress_ratio)
		ClipAnimations.INFLATE:
			var grow_ratio: float = progress_ratio
			if progress_ratio < 0.33:
				grow_ratio = progress_ratio
			elif progress_ratio < 0.53:
				if %GrowSound.playing:
					%GrowSound.stop()
				grow_ratio = 0.33 - 0.05 * ((progress_ratio - 0.33) / 0.20)
			elif progress_ratio < 0.70:
				grow_ratio = 0.28 + 0.42 * ((progress_ratio - 0.53) / 0.17)
				if use_grow_sound:
					if !%GrowSound.playing:
						var effectBus = AudioServer.get_bus_index("Effect")
						var effect: AudioEffectPitchShift = AudioServer.get_bus_effect(effectBus, 0)
						var slen = %GrowSound.stream.get_length()
						effect.pitch_scale = ((time_to_scale * (1 - grow_ratio)) / slen)
						%GrowSound.pitch_scale = 1 / ((time_to_scale * (1 - grow_ratio)) / slen)
						%GrowSound.play(slen * grow_ratio)
			elif progress_ratio < 0.90:
				if %GrowSound.playing:
					%GrowSound.stop()
				grow_ratio = 0.70 - 0.05 * ((progress_ratio - 0.70) / 0.20)
			else:
				grow_ratio = 0.65 + 0.35 * ((progress_ratio - 0.90) / 0.10)
				if use_grow_sound:
					if !%GrowSound.playing:
						var effectBus = AudioServer.get_bus_index("Effect")
						var effect: AudioEffectPitchShift = AudioServer.get_bus_effect(effectBus, 0)
						var slen = %GrowSound.stream.get_length()
						effect.pitch_scale = ((time_to_scale * (1 - grow_ratio)) / slen)
						%GrowSound.pitch_scale = 1 / ((time_to_scale * (1 - grow_ratio)) / slen)
						%GrowSound.play(slen * grow_ratio)
			cur_size.x = min_size.x + ((maxWidth - min_size.x) * grow_ratio)
			cur_size.y = min_size.y + ((maxHeight - min_size.y) * grow_ratio)
		ClipAnimations.TV:
			if progress_ratio < 0.33:
				cur_size.x = min_size.x + ((maxWidth - min_size.x) * (progress_ratio * 3))
				cur_size.y = min_size.y + ((maxHeight - min_size.y) * (progress_ratio * 0.10))
			else:
				cur_size.x = maxWidth
				var sp = (min_size.y + ((maxHeight - min_size.y) * (0.33 * 0.10)))
				cur_size.y = sp + ((maxHeight - sp) * ((progress_ratio - 0.33) / 0.66))

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
		logger.log_debug("Initial fade not set, setting initial fade values now")
		fade_time_elapsed = 0.0
		cur_opacity = 0.0 if clip_fading_in else 1.0
		fade_source(cur_opacity)
		clip_initial_fade_set = true
		return
	# if we are done fading, stop the animation and reset values
	if (clip_fading_in and cur_opacity >= 1.0) or (clip_fading_out and cur_opacity <= 0.0):
		logger.log_debug("Fade complete, resetting values")
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
	if obs.obs_connected and obs_configured:
		await obs.set_source_filter_settings(source_name, fade_filter_name, { "opacity": opacity })


## Processes the clip queue by playing the next clip if available.
## Waits for OBS to be ready before attempting to play.
## Does nothing if the queue is empty or if a clip is already playing.
func process_clip_queue():
	if try_clip_play:
		logger.log_debug("We're already trying to play a clip, skip")
		return
	# If OBS isn't fully ready, then try again after the queue timer time
	if !obs.obs_connected or !obs_configured:
		logger.log_debug("OBS isn't ready yet, wait for %d seconds before trying again" % queue_delay)
		await get_tree().create_timer(queue_delay).timeout
		process_clip_queue()
		return
	# If the queue is empty or a clip is already playing, do nothing
	if clip_queue.is_empty() or clip_playing:
		logger.log_debug("Queue is empty or a clip is already playing, nothing to do")
		return
	# Play the next clip from the queue
	%ClipQueueList.remove_item(0)
	play_clip(clip_queue.pop_front())


## This function processes the shoutout queue
func process_so_queue():
	if so_queue.is_empty():
		return
	if so_on_cooldown:
		return
	# Check each user in the queue for shoutouts
	for i in so_queue.size():
		%SOQueueList.remove_item(i)
		var cur_user = so_queue.pop_at(i)
		var current_user: TwitchUser = await Twitch.get_current_user()
		if current_user.display_name == cur_user:
			continue # Skip if it's the current user

		# Check if the user is on cooldown
		if user_so_cooldowns.has(cur_user):
			%SOQueueList.add_item("%s - On Cooldown" % cur_user)
			get_tree().create_timer(PER_USER_SHOUTOUT_COOLDOWN).timeout.connect(func(): so_queue.append(cur_user))
			continue # Skip if on cooldown

		# Send the shoutout if not on cooldown
		await send_so(cur_user)
		so_on_cooldown = true
		%SOCountDownBar.max_value = SHOUTOUT_COOLDOWN
		%SOCountdownTimer.start(SHOUTOUT_COOLDOWN)
		get_tree().create_timer(SHOUTOUT_COOLDOWN).timeout.connect(
			func():
				so_on_cooldown = false
				process_so_queue()
		)
		return # Exit after sending the first shoutout


## Sends a shoutout to a specified user.
##
## This function sends a shoutout to a specified Twitch user.
## It first checks if the user exists and then attempts to send
## a shoutout using the Twitch API.
##
## @param username The username of the Twitch user to shoutout.
func send_so(username: String) -> bool:
	var current_user: TwitchUser = await Twitch.get_current_user()
	var user = await Twitch.get_user(username)
	if user == null:
		logger.log_error("Couldn't get user %s" % username)
		return false
	var response: BufferedHTTPClient.ResponseData = await Twitch.api.send_a_shoutout(current_user.id, current_user.id, user.id)
	if response.response_code == 429:
		%SOQueueList.add_item("%s - On Cooldown" % username)
		get_tree().create_timer(PER_USER_SHOUTOUT_COOLDOWN).timeout.connect(func(): so_queue.append(username))
		return false
	return true


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
		logger.log_debug("we're already trying to play a clip, skip")
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
		logger.log_debug("Scaling is enabled, will try to disable scale filter so we can get original clip size")
		# First we get the source filter to see if it even needs to be disabled
		logger.log_debug("First get scale filter state")
		obs.get_source_filter(source_name, source_filter_name)
		var source_filter = await obs.got_source_filter
		# Only continue if we actually got the source filter
		if typeof(source_filter) == TYPE_DICTIONARY:
			logger.log_debug("We got the scale filter state")
			if source_filter.filterEnabled:
				logger.log_debug("Scale filter is enabled, will try to disable it")
				# Prepare a function to set the clip url if
				var set_clip_url_if_enabled = func(event_data):
					if event_data.filterEnabled:
						logger.log("Scale filter got set to enabled after trying to disable it")
					else:
						set_clip_url(clip)
				# Connect to the filter state changed function to detect the disable event
				obs_scale_filter_enable_state_changed.connect(set_clip_url_if_enabled, CONNECT_ONE_SHOT)
				# Set a timout of 2 seconds to wait for the source filter to get disabled
				get_tree().create_timer(2.0).timeout.connect(
					func():
						# If the function is still connected to the signal after 2 seconds, we failed
						if obs_scale_filter_enable_state_changed.is_connected(set_clip_url_if_enabled):
							logger.log_debug("Timer expired, no message received from OBS")
							obs_scale_filter_enable_state_changed.disconnect(set_clip_url_if_enabled)
				)

				# Disable the source filter
				obs.set_source_filter_enabled(source_name, source_filter_name, false)
				# Wait till the message goes through, if it fails just continue
				if await obs.source_filter_enabled:
					logger.log_debug("Command to disable scale filter succeeded")
					# Don't set the clip until the OBS event says the filter was disabled
					return
				logger.log_debug("Error disabling scale filter")
				reset_playback()
				return
			logger.log_debug("Scale filter not enabled, skipping")
		else:
			logger.log_debug("Failure getting scale filter state")
			check_obs_config()
			reset_playback()
			return
	set_clip_url(clip)


## This function sets the clip URL in OBS.
##
## This function sets the clip URL in OBS. It takes a TwitchClip object as an
## argument and sets the input settings of the source to the clip's URL.
##
## Arguments:
## clip: A TwitchClip object representing the clip to set as the URL.
##
## Example:
## set_clip_url(clip)
func set_clip_url(clip: TwitchClip = null):
	logger.log_debug("Actually set the clip URL in OBS now")
	if clip != null:
		obs.set_input_settings(source_name, { "input": clip.url, "is_local_file": false })
		return
	obs.set_input_settings(source_name, { "input": "", "is_local_file": false })


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
		logger.log_debug("Clearing current clip in OBS now")
		set_clip_url()


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
		logger.log_debug("User: %s not found in clip cache. Fetching from API" % username)
		# Fetch the Twitch user information for the given username
		var so_user: TwitchUser
		so_user = await Twitch.get_user(username)
		if so_user == null:
			logger.log("Couldn't get shoutout for user: %s" % username)
			return
		# Fetch a list of clips for the user
		var clips: TwitchGetClips.Response
		var clip_options = TwitchGetClips.Opt.from_json(
			{
				"broadcaster_id": so_user.id,
				"first": 100,
			},
		)
		logger.log_debug("Waiting for Twitch API response")
		clips = await Twitch.api.get_clips(clip_options)

		# If no clips are found, return null
		if clips.data.is_empty():
			logger.log_debug("No clips found for user: %s", username)
			return null
		logger.log_debug("Got clips for user: %s and stored in clip cache" % username)
		user_clips[username] = { "unplayed": clips.data, "played": [] }

	# Pick a random clip from the list
	if user_clips[username].unplayed.is_empty():
		logger.log_debug("No unplayed clips found for user: %s moving played to unplayed", username)
		user_clips[username].unplayed = user_clips[username].played
		user_clips[username].played.clear()
	logger.log_debug("Picking a random clip from the unplayed list")
	var clip = user_clips[username].unplayed.pick_random()
	logger.log_debug("Clip picked: %s, moving from unplayed to played" % clip.id)
	user_clips[username].unplayed.erase(clip)
	user_clips[username].played.append(clip)

	var clip_url = await get_clip_url(clip.id)
	if clip_url != null:
		clip.url = clip_url
		return clip

	return null


## This function fetches the clip URL for a given clip ID.
## It uses the Twitch GraphQL API to retrieve the clip's access token.
## The function constructs the clip URL by combining the source URL and the
## access token and signature.
##
## Arguments:
## clip_id: A string representing the clip ID.
##
## Returns:
## A string representing the clip URL, or null if the request fails.
##
## Example:
## var clip_url = get_clip_url("clip123")
func get_clip_url(clip_id: String):
	# Create a request to get the clip's access token
	# this doesn't use the standard Twitch API, this is the GraphQL API
	logger.log_debug("Creating a request to get the clip's access token")
	var req: BufferedHTTPClient.RequestData = Twitch.api.client.request(
		"https://gql.twitch.tv/gql",
		HTTPClient.METHOD_POST,
		{ "Content-Type": "application/json", "Client-ID": TWITCH_VIDEO_API_CLIENT },
		JSON.stringify(
			{
				"operationName": "VideoAccessToken_Clip",
				"variables": { "slug": clip_id },
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
	logger.log_debug("Waiting for the response from the Twitch API")
	var res: BufferedHTTPClient.ResponseData = await Twitch.api.client.wait_for_request(req)

	# If the request was successful, parse the response and construct the clip URL
	if res.response_code == 200:
		logger.log_debug("Got clip token from Twitch API")
		var parsed = JSON.parse_string(res.response_data.get_string_from_utf8())

		var clip_url = parsed.data.clip.videoQualities[0].sourceURL + "?token=%s&sig=%s" % [
			parsed.data.clip.playbackAccessToken.value.uri_encode(),
			parsed.data.clip.playbackAccessToken.signature.uri_encode(),
		]
		return clip_url

	logger.log_debug("Failed to get clip token from Twitch API")
	return null


## Checks the OBS configuration to ensure the required source and filters are set up correctly.
## This function verifies that:
## 1. The scene list is available
## 2. The source exists in one of the scenes
## 3. The required filters (scale and fade) exist on the source
## It also updates the UI with configuration suggestions if issues are found.
## The function returns true if the configuration is valid, false otherwise.
func check_obs_config() -> bool:
	logger.log_debug("Checking OBS configuration")
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
	obs_configured = true
	# If the configuration is valid, hide the setup button and panel
	if !%SetupOBS.visible:
		logger.log_success("The OBS configuration looks good.")
		%SetupOBS.hide()
		fade_source(0.0)
		clear_clip()
	%OBSConfigPanel.hide()
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
	if wait_for_clip_transform:
		logger.log_debug("A scene item transform changed")

		# deep breath.. FINE!!!
		# get scene item list
		# itterate the damn list to find the one that matches our scene item id
		# see what the source name is for that scene item id.... (>_<)
		var cur_source_name = ""
		obs.get_scene_item_list(event_data.sceneName)
		var scene_item_list = await obs.got_scene_item_list
		if typeof(scene_item_list) == TYPE_ARRAY:
			var i = scene_item_list.find_custom(func(e): return e.sceneItemId == event_data.sceneItemId)
			# If we found our source, save its scene item ID and scene name
			if i > -1:
				cur_source_name = scene_item_list[i].sourceName
		if cur_source_name == "":
			obs.get_group_scene_item_list(event_data.sceneName)
			scene_item_list = await obs.got_group_scene_item_list
			if typeof(scene_item_list) == TYPE_ARRAY:
				var i = scene_item_list.find_custom(func(e): return e.sceneItemId == event_data.sceneItemId)
				# If we found our source, save its scene item ID and scene name
				if i > -1:
					cur_source_name = scene_item_list[i].sourceName

		# If this transform is fro, the correct source name, then update the clip ratio.
		if wait_for_clip_transform and cur_source_name == source_name:
			logger.log_debug("The transform was for our source, updating clip ratio")
			if event_data.sceneItemTransform.sourceWidth > 0.0 and event_data.sceneItemTransform.sourceHeight > 0.0:
				wait_for_clip_transform = false
				cur_clip_ratio = event_data.sceneItemTransform.sourceWidth / event_data.sceneItemTransform.sourceHeight
				logger.log_debug("The new clip ratio is: %f" % cur_clip_ratio)
			else:
				logger.log_debug("The source width or height is zero, not updating clip ratio")


## Handles the event when a source filter's enable state changes.
## This function is called whenever a source filter is enabled or disabled.
## It is used to update the source filter's enable state in the scene.
func _on_obs_source_filter_enable_state_changed(event_data: Variant) -> void:
	if event_data.sourceName == source_name:
		obs_scale_filter_enable_state_changed.emit(event_data)


func add_random_clip(username: String, count: int = 1):
	for each in count:
		# Get a random clip from the specified user
		var clip = await get_random_clip_url(username)
		if clip != null:
			# Add the clip to the queue
			clip_queue.append(clip)
			%ClipQueueList.add_item("%s - %s" % [clip.broadcaster_name, clip.title])
			logger.log(
				"Added clip to queue: \"%s\" from %s clipped by %s"
				% [clip.title, clip.broadcaster_name, clip.creator_name],
			)
	# If the queue is not currently processing, start it
	process_clip_queue()


## Adds random clips from the user's that have already had clips
## played this session.
##
## @param count The number of clips to add from the cache.
func add_random_clip_from_cache(count: int = 1):
	for each in count:
		if user_clips.is_empty():
			return
		var cur_user_clips = user_clips[user_clips.keys().pick_random()]
		var cur_user
		if cur_user_clips.unplayed.is_empty():
			cur_user = cur_user_clips.played[0].display_name
		else:
			cur_user = cur_user_clips.unplayed[0].display_name
		await add_random_clip(cur_user)


## Adds random clips from the user's own account.
##
## @param count The number of clips to add from the user's own account.
func add_random_self_clip(count: int = 1):
	var user = await Twitch.get_current_user()
	await add_random_clip(user.display_name, count)


## Parse a Twitch clip URL and extract the clip ID.
##
## @param clip_url The URL of the Twitch clip to parse.
## @return The clip ID extracted from the URL, or null if parsing fails.
func parse_twitch_clip_url(clip_url: String):
	var clip_start = clip_url.find("clip/")
	if clip_start == -1:
		return null
	var clip_end = clip_url.rfind("?")
	if clip_end == -1:
		return clip_url.substr(clip_start + 5)
	return clip_url.substr(clip_start + 5, clip_end - (clip_start + 5))


## Add a clip to the queue using a Twitch clip URL
##
## @param clip_id_url The URL of the clip to add. Must be a valid Twitch clip URL.
func add_clip(clip_id_url: String):
	var clip_id = parse_twitch_clip_url(clip_id_url)
	if clip_id == null:
		logger.log("Couldn't parse clip URL")
		return

	var clips: TwitchGetClips.Response
	var clip_options: TwitchGetClips.Opt = TwitchGetClips.Opt.new()
	clip_options.id = [clip_id]
	clip_options.first = 1

	logger.log_debug("Waiting for Twitch API response")
	clips = await Twitch.api.get_clips(clip_options)

	if clips.data.is_empty():
		logger.log_error("Couldn't find clip by id")
		return

	var clip = clips.data[0]

	var clip_url = await get_clip_url(clip_id)
	if clip_url != null:
		clip.url = clip_url
		clip_queue.append(clip)
		%ClipQueueList.add_item("%s - %s" % [clip.broadcaster_name, clip.title])
		return
	logger.log_error("Error retrieving clip from URL")


## Queues a shoutout for a specific user.
## This function adds the user to the shoutout queue and processes the queue if necessary.
##
## @param username The Twitch username of the user to queue for a shoutout.
func queue_shoutout(username: String):
	logger.log("Queueing shoutout")
	if !so_queue.has(username):
		%SOQueueList.add_item("%s" % username)
		so_queue.append(username)
	process_so_queue()


## Handles the event when a shoutout command is received.
## This function is called when a shoutout command is sent to the script.
## It queues the user for a shoutout and processes the queue if necessary.
##
## @param _from_username The username of the user who sent the shoutout command.
## @param _info The information about the shoutout command.
## @param args An array of strings containing the arguments of the shoutout command.
## @return void
func _on_shoutout_command_received(_from_username: String, _info: TwitchCommandInfo, args: PackedStringArray) -> void:
	if %UseQueueSOCmd.button_pressed:
		queue_shoutout(args[0])
		logger.log("Shoutout command triggered")


## Handles the event when a random clip command is received.
## This function is called when a random clip command is sent to the script.
## It adds random clips from the specified user to the queue.
##
## @param _from_username The username of the user who sent the random clip command.
## @param _info The information about the random clip command.
## @param args An array of strings containing the arguments of the random clip command.
## @return void
func _on_random_clip_command_received(_from_username: String, _info: TwitchCommandInfo, args: PackedStringArray) -> void:
	if %UseRandomClipCmd.button_pressed:
		var clip_count = 1
		if args.size() > 1 and args[1].is_valid_int():
			clip_count = args[1].to_int()
		add_random_clip(args[0], clip_count)
		logger.log("Random clip command triggered")


## Handles the event when a shoutout and random clip command is received.
## This function is called when a shoutout and random clip command is sent to the script.
## It queues the user for a shoutout and adds random clips from the user to the queue.
##
## @param _from_username The username of the user who sent the shoutout and random clip command.
## @param _info The information about the shoutout and random clip command.
## @param args An array of strings containing the arguments of the shoutout and random clip command.
## @return void
func _on_so_random_clip_command_received(_from_username: String, _info: TwitchCommandInfo, args: PackedStringArray) -> void:
	if %UseSORandomClipCmd.button_pressed:
		queue_shoutout(args[0])
		var clip_count = 1
		if args.size() > 1 and args[1].is_valid_int():
			clip_count = args[1].to_int()
		add_random_clip(args[0], clip_count)
		logger.log("Shoutout and Random clip command triggered")


## Handles the event when a clip command is received.
## This function is called when a clip command is sent to the script.
## It adds the clip from the specified URL to the queue.
##
## @param _from_username The username of the user who sent the clip command.
## @param _info The information about the clip command.
## @param args An array of strings containing the arguments of the clip command.
## @return void
func _on_clip_command_received(_from_username: String, _info: TwitchCommandInfo, args: PackedStringArray) -> void:
	if %UseClipCmd.button_pressed:
		await add_clip(args[0])
		process_clip_queue()
		logger.log("Queue clip command triggered")


## Adds random clips from the user's recent raiders.
## This function adds random clips from the user's recent raiders.
##
## @param count The number of clips to add from the user's recent raiders.
func _on_raider_random_clip_command_received(_from_username: String, _info: TwitchCommandInfo, args: PackedStringArray) -> void:
	if %UseRaiderClipCmd.button_pressed:
		if recent_raider.is_empty():
			return
		var clip_count = 1
		if args.size() > 1 and args[1].is_valid_int():
			clip_count = args[1].to_int()
		add_random_clip(recent_raider, clip_count)


## Handles the event when a raider shoutout command is received.
## This function is called when a raider shoutout command is sent to the script.
## It queues the raider for a shoutout and processes the queue if necessary.
##
## @param _from_username The username of the user who sent the raider shoutout command.
## @param _info The information about the raider shoutout command.
## @param _args An array of strings containing the arguments of the raider shoutout command.
## @return void
func _on_raider_so_command_received(_from_username: String, _info: TwitchCommandInfo, _args: PackedStringArray) -> void:
	if %UseRaiderSOCmd.button_pressed:
		if recent_raider.is_empty():
			return
		queue_shoutout(recent_raider)


## Handles the event when a raider shoutout and random clip command is received.
## This function is called when a raider shoutout and random clip command is sent to the script.
## It queues the raider for a shoutout and adds random clips from the raider to the queue.
##
## @param _from_username The username of the user who sent the raider shoutout and random clip command.
## @param _info The information about the raider shoutout and random clip command.
## @param args An array of strings containing the arguments of the raider shoutout and random clip command.
## @return void
func _on_raider_so_random_clip_command_received(_from_username: String, _info: TwitchCommandInfo, args: PackedStringArray) -> void:
	if %UseRaiderSORandomCmd.button_pressed:
		if recent_raider.is_empty():
			return
		queue_shoutout(recent_raider)
		var clip_count = 1
		if args.size() > 1 and args[1].is_valid_int():
			clip_count = args[1].to_int()
		add_random_clip(recent_raider, clip_count)


## Handles the event when a clip show command is received.
## This function is called when a clip show command is sent to the script.
## It adds random clips from the cache to the queue.
##
## @param _from_username The username of the user who sent the clip show command.
## @param _info The information about the clip show command.
## @param args An array of strings containing the arguments of the clip show command.
## @return void
func _on_clip_show_command_received(_from_username: String, _info: TwitchCommandInfo, args: PackedStringArray) -> void:
	if %UseClipShowCmd.button_pressed:
		self_clip_show_running = false
		if args.size() > 0 and args[0].is_valid_int():
			add_random_clip_from_cache(args[0].to_int())
			return
		add_random_clip_from_cache(1)
		clip_show_running = true
		logger.log("Clip show command triggered")
		process_clip_queue()


## Handles the event when a stop clip show command is received.
## This function is called when a stop clip show command is sent to the script.
## It stops the clip show.
##
## @param _from_username The username of the user who sent the stop clip show command.
## @param _info The information about the stop clip show command.
## @param _args An array of strings containing the arguments of the stop clip show command.
## @return void
func _on_stop_clip_show_command_received(_from_username: String, _info: TwitchCommandInfo, _args: PackedStringArray) -> void:
	if %UseStopClipShowCmd.button_pressed:
		clip_show_running = false
		self_clip_show_running = false


## Handles the event when a self clip show command is received.
## This function is called when a self clip show command is sent to the script.
## It adds random clips from the cache to the queue.
##
## @param _from_username The username of the user who sent the self clip show command.
## @param _info The information about the self clip show command.
## @param args An array of strings containing the arguments of the self clip show command.
## @return void
func _on_self_clip_show_command_received(_from_username: String, _info: TwitchCommandInfo, args: PackedStringArray) -> void:
	if %UseSelfClipShowCmd.button_pressed:
		clip_show_running = false
		if args.size() > 0 and args[0].is_valid_int():
			add_random_self_clip(args[0].to_int())
			return
		add_random_self_clip(1)
		self_clip_show_running = true
		logger.log("Self clip show command triggered")
		process_clip_queue()
