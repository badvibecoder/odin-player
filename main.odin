package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:sys/linux"
import "core:sys/posix"
import "core:unicode/utf8"
import ma "vendor:miniaudio"

// Phase 5: file-browser navigation pane + now-playing pane + marquee + seek.
//
// Navigation (root-locked, shows folders + audio files only):
//   [Up/Down]      Move selection
//   [Right/Enter]  Open folder / play file
//   [Left]         Go up to parent folder
//
// Playback:
//   [Space]        Play / Pause
//   [w]/[s]        Volume up / down
//   [a]/[d]        Seek backward / forward (tap = 10s, hold = ramp up)
//   [n]/[b]        Next / previous track (within the current folder)
//
//   [r]            Toggle shuffle
//   [l]            Cycle loop mode (All -> One -> Off)
//   [p]            Toggle periodic auto-save
//   [c]            Cycle color scheme
//   [q]            Quit (restores terminal + saves config)

VOLUME_STEP :: 0.05
BAR_WIDTH   :: 26

SEEK_BASE           :: 10.0 // seconds per seek tap
SEEK_MAX_LEVEL      :: 6    // max ramp level -> 60s per repeat
SEEK_REPEAT_WINDOW  :: 400 * time.Millisecond

MARQUEE_PAD    :: 4
MARQUEE_WIDTH  :: 36 // fixed "LCD" display width
MARQUEE_SPEED  :: 250 * time.Millisecond

// How often to auto-save progress, so an ungraceful shutdown (crash, power
// loss, SIGKILL) doesn't lose a long audiobook/lecture position.
AUTOSAVE_INTERVAL :: 30 * time.Second

TITLE_ROW       :: 1
NOW_ROW         :: 2
STATUS_ROW      :: 3
PROGRESS_ROW    :: 4
NAV_HEADER_ROW  :: 5
NAV_LIST_ROW    :: 6

FOOTER1 :: "↑/↓ Move   ← Up   →/Enter Open   Space Play/Pause   w/s Volume"
FOOTER2 :: "a/d Seek   n/b Prev/Next   r Shuffle   l Loop   p Autosave   c Color   q Quit"

RESET :: "\x1b[0m"

Loop_Mode :: enum int {
	All = 0,
	One = 1,
	Off = 2,
}

Track :: struct {
	path: string, // full path used to load the audio
	name: string, // display name (filename stem, underscores -> spaces)
}

Entry :: struct {
	name:   string, // display name ("..", folder name, or track stem)
	path:   string, // full path (or parent path for "..")
	is_dir: bool,
}

App :: struct {
	engine:      ma.engine,
	sound:       ma.sound,

	// Playback playlist: the audio files of the folder currently being played.
	tracks:      [dynamic]Track,
	current:     int,   // index of the loaded track within `tracks`

	// Browser state.
	cwd:         string, // current directory in the navigation pane
	entries:     [dynamic]Entry,
	selection:   int,    // selected entry index
	scroll:      int,    // top visible entry index
	rows:        int,    // terminal height
	cols:        int,    // terminal width

	playing:     bool,
	volume:      f32,
	loaded:      bool,   // whether `sound` currently holds a loaded track
	sample_rate: u32,    // cached data-source sample rate (Hz)

	scheme:      int,    // current color scheme index
	loop:        Loop_Mode,
	random:      bool,
	autosave:    bool,   // whether periodic auto-save is enabled

	directory:   string, // root directory (navigation is locked here)
	marquee_start: time.Tick,
}

Key :: enum {
	None,
	Quit,
	Toggle_Play,
	Volume_Up,
	Volume_Down,
	Seek_Back,
	Seek_Forward,
	Next_Track,
	Prev_Track,
	Nav_Up,
	Nav_Down,
	Nav_Open,
	Nav_Parent,
	Cycle_Color,
	Cycle_Loop,
	Toggle_Random,
	Toggle_Autosave,
}

Key_Parser :: struct {
	in_esc: bool,
	in_csi: bool,
}

Seek_State :: struct {
	dir:   int, // -1 back, +1 forward, 0 none
	level: int,
	last:  time.Tick,
}

