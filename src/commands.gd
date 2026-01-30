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
	#reset size an playing state
	cur_size = min_size
	scale_source(cur_size.x, cur_size.y)
	# if the clip queue has more clips, play them after a timeout
	if not clip_queue.is_empty():
		await get_tree().create_timer(queue_delay).timeout
		process_queue()


## Handles clip started event
func _on_clip_started() -> void:
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
func _on_obs_input_settings_set() -> void:
	# once we are sure that the clip has been set, we can clear it from
	# the app
	if current_clip == null:
		return
	current_clip = null
	# Restart the media timer at a higher rate so we can start animations
	# as soon as the clip actually starts playing
	%OBSMediaTimer.start(0.05)


## Handles OBS set input settings error
func _on_obs_set_input_settings_error() -> void:
	# if we fail to set the input, we need to reset state to try again
	reset_playback()


## Handles source filter settings error
func _on_source_filter_settings_error() -> void:
	# if we fail to set the filter, we need to reset state so the next
	# attempt will work
	reset_animations()


## Check the status of the media source.
## This is needed as we could miss a message and because the states that OBS
## sends aren't truly representative of if the clip is truly playing
func _on_obs_media_timer_timeout() -> void:
	if obs.obs_connected:
		obs.get_media_input_status(source_name)


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
func _on_obs_got_media_input_status(media_state, media_duration, media_cursor) -> void:
	if media_state == null:
		return
	if media_duration == null:
		media_duration = 0.0
	if media_cursor == null:
		media_cursor = 0.0
	# Check if media is playing
	# Even if the state says it's playing, if the media_duration is 0.0, it's not actually loaded
	# Furthermore if the cursor isn't beyond 0.0, we can't be sure the clip is ready to actually play
	if media_state == obs.MediaInputStates.OBS_MEDIA_STATE_PLAYING and media_duration > 0.0 and media_cursor > 0.0:
		# If state goes from buffering to playing then start animations
		if !clip_playing:
			clip_playing = true
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
	# if we have reached the maximum size, stop animating
	if cur_size.x >= max_size.x and cur_size.y >= max_size.y:
		resize_time_elapsed = 0.0
		clip_resizing = false
		return
	# keep track of the total time spent on the resize animation
	resize_time_elapsed += delta
	# calculate the new size based on the elapsed time
	if cur_size.x < max_size.x:
		var progress_ratio = resize_time_elapsed / time_to_scale
		cur_size.x = min_size.x + ((max_size.x - min_size.x) * progress_ratio)
		if cur_size.x > max_size.x:
			cur_size.x = max_size.x
	if cur_size.y < max_size.y:
		var progress_ratio = resize_time_elapsed / time_to_scale
		cur_size.y = min_size.y + ((max_size.y - min_size.y) * progress_ratio)
		if cur_size.y > max_size.y:
			cur_size.y = max_size.y
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


## Connect to OBS if it is not already connected
## will wait for the connection before proceeding
func wait_obs_ready():
	if obs.is_connected:
		return
	obs.enable_connect()
	await obs.obs_authenticated


## Checks if OBS is ready, will connect if not ready,
## but immediately return false if not connected when called.
## Does not wait for the connection to complete.
func obs_ready() -> bool:
	if obs.is_connected:
		return true
	obs.enable_connect()
	return false


## Scales the source in OBS to the specified width and height.
## @param w The target width.
## @param h The target height.
func scale_source(w: int, h: int):
	if not obs_scale:
		return
	if obs.obs_connected:
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
	if obs.obs_connected:
		obs.set_source_filter_settings(source_name, fade_filter_name, { "opacity": opacity })


## Enables a specified source filter for the current source.
##
## @param filter_name - The name of the filter to enable.
func enable_source_filter(filter_name: String):
	if obs.obs_connected:
		obs.set_source_filter_enabled(source_name, filter_name, true)


## Processes the clip queue by playing the next clip if available.
## Waits for OBS to be ready before attempting to play.
## Does nothing if the queue is empty or if a clip is already playing.
func process_queue():
	# Wait for OBS to be ready before proceeding
	await wait_obs_ready()
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
	logger.log(
		"Playing clip: \"%s\" from %s clipped by %s"
		% [clip.title, clip.broadcaster_name, clip.creator_name],
	)
	current_clip = clip
	obs.set_input_settings(source_name, { "input": clip.url })


## This function clears the current clip by setting the OBS input settings to an empty string.
func clear_clip():
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

	# Pick a random clip from the list
	var clip = clips.data.pick_random()

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
