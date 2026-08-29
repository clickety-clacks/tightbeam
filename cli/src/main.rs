mod anthropic_oauth;
mod args;
mod base_dir;
mod catalog_probe;
mod ceremonies;
mod child_process;
mod command_execution;
mod contain;
mod cursor_execution_identity;
mod dispatch;
mod github_auth;
mod harness_process;
mod harnesses;
mod lease;
mod onboard_emit;
mod preflight;
mod probe;
mod users;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if cursor_execution_identity::running_as_launcher()
        && !cursor_execution_identity::launcher_command_allowed(&args)
    {
        eprintln!("Cursor execution launcher refused: only cursor-exec is permitted");
        std::process::exit(1);
    }

    if args.first().is_some_and(|arg| arg == "cursor-exec") {
        match cursor_execution_identity::run(&args[1..]) {
            Ok(status) => std::process::exit(status),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
    }

    if args.first().is_some_and(|arg| arg == "rail-exec") {
        match contain::rail_exec(&args[1..]) {
            Ok(status) => std::process::exit(status),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
    }

    if args.first().is_some_and(|arg| arg == "harness-exec") {
        match harness_process::session_exec(&args[1..]) {
            Ok(status) => std::process::exit(status),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
    }

    if args.first().is_some_and(|arg| arg == "command-exec") {
        match command_execution::run(&args[1..]) {
            Ok(status) => std::process::exit(status),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
    }

    if args.first().is_some_and(|arg| arg == "catalog-probe") {
        match catalog_probe::probe(&args[1..]) {
            Ok(status) => std::process::exit(status),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
    }

    // The launcher's boot identity, verbatim — the Elixir reconciler compares a
    // recorded launch's boot identity against the CURRENT boot to prove a
    // reboot orphan (a pid cannot survive the kernel), and the only safe source
    // for that comparison is the SAME implementation that recorded it: a
    // reimplementation that drifted by one field would read live processes as
    // orphans and resolve their fences.
    if args.first().is_some_and(|arg| arg == "boot-identity") {
        match harness_process::print_boot_identity() {
            Ok(()) => std::process::exit(0),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
    }

    if args.first().is_some_and(|arg| arg == "harness-group") {
        match harness_process::group(&args[1..]) {
            Ok(status) => std::process::exit(status),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
    }

    // A permanent, host-agnostic diagnostic: what does THIS kernel let the containment
    // seam do? Prints the OS release and, on linux, the Landlock ABI and a per-right grant
    // trace for a directory and a device node. Exists because three fleet hosts at one
    // kernel version are not the platform gate, and a grant that EINVALs on a runner needs
    // its cause printed, not guessed. Always exits 0 — it reports, it does not enforce.
    if args.first().is_some_and(|arg| arg == "contain-probe") {
        print!("{}", contain::contain_probe());
        std::process::exit(0);
    }

    // Stage an exact profile and report per-root — the diagnostic the mix suite calls when
    // a rail-exec refusal must be reproduced against the very profile string it was handed.
    if args.first().is_some_and(|arg| arg == "contain-stage") {
        match args.get(1) {
            Some(profile) => print!("{}", contain::contain_stage(profile)),
            None => eprintln!("usage: tightbeam contain-stage <profile>"),
        }
        std::process::exit(0);
    }

    if args
        .first()
        .is_some_and(|arg| arg == "version" || arg == "--version")
    {
        println!("{}", env!("CARGO_PKG_VERSION"));
        std::process::exit(0);
    }

    match args::parse(args) {
        Ok(args::Command::Help) => {
            println!("{}", args::render_help(harnesses::load_optional().as_ref()))
        }
        Ok(args::Command::CommandHelp(command)) => {
            match args::render_command_help(harnesses::load_optional().as_ref(), &command) {
                Some(entry) => println!("{entry}"),
                None => {
                    eprintln!("no such command: {command} — run 'tightbeam help' for usage");
                    std::process::exit(1);
                }
            }
        }
        Ok(command) => {
            if let Err(error) = dispatch::run(command) {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