// struct winsize (Linux termios.h) for TIOCGWINSZ.
Winsize :: struct {
	row:    u16,
	col:    u16,
	xpixel: u16,
	ypixel: u16,
}

// ANSI color schemes, cycled with the 'c' key.
Color_Scheme :: struct {
	title:     string,
	now:       string,
	highlight: string,
	bar:       string,
	footer:    string,
}

color_schemes := [4]Color_Scheme{
	{title = "\x1b[1;36m", now = "\x1b[1;33m", highlight = "\x1b[7m",     bar = "\x1b[32m", footer = "\x1b[2m"},
	{title = "\x1b[1;35m", now = "\x1b[1;36m", highlight = "\x1b[7;35m", bar = "\x1b[33m", footer = "\x1b[2m"},
	{title = "\x1b[1;32m", now = "\x1b[1;34m", highlight = "\x1b[7;34m", bar = "\x1b[36m", footer = "\x1b[2m"},
	{title = "",           now = "",           highlight = "\x1b[7m",     bar = "",           footer = ""},
}

// Config mirrors the persisted JSON in ~/.odin-player/config.json.
Config :: struct {
	directory:    string `json:"directory"`,
	volume:       f32    `json:"volume"`,
	color_scheme: int    `json:"color_scheme"`,
	loop:         int    `json:"loop"`,
	random:       bool   `json:"random"`,
	track_path:   string `json:"track_path"`,
	position:     f64    `json:"position"`, // seconds into the last track
	autosave:     bool   `json:"autosave"`,
}

// Set by the SIGWINCH handler, polled by the main loop.
winch_flag: b32

main :: proc() {
	arg_dir := ""
	if len(os.args) > 1 {
		arg_dir = os.args[1]
	}

	app := App{volume = 1.0, autosave = true}

	// --- Load persisted preferences ---
	cfg := Config{directory = "testmusic", volume = 1.0, color_scheme = 0, loop = 0, random = false, autosave = true}
	load_config(&cfg)

	root := arg_dir if arg_dir != "" else cfg.directory
	if root == "" {
		root = "testmusic"
	}
	// Resolve the root to an absolute path so fullpaths (which are absolute)
	// line up with it for the resume check and path comparisons.
	if abs_root, aerr := os.get_absolute_path(root, context.allocator); aerr == nil {
		app.directory = abs_root
	} else {
		app.directory = strings.clone(root)
	}
	app.cwd = strings.clone(app.directory)
	app.volume = clamp(cfg.volume, 0.0, 1.0)
	app.scheme = clamp(cfg.color_scheme, 0, len(color_schemes) - 1)
	app.loop = Loop_Mode(cfg.loop)
	if app.loop < .All || app.loop > .Off {
		app.loop = .All
	}
	app.random = cfg.random
	app.autosave = cfg.autosave

	// Seed the RNG used for shuffle.
	rand.reset(u64(time.to_unix_nanoseconds(time.now())))

	// --- Initialize the miniaudio engine ---
	engine_config := ma.engine_config_init()
	engine_config.periodSizeInMilliseconds = 40
	if res := ma.engine_init(&engine_config, &app.engine); res != .SUCCESS {
		fmt.eprintf("error: failed to initialize audio engine: %v\n", res)
		os.exit(1)
	}
	defer ma.engine_uninit(&app.engine)

	// --- Build the browser for the root directory ---
	load_dir(&app)
	defer free_entries(&app.entries)
	defer free_tracks(&app.tracks)
	defer delete(app.cwd)
	defer delete(app.directory)

	// --- Resume the last track/position, if it still exists under the root ---
	if cfg.track_path != "" && is_under_root(cfg.track_path, app.directory) {
		build_folder_playlist(&app, filepath.dir(cfg.track_path))
		idx := find_track_by_path(&app, cfg.track_path)
		if idx >= 0 {
			load_track(&app, idx, cfg.position, false)
		}
	}
	defer unload_sound(&app)

	// --- Switch the terminal into raw, non-blocking mode ---
	original, raw_ok := enter_raw_mode()
	if !raw_ok {
		fmt.eprintf("error: failed to switch terminal to raw mode\n")
		return
	}
	defer restore_terminal(original)

	setup_winch_handler()

	app.rows, app.cols = get_terminal_size()
	clear_screen()
	defer save_config(&app)

	parser: Key_Parser
	seek: Seek_State
	last_save := time.tick_now()
	loop: for {
		if winch_flag {
			winch_flag = false
			clear_screen()
		}
		app.rows, app.cols = get_terminal_size()
		draw(&app)

		buf: [16]u8
		n := read_stdin(buf[:])
		for i in 0 ..< n {
			key := key_parser_feed(&parser, buf[i])
			switch key {
			case .Quit:
				break loop
			case .Toggle_Play:
				toggle_play(&app)
			case .Volume_Up:
				change_volume(&app, +VOLUME_STEP)
			case .Volume_Down:
				change_volume(&app, -VOLUME_STEP)
			case .Seek_Back:
				do_seek(&seek, &app, -1)
			case .Seek_Forward:
				do_seek(&seek, &app, +1)
			case .Next_Track:
				next_track(&app)
			case .Prev_Track:
				prev_track(&app)
			case .Nav_Up:
				move_selection(&app, -1)
			case .Nav_Down:
				move_selection(&app, +1)
			case .Nav_Open:
				open_selection(&app)
			case .Nav_Parent:
				navigate_up(&app)
			case .Cycle_Color:
				app.scheme = (app.scheme + 1) % len(color_schemes)
			case .Cycle_Loop:
				cycle_loop(&app)
			case .Toggle_Random:
				toggle_random(&app)
			case .Toggle_Autosave:
				toggle_autosave(&app)
			case .None:
			}
		}

		// When a track finishes naturally, honor loop + shuffle settings.
		if app.playing && app.loaded && !ma.sound_is_playing(&app.sound) {
			on_track_end(&app)
		}

		// Periodically persist progress (silently) so a non-graceful exit
		// doesn't lose the current track/position.
		if app.autosave && time.tick_diff(last_save, time.tick_now()) >= AUTOSAVE_INTERVAL {
			save_config(&app, true)
			last_save = time.tick_now()
		}

		time.sleep(16 * time.Millisecond)
	}
}

