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

extends RichTextLabel

var app_logger := AppLogger.new()

const ESCAPE_CSI = char(27) +"["
var data_buffer = "" # Used to identify escape sequences

var is_bold = false
var is_italic = false
var current_color = ""

const color_values = [
	"#555555", # real black would not be readable
	"#ff7733", # orangish pale red
	"#00ff00", # green
	"#ffff00", # yellow
	"#6666ff", # paler blue
	"#ffff00", # magenta
	"#00ffff", # cyan
	"#ffffff", # white
]

class AppLogger extends Logger:
	
	signal log_message(message: String, error: bool)
	signal log_error(
				function: String,
				file: String,
				line: int,
				code: String,
				rationale: String,
				editor_notify: bool,
				error_type: int,
				script_backtraces: Array[ScriptBacktrace])
	
	# Note that this method is not called for messages that use
	# `push_error()` and `push_warning()`, even though these are printed to stderr.
	func _log_message(message: String, error: bool) -> void:
		if error or OS.is_debug_build():
			log_message.emit(message, error)
		# Do something with `message`.
		# `error` is `true` for messages printed to the standard error stream (stderr) with `print_error()`.
		# Note that this method will be called from threads other than the main thread, possibly at the same
		# time, so you will need to have some kind of thread-safety as part of it, like a Mutex.

	func _log_error(
			function: String,
			file: String,
			line: int,
			code: String,
			rationale: String,
			editor_notify: bool,
			error_type: int,
			script_backtraces: Array[ScriptBacktrace]
	) -> void:
		log_error.emit(function, file, line, code, rationale, editor_notify, error_type, script_backtraces)
		# Do something with the error. The error text is in `rationale`.
		# See the Logger class reference for details on other parameters.
		# Note that this method will be called from threads other than the main thread, possibly at the same
		# time, so you will need to have some kind of thread-safety as part of it, like a Mutex.
		

# Use `_init()` to initialize the logger as early as possible, which ensures that messages
# printed early are taken into account. However, even when using `_init()`, the engine's own
# initialization messages are not accessible.
func _init() -> void:
	OS.add_logger(app_logger)

func _exit_tree() -> void:
	OS.remove_logger(app_logger)

func log(_text: String) -> void:
	append_text("[code]" + _text + "[/code]\n")

func log_success(_text: String) -> void:
	append_text("[code][color=#00FF00]" + _text + "[/color][/code]\n")

func log_warn(_text: String) -> void:
	append_text("[code][color=#FF8800]" + _text + "[/color][/code]\n")

func log_error(_text: String) -> void:
	append_text("[code][color=#FF0000]" + _text + "[/color][/code]\n")


func ansi_to_bbcode(text_line: String) -> String:
	var _text = text_line
	
	var s = "" # s goes to screen regardless of escape codes
	#            e.g. in "Hello \x1b[31mworld!\x1b0m!"
	#            the part "Hello " goes to screen even if the escape
	#            sequence is not yet fully received
	
	while ESCAPE_CSI in _text:
		var parts = _text.split(ESCAPE_CSI, true, 1)
		s += parts[0]
		_text = parts[1]
		
		if "m" in _text:
			parts = _text.split("m", true, 1)
			_text = parts[1]
			
			s += process_escape_code(parts[0])
		
		else:
			# Escape not fully received yet
			data_buffer = ESCAPE_CSI + _text
			_text = ""
			break
	
	if _text.length() > 0:
		s += _text
	
	return s


func process_escape_code(code_text: String) -> String:
	var code_items = code_text.split(";")
	
	var request_bold = null
	var request_italic = null
	var request_color = null
	
	for code in code_items:
		match code:
			"0": # Reset all
				request_bold = false
				request_italic = false
				request_color = ""
			
			"1":
				request_bold = true
			"22":
				request_bold = false
			
			"3":
				request_italic = true
			"23":
				request_italic = false
			
			"39":
				request_color = ""
			
			_:
				var code_int = int(code)
				if (code_int >= 30) and (code_int <= 37):
					var color_index = code_int - 30
					request_color = color_values[color_index]

	if code_items.size() == 5:
		request_color = "#" + Color.from_rgba8(int(code_items[2]), int(code_items[3]), int(code_items[4])).to_html(false)
		#"#%X%X%X" % [code_items[2], code_items[3], code_items[4]]
	
	# Invalidate requests which don't change anything
	if (request_italic != null) and (request_italic == is_italic):
		request_italic = null
	if (request_bold != null) and (request_bold == is_bold):
		request_bold = null
	if (request_color != null) and (request_color == current_color):
		request_color = null
	
	# entanglement ("[i]  [b]   [/i]   [/b]") is not supported
	# "[i]  [/i][b][i]   [/i]   [/b]" must be done instead
	# italics are inside bold, which are inside color
	
	var s = ""
	
	var has_to_close_italic = is_italic and ((request_italic == false) or (request_bold != null) or (request_color != null))
	var has_to_close_bold = is_bold and ((request_bold == false) or (request_color != null))
	var has_to_open_bold = (is_bold and (request_bold == null)) or (request_bold == true)
	var has_to_open_italic = (is_italic and (request_italic == null)) or (request_italic == true)
	
	if has_to_close_italic:
		s += "[/i]"
		is_italic = false
	
	if has_to_close_bold:
		s += "[/b]"
		is_bold = false
	
	if (current_color != ""):
		if (request_color != null):
			s += "[/color]"
			current_color = ""
	
	if (request_color != null):
		if request_color != "":
			s += "[color=%s]" % request_color
		current_color = request_color
	
	if has_to_open_bold: 
		s += "[b]"
		is_bold = true
	
	if has_to_open_italic: 
		s += "[i]"
		is_italic = true
	
	
	return s


func reset_formats() -> String:
	var s = ""
	
	if is_italic:
		s += "[/i]"
		is_italic = false
	if is_bold:
		s += "[/b]"
		is_bold = false
	if current_color != "":
		s += "[/color]"
		current_color = ""
	
	return s

func set_color(color_name: String = "") -> String:
	# Both bold and italic are inside colors and boundaries should be regenerated
	
	var s = ""
	
	if color_name == current_color:
		return ""
	
	if is_italic:
		s += "[/i]"
	if is_bold:
		s += "[/b]"
	if (current_color != ""):
		s += "[/color]"
	
	current_color = color_name
	if current_color != "":
		s += "[color=%s]" % current_color
	if is_bold:
		s += "[b]"
	if is_italic:
		s += "[i]"
	
	return s


func set_bold(should_be_bold: bool = false) -> String:
	# Italics are inside bold and boundaries must be regenerated
	
	var s = ""
	
	if is_bold == should_be_bold:
		return ""
	
	if is_italic:
		s += "[/i]"
	
	is_bold = should_be_bold
	if (is_bold):
		s += "[b]"
	else:
		s += "[/b]"
	
	if is_italic:
		s += "[i]"
	
	
	return s

func set_italic(should_be_italic: bool = false) -> String:
	var s = ""
	
	if is_italic == should_be_italic:
		return ""
	
	is_italic = should_be_italic
	
	if is_italic:
		s += "[i]"
	else:
		s += "[/i]"
	
	return s
