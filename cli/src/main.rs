mod args;
mod ceremonies;
mod contain;
mod dispatch;
mod probe;

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

    match args::parse(args) {
        Ok(args::Command::Help) => println!("{}", args::HELP),
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