// --- directory browser ---

// load_dir reads `cwd` and rebuilds the browser entries: folders + audio files
// only, hidden entries skipped, ".." prepended when not at the root.
load_dir :: proc(app: ^App) {
	free_entries(&app.entries)
	app.entries = make([dynamic]Entry)
	app.selection = 0
	app.scroll = 0

	if app.cwd != app.directory {
		// Clone the name too: free_entries deletes it, so it must not be a
		// string literal.
		append(&app.entries, Entry{name = strings.clone(".."), path = strings.clone(filepath.dir(app.cwd)), is_dir = true})
	}

	files, err := os.read_all_directory_by_path(app.cwd, context.allocator)
	if err != nil {
		return
	}
	for fi in files {
		if strings.has_prefix(fi.name, ".") {
			delete(fi.fullpath, context.allocator)
			continue
		}
		if fi.type == .Directory {
			append(&app.entries, Entry{
				name   = strings.clone(fi.name),
				path   = strings.clone(fi.fullpath),
				is_dir = true,
			})
		} else if fi.type == .Regular && is_audio(filepath.ext(fi.fullpath)) {
			append(&app.entries, Entry{
				name   = track_name(filepath.stem(fi.fullpath)),
				path   = strings.clone(fi.fullpath),
				is_dir = false,
			})
		}
		delete(fi.fullpath, context.allocator)
	}
	slice.sort_by(app.entries[:], entry_less)
}

free_entries :: proc(entries: ^[dynamic]Entry) {
	for e in entries^ {
		delete(e.name)
		delete(e.path)
	}
	delete(entries^)
}

entry_less :: proc(a, b: Entry) -> bool {
	if a.is_dir != b.is_dir {
		return a.is_dir // folders first
	}
	return a.name < b.name
}

move_selection :: proc(app: ^App, delta: int) {
	if len(app.entries) == 0 {
		return
	}
	app.selection = clamp(app.selection + delta, 0, len(app.entries) - 1)
}

