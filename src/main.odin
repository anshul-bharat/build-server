package main

import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"

import "http"

WATCHED_FILES: map[string]os.File_Time
COMMANDS: map[string][dynamic]string

start_server := false
requires_reload := false

main :: proc() {
	files, err := filepath.glob("*")

	COMMANDS = generate_agrs_map()

	context.logger = log.create_console_logger()

	if err != filepath.Match_Error.None {
		log.error("Something went wrong!, cannot read files")
		return
	}

	for file in files {
		file_time, err := os.last_write_time_by_name(file)
		if err != os.ERROR_NONE {
			log.errorf("Cannot read: {}", file)
			return
		}

		WATCHED_FILES[file] = file_time
	}

	if start_server {
		t := thread.create(start_web_server)
		if t != nil {
			t.init_context = context
			t.user_index = 0
			thread.start(t)
		}
	}

	log.info("Build Server Started")

	check_files()
}

start_web_server :: proc(t: ^thread.Thread) {
	if start_server == false {
		return
	}

	assert(len(COMMANDS["-s"]) == 1, "No webserver directory specified")

	server := http.Server {
		public_dir         = filepath.join({os.get_current_directory(), COMMANDS["-s"][0]}),
		views_dir          = os.get_current_directory(),
		response_modifiers = {},
	}

	http.init_server(&server)

	modifier: http.ResponseModifier_Proc = proc(request: ^http.Request, response: ^http.Response) {
		if response.headers["Content-Type"] == http.CONTENT_TYPES[".html"] {
			if r := response.varient.(^http.TextResponse); r != nil {
				r.body = strings.join({r.body, JAVASCRIPT_ATTACHMENT}, "")
			}
		}
	}
	append(&server.response_modifiers, modifier)

	server.route_map = map[string]http.Route_Proc{}
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


	http.serve(&server)
}

Walk_Proc :: proc(
	info: os.File_Info,
	in_err: os.Error,
	user_data: rawptr,
) -> (
	err: os.Error,
	skip_dir: bool,
) {
	if info.is_dir == false {
		files_list := transmute(^[dynamic]string)user_data
		output, _ := strings.replace_all(
			info.fullpath,
			os.get_current_directory(),
			"",
			context.temp_allocator,
		)
		output, _ = strings.replace_all(output, "\\", "/", context.temp_allocator)
		output, _ = strings.replace(output, "/", "", 1, context.temp_allocator)
		append_elem(files_list, output)
	}
	return nil, false
}

check_files :: proc() {

	for true {
		files: [dynamic]string
		filepath.walk("./", Walk_Proc, &files)
		for file in files {
			file_time := os.last_write_time_by_name(file) or_continue

			new_file := file in WATCHED_FILES
			if new_file == false {
				WATCHED_FILES[file] = file_time
				change_handler(file)
				break
			}

			last_update_time := WATCHED_FILES[file]
			if last_update_time < file_time {
				WATCHED_FILES[file] = file_time
				change_handler(file)
			}

		}
		delete(files)
		time.sleep(time.Second)
	}

}

change_handler :: proc(filename: string) {
	for pattern in COMMANDS["-i"] {
		if strings.contains(filename, pattern) {
			return
		}
	}

	should_call_handler := false
	if len(COMMANDS["-w"]) == 0 {
		should_call_handler = true
	}

	for pattern in COMMANDS["-w"] {
		if strings.contains(filename, pattern) {
			should_call_handler = true
			break
		}
	}

	if should_call_handler == true {
		log.infof("Updated: {}", filename)
		for command, i in COMMANDS["-x"] {
			cmd: cstring = strings.clone_to_cstring(command)
			libc.system(cmd)
			log.info("************************")
			requires_reload = true
		}
	}
}

generate_agrs_map :: proc() -> map[string][dynamic]string {
	args := os.args

	args_map: map[string][dynamic]string
	args_map["-x"] = {}
	args_map["-i"] = {}
	args_map["-w"] = {}
	args_map["-s"] = {}


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

	return args_map
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

