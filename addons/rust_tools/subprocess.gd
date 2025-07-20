## A subprocess that can be launched, either synchronously (blocking) or asynchronously.
@tool
class_name RustToolsSubprocess
extends RefCounted

## Emitted when a subprocess started with [code]run_async[/code] has completed.
signal finished(success: bool)

var _command: String
var _args := PackedStringArray()
var _working_dir := "."

# Attributes of running process.
var _pid := -1
var _poll_thread: Thread
var _stdout_thread: Thread
var _stderr_thread: Thread

## Creates a new subprocess to run the given command (executable).
func _init(command: String) -> void:
	_command = command

## Sets command line arguments to follow after the command itself.
##
## Important: the given args must currently not contain spaces or other characters that are special
## to any shell! If we need that in the future, we'll need to add shell-specific escaping code.
func set_args(args: PackedStringArray) -> void:
	_args = args

## Sets the working directory in which to execute the command. Defaults to the current directory.
func set_working_dir(working_dir: String) -> void:
	_working_dir = working_dir

## Runs the command synchronously, blocking until completed.
## Returns [code]true[/code] if successful.
func run_sync() -> bool:
	var command_line := _shell_command_with_chdir()
	var output := []
	var read_stderr := true
	var open_console := false
	var exit_code := OS.execute(command_line.path, command_line.arguments, output, read_stderr, open_console)
	
	var color_output := RustToolsAnsiEscapeCodes.to_bbcode(output[0])
	print_rich(color_output)

	return exit_code == 0

## Starts the process to run in the background.
## Returns [code]true[/code] if started successfully.
func run_async() -> bool:
	var command_line := _shell_command_with_chdir()
	var blocking := true
	var dict := OS.execute_with_pipe(command_line.path, command_line.arguments, blocking)
	if dict.is_empty():
		return false
	
	var pid: int= dict.pid
	_pid = pid
	
	var stdio: FileAccess = dict.stdio
	var stderr: FileAccess = dict.stderr
	_poll_thread = Thread.new()
	_stdout_thread = Thread.new()
	_stderr_thread = Thread.new()
	_poll_thread.start(func() -> void: _poll_process(pid))
	_stdout_thread.start(func() -> void: _read_process_output(stdio))
	_stderr_thread.start(func() -> void: _read_process_output(stderr))
	
	return true

## Kills the running process.
func kill() -> void:
	if _pid != -1:
		OS.kill(_pid)
		_pid = -1

## Main loop for a thread that regularly polls the subprocess to see if it's finished.
# Takes pid by argument (rather than using self._pid) to avoid data races and locking.
func _poll_process(pid: int) -> void:
	while OS.is_process_running(pid):
		OS.delay_msec(100)
	var exit_code := OS.get_process_exit_code(pid)
	var success := exit_code == 0
	# Use call_deferred to make sure that signal handlers run on the main thread.
	call_deferred("_process_finished", success)

## Called on the main thread once the process is finished.
func _process_finished(success: bool) -> void:
	if _stdout_thread:
		_stdout_thread.wait_to_finish()
		_stdout_thread = null
	
	if _stderr_thread:
		_stderr_thread.wait_to_finish()
		_stderr_thread = null
	
	if _poll_thread:
		_poll_thread.wait_to_finish()
		_poll_thread = null
	
	finished.emit(success)

## Main loop for output-reading threads.
func _read_process_output(stream: FileAccess) -> void:
	while true:
		var line := stream.get_line()
		if stream.get_error() != OK:
			break
		print_rich(RustToolsAnsiEscapeCodes.to_bbcode(line))

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Note that this object will never be deleted while the process is still running,
		# because the threads reading stdout and stderr hold a reference to it.
		# Probably the pending _process_finished call also keeps the object alive, and that is the
		# one that'll clean up (wait on) the helper threads.
		pass

func _shell_command_with_chdir() -> Dictionary:
	# Spawn a shell to change directory first, because Godot's process API does not support that.
	# Using cargo's `--manifest-path` makes it ignore `.cargo/config.toml`, so that's not an option.
	# There is `cargo -C DIR build` but it's nightly only (as of 1.87.0), so that's not an option
	# either.
	
	var os := OS.get_name()
	if os in ["Web", "iOS"]:
		# No process spawning, no Rust toolchain. Can't be done.
		push_error("Rust tools is not supported on %s, since no commands can be launched from the Godot Editor. Contact the developer if you think there is a way." % os)
		return {}
	
	if os == "Windows":
		# In CMD, we need to enclose the _working_dir in double quotes, and thus,
		# need to check if there are unescaped double quotes (an odd number of
		# consecutive quotes). We do so by pattern matching, checking a group of
		# even quotes followed by another quote and no other quotes before or after.
		var pattern := RegEx.create_from_string("(?<!\")(?:\"\")*\"(?!\")")
		if pattern.search(_working_dir) != null:
			push_error("Path %s contains an unescaped double quote, which is not supported" % _working_dir)
			return {}
		
		# Similar to Unix, but using cmd.exe and /c, and requiring double quotes instead.
		return {
			"path": "cmd.exe",
			"arguments": ["/c", (
				"cd \"%s\" && %s %s" %
				[_working_dir, _command, ' '.join(_args)]
			)],
		}
	
	# From the manual: "Enclosing characters in single quotes preserves the literal
	# value of each character within the quotes. A single quote may not occur between
	# single quotes, even when preceded by a backslash."
	# This case is rare enough that we don't need to support it, but we can detect it.
	if "'" in _working_dir:
		push_error("Path %s contains a single quote, which is not supported" % _working_dir)
		return {}
	
	# All other platforms are Unix-like enough to have an sh-compatible shell.
	# We send a warning to those Operating Systems for which support is experimental.
	if os in ["Android", "macOS"]:
		push_warning("Support for %s is still experimental. Contact the developer in case of both success and failure." % os)
	
	return {
		"path": "/bin/sh",
		"arguments": ["-c", (
				"cd '%s' && %s %s" %
				[_working_dir, _command, ' '.join(_args)]
			)],
	}