open_selection :: proc(app: ^App) {
	if app.selection < 0 || app.selection >= len(app.entries) {
		return
	}
	e := app.entries[app.selection]
	if e.is_dir {
		// Enter the folder.
		delete(app.cwd)
		app.cwd = strings.clone(e.path)
		load_dir(app)
	} else {
		play_file(app, e.path)
	}
}

navigate_up :: proc(app: ^App) {
	if app.cwd == app.directory {
		return // already at root
	}
	// Clone the parent before freeing the old cwd (filepath.dir returns a
	// slice that points into app.cwd).
	new_cwd := strings.clone(filepath.dir(app.cwd))
	delete(app.cwd)
	app.cwd = new_cwd
	load_dir(app)
}

// play_file plays the given file and makes its folder the playback playlist.
play_file :: proc(app: ^App, path: string) {
	build_folder_playlist(app, filepath.dir(path))
	idx := find_track_by_path(app, path)
	if idx >= 0 {
		load_track(app, idx)
	}
}

// build_folder_playlist sets `tracks` to the audio files of `folder` (sorted).
build_folder_playlist :: proc(app: ^App, folder: string) {
	free_tracks(&app.tracks)
	app.tracks = make([dynamic]Track)
	app.current = 0

	files, err := os.read_all_directory_by_path(folder, context.allocator)
	if err != nil {
		return
	}
	for fi in files {
		if strings.has_prefix(fi.name, ".") {
			delete(fi.fullpath, context.allocator)
			continue
		}
		if fi.type == .Regular && is_audio(filepath.ext(fi.fullpath)) {
			append(&app.tracks, Track{
				path = strings.clone(fi.fullpath),
				name = track_name(filepath.stem(fi.fullpath)),
			})
		}
		delete(fi.fullpath, context.allocator)
	}
	slice.sort_by(app.tracks[:], track_less)
}

is_audio :: proc(ext: string) -> bool {
	return strings.equal_fold(ext, ".mp3") || strings.equal_fold(ext, ".wav")
}

// is_under_root reports whether `path` is `root` itself or inside it.
is_under_root :: proc(path, root: string) -> bool {
	if !strings.has_prefix(path, root) {
		return false
	}
	if len(path) == len(root) {
		return true
	}
	return path[len(root)] == '/'
}

// track_name derives a display name from a filename stem (underscores -> spaces).
track_name :: proc(stem: string) -> string {
	pretty, allocated := strings.replace_all(stem, "_", " ", context.allocator)
	if allocated {
		return pretty
	}
	return strings.clone(stem, context.allocator)
}

// --- playback ---

// load_track unloads the current sound and loads `tracks[index]`. If
// `seek_seconds` is positive the track is positioned there before playing;
// when `autoplay` is false the track is left paused at that position.
load_track :: proc(app: ^App, index: int, seek_seconds: f64 = 0.0, autoplay: bool = true) {
	if index < 0 || index >= len(app.tracks) {
		return
	}
	unload_sound(app)

	track := app.tracks[index]
	res := ma.sound_init_from_file(
		&app.engine,
		strings.unsafe_string_to_cstring(track.path),
		{.DECODE},
		nil,
		nil,
		&app.sound,
	)
	if res != .SUCCESS {
		fmt.eprintf("error: failed to load %q: %v\n", track.path, res)
		return
	}

	app.loaded = true
	app.current = index
	app.marquee_start = time.tick_now()
	ma.sound_get_data_format(&app.sound, nil, nil, &app.sample_rate, nil, 0)
	ma.sound_set_volume(&app.sound, app.volume)

	if seek_seconds > 0.0 {
		length: u64
		ma.sound_get_length_in_pcm_frames(&app.sound, &length)
		sr := app.sample_rate
		if sr == 0 {
			sr = 44100
		}
		max_sec := f64(length) / f64(sr)
		s := clamp(seek_seconds, 0.0, max_sec)
		ma.sound_seek_to_pcm_frame(&app.sound, u64(s * f64(sr)))
	}

	if autoplay {
		ma.sound_start(&app.sound)
		app.playing = true
	} else {
		app.playing = false
	}
}

unload_sound :: proc(app: ^App) {
	if app.loaded {
		ma.sound_stop(&app.sound)
		ma.sound_uninit(&app.sound)
		app.loaded = false
	}
	app.playing = false
}

