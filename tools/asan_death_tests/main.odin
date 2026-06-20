package main

import "core:fmt"
import "core:os"

RUNNER_OUTPUT_DIR :: "build"
RUNNER_NAME :: "test_asan_death_runner"

main :: proc() {
	if !os.is_dir(RUNNER_OUTPUT_DIR) {
		if err := os.make_directory(RUNNER_OUTPUT_DIR); err != nil {
			fmt.eprintfln("[DEATH-TOOL] failed to create output directory '%s': %v", RUNNER_OUTPUT_DIR, err)
			os.exit(1)
		}
	}

	runner_path: string
	when ODIN_OS == .Windows {
		runner_path = RUNNER_OUTPUT_DIR + "/" + RUNNER_NAME + ".exe"
	} else {
		runner_path = RUNNER_OUTPUT_DIR + "/" + RUNNER_NAME
	}

	build_desc := os.Process_Desc {
		command = {
			"odin",
			"build",
			"src/",
			"-sanitize:address",
			"-define:TINA_ASAN_DEATH_TESTS=true",
			fmt.tprintf("-out:%s", runner_path),
		},
	}

	fmt.printfln("[DEATH-TOOL] building runner: %v", build_desc.command)
	build_state, build_stdout, build_stderr, build_err := os.process_exec(build_desc, context.allocator)
	defer {
		delete(build_stdout)
		delete(build_stderr)
	}

	if build_err != nil {
		fmt.eprintfln("[DEATH-TOOL] failed to start odin build: %v", build_err)
		os.exit(1)
	}

	if !build_state.success {
		fmt.eprintfln("[DEATH-TOOL] runner build failed")
		if len(build_stdout) > 0 {
			fmt.eprintf("[DEATH-TOOL] stdout:\n%s\n", string(build_stdout))
		}
		if len(build_stderr) > 0 {
			fmt.eprintf("[DEATH-TOOL] stderr:\n%s\n", string(build_stderr))
		}
		os.exit(1)
	}

	run_desc := os.Process_Desc {
		command = {runner_path},
	}

	fmt.printfln("[DEATH-TOOL] running death-test runner: %s", runner_path)
	run_state, run_stdout, run_stderr, run_err := os.process_exec(run_desc, context.allocator)
	defer {
		delete(run_stdout)
		delete(run_stderr)
	}

	if run_err != nil {
		fmt.eprintfln("[DEATH-TOOL] failed to run death-test runner: %v", run_err)
		os.exit(1)
	}

	if len(run_stdout) > 0 {
		fmt.print(string(run_stdout))
	}
	if len(run_stderr) > 0 {
		fmt.eprint(string(run_stderr))
	}

	if !run_state.success {
		fmt.eprintfln("[DEATH-TOOL] death-test runner reported failures")
		os.exit(1)
	}

	fmt.printfln("[DEATH-TOOL] all death tests passed")
}
