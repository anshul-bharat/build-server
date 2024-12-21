package main

import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"

import "http"

WATCHED_FILES: map[string]os.File_Time
COMMANDS: map[string]([dynamic]string)

start_server := false
server_thread: ^thread.Thread = nil
stop_server := false
requires_reload := false

main :: proc() {
	when ODIN_DEBUG {
		context.logger = log.create_console_logger()
		defer log.destroy_console_logger(context.logger)
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {

			fmt.println("Exiting")
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	_main()
}

_main :: proc() {

	WATCHED_FILES = map[string]os.File_Time{}
	COMMANDS = map[string]([dynamic]string){}

	defer {
		for k, v in WATCHED_FILES {
			delete(k)
		}
		delete(WATCHED_FILES)
		for k, v in COMMANDS {
			delete(v)
		}
		delete(COMMANDS)
	}

	generate_agrs_map(&COMMANDS)

	if start_server {
		server_thread = thread.create(start_web_server)
		if server_thread != nil {
			server_thread.init_context = context
			server_thread.user_index = 0
			thread.start(server_thread)
		}
	}

	log.info("Build Server Started")
	init_file_times()
	check_files()
	stop_server = true
	thread.join(server_thread)
	thread.destroy(server_thread)
}

start_web_server :: proc(t: ^thread.Thread) {
	if start_server == false {
		return
	}

	assert(len(COMMANDS["-s"]) == 1, "No webserver directory specified")

	server := new(http.Server)
	defer {
		delete(server.views_dir)
		delete(server.public_dir)
		free(server)
	}
	server.public_dir = filepath.join(
		{os.get_current_directory(context.temp_allocator), COMMANDS["-s"][0]},
	)
	server.views_dir = os.get_current_directory()
	server.response_modifiers = {}
	defer delete(server.response_modifiers)
	http.init_server(server)

	modifier: http.ResponseModifier_Proc = proc(request: ^http.Request, response: ^http.Response) {
		if response.headers["Content-Type"] == http.CONTENT_TYPES[".html"] {
			if r := response.varient.(^http.TextResponse); r != nil {
				r.body = strings.join({r.body, JAVASCRIPT_ATTACHMENT}, "", context.temp_allocator)
			}
		}
	}
	append(&(server.response_modifiers), modifier)

	server.route_map = map[string]http.Route_Proc{}
	defer delete(server.route_map)
	server.route_map["/ws"] = proc(request: ^http.Request) -> ^http.Response {
		response := http.new_text_response()
		response.headers["Content-Type"] = http.CONTENT_TYPES[".json"]
		if requires_reload == true {
			response.body = `{"reload": true}`
			requires_reload = false
		} else {
			response.body = `{"reload": false}`
		}

		return response
	}


	http.serve(server, proc() -> bool {return stop_server == false})
}

Walk_Proc :: proc(
	info: os.File_Info,
	in_err: os.Error,
	user_data: rawptr,
) -> (
	err: os.Error = nil,
	skip_dir: bool = false,
) {

	relative_path, _ := filepath.rel(
		os.get_current_directory(context.temp_allocator),
		info.fullpath,
		context.temp_allocator,
	)
	relative_path, _ = filepath.to_slash(relative_path, context.temp_allocator)
	// fmt.println("# ",info.fullpath)
	if (should_call_handler(relative_path) == false) {
		return
	}

	if info.is_dir == false {
		files_list := transmute(^[dynamic]string)user_data
		// append_elem(files_list, relative_path)
		filename, err := strings.clone(relative_path)
		// defer delete(filename)
		if (err == nil) {
			append_elem(files_list, filename)
		}
	}

	return
}

init_file_times :: proc() {
	files := [dynamic]string{}

	for root in COMMANDS["-r"] {
		filepath.walk(root, Walk_Proc, &files)
	}

	for file in files {
		file_time := os.last_write_time_by_name(file) or_continue
		WATCHED_FILES[file] = file_time
	}

	delete(files)
}

check_files :: proc() {
	close_app := false
	i := 0
	for close_app == false {
		i += 1
		files := [dynamic]string{}
		defer delete(files)

		skip := false
		for root in COMMANDS["-r"] {
			filepath.walk(root, Walk_Proc, &files)
		}

		for filename in files {
			file_time := os.last_write_time_by_name(filename) or_continue

			is_old_file := filename in WATCHED_FILES
			if is_old_file == false || WATCHED_FILES[filename] < file_time {
				skip = true
				change_handler(filename)
				// fmt.printfln("{} : {} : {}", filename, WATCHED_FILES[filename], file_time)
			}

			WATCHED_FILES[filename] = file_time

			delete(filename)
		}

		free_all(context.temp_allocator)

		time.sleep(time.Second)

		 if (i > 20) {
			return
		}
	}
}

should_call_handler :: proc(filepath: string) -> bool {
	// if true {
	// 	return true
	// }
	for pattern in COMMANDS["-r"] {
		if strings.contains(filepath, pattern) == false {
			return false
		}
	}

	for pattern in COMMANDS["-i"] {
		if strings.contains(filepath, pattern) {
			return false
		}
	}

	should_call := false
	if len(COMMANDS["-w"]) == 0 {
		should_call = true
	} else {
		for pattern in COMMANDS["-w"] {
			if strings.contains(filepath, pattern) {
				should_call = true
				break
			}
		}
	}

	return should_call
}

change_handler :: proc(filename: string) {
	fmt.printfln("Updated: {}", filename)
	for command, i in COMMANDS["-x"] {
		cmd: cstring = strings.clone_to_cstring(command, context.temp_allocator)
		libc.system(cmd)
		requires_reload = true
		free_all(context.temp_allocator)
	}
}

generate_agrs_map :: proc(args_map: ^map[string][dynamic]string) {
	args := os.args

	args_map["-x"] = {}
	args_map["-i"] = {"/.git"}
	args_map["-w"] = {}
	args_map["-s"] = {}
	args_map["-r"] = {}

	is_error := true

	for arg in args {
		if strings.has_prefix(arg, "-x=") {
			cmd := strings.trim_prefix(arg, "-x=")
			append(&args_map["-x"], cmd)
			is_error = false
		} else if strings.has_prefix(arg, "-i=") {
			cmd := strings.trim_prefix(arg, "-i=")
			append(&args_map["-i"], cmd)
			is_error = false
		} else if strings.has_prefix(arg, "-r=") {
			cmd := strings.trim_prefix(arg, "-r=")
			append(&args_map["-r"], cmd)
			is_error = false
		} else if strings.has_prefix(arg, "-w=") {
			cmd := strings.trim_prefix(arg, "-w=")
			append(&args_map["-w"], cmd)
			is_error = false
		} else if strings.has_prefix(arg, "-s=") {
			cmd := strings.trim_prefix(arg, "-s=")
			append(&args_map["-s"], cmd)
			is_error = false
			start_server = true
		} else {
			is_error = true
		}
	}

	if is_error == true {
		log.panic(
			"Invalid args: Usage > build-server -x=\"{Execute command}\" -w=\"{Watch files pattern}\" -i=\"{Ignore files pattern}\" ",
		)
	}

	if (len(args_map["-r"]) == 0) {
		append(&args_map["-r"], "./")
	}

}

JAVASCRIPT_ATTACHMENT := `
	<script>
	setInterval(function(){
		fetch('/ws')
		.then(res => res.json())
		.then(res => {
			if (res.reload == true) {
				window.location.reload();
			}
		})
	}, 1000)
	</script>
`