advance :: proc(app: ^App) {
	if len(app.tracks) == 0 {
		return
	}
	if app.random {
		load_track(app, random_index(app))
	} else {
		idx := app.current + 1
		if idx >= len(app.tracks) {
			idx = 0
		}
		load_track(app, idx)
	}
}

next_track :: proc(app: ^App) {
	advance(app)
}

prev_track :: proc(app: ^App) {
	if len(app.tracks) == 0 {
		return
	}
	idx := app.current - 1
	if idx < 0 {
		idx = len(app.tracks) - 1
	}
	load_track(app, idx)
}

on_track_end :: proc(app: ^App) {
	if app.loop == .One {
		ma.sound_seek_to_pcm_frame(&app.sound, 0)
		ma.sound_start(&app.sound)
		app.playing = true
		return
	}
	if app.random {
		advance(app)
		return
	}
	if app.loop == .Off && app.current >= len(app.tracks) - 1 {
		ma.sound_seek_to_pcm_frame(&app.sound, 0)
		app.playing = false
	} else {
		advance(app)
	}
}

toggle_play :: proc(app: ^App) {
	if !app.loaded {
		return
	}
	if app.playing {
		ma.sound_stop(&app.sound)
		app.playing = false
	} else {
		ma.sound_start(&app.sound)
		app.playing = true
	}
}

change_volume :: proc(app: ^App, delta: f32) {
	app.volume = clamp(app.volume + delta, 0.0, 1.0)
	if app.loaded {
		ma.sound_set_volume(&app.sound, app.volume)
	}
}

cycle_loop :: proc(app: ^App) {
	app.loop = Loop_Mode((int(app.loop) + 1) % 3)
}

toggle_random :: proc(app: ^App) {
	app.random = !app.random
}

toggle_autosave :: proc(app: ^App) {
	app.autosave = !app.autosave
}

random_index :: proc(app: ^App) -> int {
	n := len(app.tracks)
	if n <= 1 {
		return app.current
	}
	idx := rand.int_max(n)
	for idx == app.current {
		idx = rand.int_max(n)
	}
	return idx
}

find_track_by_path :: proc(app: ^App, path: string) -> int {
	for t, i in app.tracks {
		if t.path == path {
			return i
		}
	}
	return -1
}

// seek_by moves the playback position by `delta_seconds`, clamped to the track.
seek_by :: proc(app: ^App, delta_seconds: f64) {
	if !app.loaded {
		return
	}
	cursor, length: u64
	ma.sound_get_cursor_in_pcm_frames(&app.sound, &cursor)
	ma.sound_get_length_in_pcm_frames(&app.sound, &length)
	sr := app.sample_rate
	if sr == 0 {
		sr = 44100
	}
	cur_sec := f64(cursor) / f64(sr)
	len_sec := f64(length) / f64(sr)
	new_sec := clamp(cur_sec + delta_seconds, 0.0, len_sec)
	ma.sound_seek_to_pcm_frame(&app.sound, u64(new_sec * f64(sr)))
}

// do_seek performs a seek with hold-to-accelerate: taps are SEEK_BASE seconds,
// but rapid repeats (holding the key) ramp the jump size up.
do_seek :: proc(ss: ^Seek_State, app: ^App, dir: int) {
	now := time.tick_now()
	if ss.dir == dir && time.tick_diff(ss.last, now) <= SEEK_REPEAT_WINDOW {
		ss.level = min(ss.level + 1, SEEK_MAX_LEVEL)
	} else {
		ss.level = 1
	}
	ss.dir = dir
	ss.last = now
	seek_by(app, SEEK_BASE * f64(ss.level) * f64(dir))
}

loop_name :: proc(mode: Loop_Mode) -> string {
	switch mode {
	case .All:
		return "All"
	case .One:
		return "One"
	case .Off:
		return "Off"
	}
	return "?"
}

free_tracks :: proc(tracks: ^[dynamic]Track) {
	for t in tracks^ {
		delete(t.path)
		delete(t.name)
	}
	delete(tracks^)
}

track_less :: proc(a, b: Track) -> bool {
	return a.name < b.name
}

// --- marquee ---

