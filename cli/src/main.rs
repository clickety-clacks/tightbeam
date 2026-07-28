mod args;
mod base_dir;
mod ceremonies;
mod contain;
mod dispatch;
mod harnesses;
mod preflight;
mod probe;
mod screen;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.first().is_some_and(|arg| arg == "rail-exec") {
        match contain::rail_exec(&args[1..]) {
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