rune_at :: proc(s: string, idx: int) -> (r: rune, ok: bool) {
	i := 0
	for c in s {
		if i == idx {
			return c, true
		}
		i += 1
	}
	return 0, false
}

// marquee_name renders a fixed-width "LCD" window of `name`, always scrolling
// left with trailing pad spaces and wrapping around (old MP3-player style).
marquee_name :: proc(name: string, offset: int, buf: []byte) -> string {
	nr := strings.rune_count(name)
	if nr == 0 {
		return ""
	}
	total := nr + MARQUEE_PAD
	width := min(MARQUEE_WIDTH, total)
	off := offset %% total
	pos := 0
	for i in 0 ..< width {
		idx := (off + i) %% total
		if idx < nr {
			r, _ := rune_at(name, idx)
			enc, n := utf8.encode_rune(r)
			for b in 0 ..< n {
				if pos < len(buf) {
					buf[pos] = enc[b]
					pos += 1
				}
			}
		} else {
			if pos < len(buf) {
				buf[pos] = ' '
				pos += 1
			}
		}
	}
	return string(buf[:pos])
}

// --- drawing ---

draw :: proc(app: ^App) {
	scheme := color_schemes[app.scheme]

	list_height := app.rows - NAV_LIST_ROW - 1 // -1 for the second footer row
	if list_height < 1 {
		list_height = 1
	}
	ensure_visible(app.selection, len(app.entries), &app.scroll, list_height)

	// Row 1: title
	fmt.printf("\x1b[%d;1H\x1b[K%sodin-player — Phase 5%s", TITLE_ROW, scheme.title, RESET)

	// Row 2: now playing (marquee)
	if app.loaded {
		mbuf: [1024]byte
		elapsed := time.tick_diff(app.marquee_start, time.tick_now())
		offset := int(elapsed / MARQUEE_SPEED)
		disp := marquee_name(app.tracks[app.current].name, offset, mbuf[:])
		fmt.printf("\x1b[%d;1H\x1b[K  %s▶ %s%s", NOW_ROW, scheme.now, disp, RESET)
	} else {
		fmt.printf("\x1b[%d;1H\x1b[K  (nothing playing — browse and press Enter)", NOW_ROW)
	}

	// Row 3: status
	if app.loaded {
		state := "Playing" if app.playing else "Paused"
		fmt.printf("\x1b[%d;1H\x1b[K  [%s]  Vol %d%%  Shuffle:%s  Loop:%s  Autosave:%s",
			STATUS_ROW, state, int(app.volume * 100.0 + 0.5),
			"on" if app.random else "off",
			loop_name(app.loop),
			"on" if app.autosave else "off")
	} else {
		fmt.printf("\x1b[%d;1H\x1b[K  [Stopped]  Vol %d%%", STATUS_ROW, int(app.volume * 100.0 + 0.5))
	}

	// Row 4: progress bar
	draw_progress(app, scheme)

	// Row 5: navigation header (current directory)
	fmt.printf("\x1b[%d;1H\x1b[K%s%s%s", NAV_HEADER_ROW, scheme.footer, fit(app.cwd, app.cols), RESET)

	// Navigation pane
	for row in 0 ..< list_height {
		idx := app.scroll + row
		fmt.printf("\x1b[%d;1H\x1b[K", NAV_LIST_ROW + row)
		if idx < len(app.entries) {
			e := app.entries[idx]
			if idx == app.selection {
				if e.is_dir && e.name != ".." {
					fmt.printf(" %s> %s/%s", scheme.highlight, fit(e.name, app.cols - 5), RESET)
				} else {
					fmt.printf(" %s> %s%s", scheme.highlight, fit(e.name, app.cols - 4), RESET)
				}
			} else {
				if e.is_dir && e.name != ".." {
					fmt.printf("   %s/", fit(e.name, app.cols - 4))
				} else {
					fmt.printf("   %s", fit(e.name, app.cols - 3))
				}
			}
		}
	}

	// Footer (two rows)
	footer1 := app.rows - 1
	fmt.printf("\x1b[%d;1H\x1b[K%s%s%s", footer1, scheme.footer, fit(FOOTER1, app.cols), RESET)
	fmt.printf("\x1b[%d;1H\x1b[K%s%s%s", app.rows, scheme.footer, fit(FOOTER2, app.cols), RESET)
	fmt.print("\x1b[J")
}

draw_progress :: proc(app: ^App, scheme: Color_Scheme) {
	if !app.loaded {
		fmt.printf("\x1b[%d;1H\x1b[K  [ -:-- / -:-- ]", PROGRESS_ROW)
		return
	}

	cursor, length: u64
	ma.sound_get_cursor_in_pcm_frames(&app.sound, &cursor)
	ma.sound_get_length_in_pcm_frames(&app.sound, &length)

	sr := app.sample_rate
	if sr == 0 {
		sr = 44100
	}
	cur_sec := f64(cursor) / f64(sr)
	len_sec := f64(length) / f64(sr)

	filled := 0
	if length > 0 {
		filled = int(f64(BAR_WIDTH) * f64(cursor) / f64(length))
	}
	filled = clamp(filled, 0, BAR_WIDTH)

	bar_buf: [BAR_WIDTH * 3 + 1]byte
	bar := build_bar(bar_buf[:], filled, BAR_WIDTH)

	tbuf: [32]byte
	cur_str := format_time(cur_sec, tbuf[:16])
	len_str := format_time(len_sec, tbuf[16:])

	fmt.printf("\x1b[%d;1H\x1b[K  %s[%s]%s %s / %s",
		PROGRESS_ROW, scheme.bar, bar, RESET, cur_str, len_str)
}

build_bar :: proc(buf: []byte, filled, width: int) -> string {
	f := clamp(filled, 0, width)
	i := 0
	for c in 0 ..< width {
		if c < f {
			if i + 3 <= len(buf) {
				buf[i] = 0xE2; buf[i + 1] = 0x96; buf[i + 2] = 0x88 // "█"
				i += 3
			}
		} else {
			if i + 2 <= len(buf) {
				buf[i] = 0xC2; buf[i + 1] = 0xB7 // "·"
				i += 2
			}
		}
	}
	return string(buf[:i])
}

format_time :: proc(seconds: f64, buf: []byte) -> string {
	total := int(seconds)
	if total < 0 {
		total = 0
	}
	h := total / 3600
	m := (total % 3600) / 60
	s := total % 60
	if h > 0 {
		return fmt.bprintf(buf, "%d:%02d:%02d", h, m, s)
	}
	return fmt.bprintf(buf, "%d:%02d", m, s)
}

// ensure_visible keeps `selection` inside the visible window of `list_height`
// rows, updating `scroll` as needed.
ensure_visible :: proc(selection: int, count: int, scroll: ^int, list_height: int) {
	if count == 0 {
		return
	}
	if selection < scroll^ {
		scroll^ = selection
	} else if selection >= scroll^ + list_height {
		scroll^ = selection - list_height + 1
	}
	max_scroll := max(0, count - list_height)
	scroll^ = clamp(scroll^, 0, max_scroll)
}

fit :: proc(s: string, max_width: int) -> string {
	if max_width <= 0 {
		return ""
	}
	count := 0
	for _, i in s {
		if count >= max_width {
			return s[:i]
		}
		count += 1
	}
	return s
}

// --- input ---

key_parser_feed :: proc(p: ^Key_Parser, b: byte) -> Key {
	if p.in_csi {
		p.in_csi = false
		switch b {
		case 'A':
			return .Nav_Up
		case 'B':
			return .Nav_Down
		case 'C':
			return .Nav_Open
		case 'D':
			return .Nav_Parent
		}
		return .None
	}
	if p.in_esc {
		p.in_esc = false
		if b == '[' {
			p.in_csi = true
		}
		return .None
	}
	if b == 0x1b {
		p.in_esc = true
		return .None
	}
	switch b {
	case 'q':
		return .Quit
	case ' ':
		return .Toggle_Play
	case 'w':
		return .Volume_Up
	case 's':
		return .Volume_Down
	case 'a':
		return .Seek_Back
	case 'd':
		return .Seek_Forward
	case 'n':
		return .Next_Track
	case 'b':
		return .Prev_Track
	case 'c':
		return .Cycle_Color
	case 'l':
		return .Cycle_Loop
	case 'r':
		return .Toggle_Random
	case 'p':
		return .Toggle_Autosave
	case '\r', '\n':
		return .Nav_Open
	}
	return .None
}

// on_winch is the SIGWINCH signal handler; it only sets a flag that the main
// loop polls (async-signal-safe).
on_winch :: proc "c" (_: posix.Signal) {
	winch_flag = true
}

setup_winch_handler :: proc() {
	act: posix.sigaction_t
	posix.sigemptyset(&act.sa_mask)
	act.sa_handler = on_winch
	act.sa_flags = {}
	if posix.sigaction(posix.Signal(posix.SIGWINCH), &act, nil) != .OK {
		fmt.eprintf("warning: failed to install SIGWINCH handler\n")
	}
}

// --- config persistence (~/.odin-player/config.json) ---

load_config :: proc(cfg: ^Config) {
	home, herr := os.user_home_dir(context.allocator)
	if herr != nil {
		return
	}
	defer delete(home)

	path, _ := filepath.join({home, ".odin-player", "config.json"}, context.allocator)
	defer delete(path)

	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)

	json.unmarshal(data, cfg)
}

save_config :: proc(app: ^App, silent: bool = false) {
	position := f64(0.0)
	track_path := ""
	if app.loaded && app.current >= 0 && app.current < len(app.tracks) {
		cursor: u64
		ma.sound_get_cursor_in_pcm_frames(&app.sound, &cursor)
		sr := app.sample_rate
		if sr == 0 {
			sr = 44100
		}
		position = f64(cursor) / f64(sr)
		track_path = app.tracks[app.current].path
	}

	cfg := Config{
		directory    = app.directory,
		volume       = app.volume,
		color_scheme = app.scheme,
		loop         = int(app.loop),
		random       = app.random,
		track_path   = track_path,
		position     = position,
		autosave     = app.autosave,
	}

	data, merr := json.marshal(cfg, {pretty = true, use_spaces = true, spaces = 2})
	if merr != nil {
		if !silent {
			fmt.eprintf("warning: failed to encode config: %v\n", merr)
		}
		return
	}
	defer delete(data)

	home, herr := os.user_home_dir(context.allocator)
	if herr != nil {
		return
	}
	defer delete(home)

	dir, _ := filepath.join({home, ".odin-player"}, context.allocator)
	defer delete(dir)
	if !os.exists(dir) {
		os.make_directory(dir)
	}

	path, _ := filepath.join({home, ".odin-player", "config.json"}, context.allocator)
	defer delete(path)
	if werr := os.write_entire_file_from_bytes(path, data); werr != nil {
		if !silent {
			fmt.eprintf("warning: failed to save config: %v\n", werr)
		}
	}
}

// --- terminal ---

enter_raw_mode :: proc() -> (original: posix.termios, ok: bool) {
	if posix.tcgetattr(posix.STDIN_FILENO, &original) != .OK {
		return original, false
	}

	raw := original
	raw.c_iflag &= ~posix.CInput_Flags{.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag &= ~posix.COutput_Flags{.OPOST}
	raw.c_cflag |= posix.CControl_Flags{.CS8}
	raw.c_lflag &= ~posix.CLocal_Flags{.ECHO, .ICANON, .IEXTEN, .ISIG}
	raw.c_cc[.VMIN] = posix.cc_t(0)
	raw.c_cc[.VTIME] = posix.cc_t(0)

	if posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw) != .OK {
		return original, false
	}
	return raw, true
}

restore_terminal :: proc(original: posix.termios) {
	t := original
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &t)
}

read_stdin :: proc(buf: []byte) -> int {
	n := posix.read(posix.STDIN_FILENO, raw_data(buf), c.size_t(len(buf)))
	if n <= 0 {
		return 0
	}
	return int(n)
}

get_terminal_size :: proc() -> (rows, cols: int) {
	ws: Winsize
	linux.ioctl(linux.Fd(1), linux.TIOCGWINSZ, uintptr(&ws))
	if ws.row != 0 && ws.col != 0 {
		return int(ws.row), int(ws.col)
	}
	return 24, 80
}

clear_screen :: proc() {
	fmt.print("\x1b[2J\x1b[H")
}
