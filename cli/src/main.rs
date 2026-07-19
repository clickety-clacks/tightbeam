mod args;
mod ceremonies;
mod dispatch;

fn main() {
    match args::parse(std::env::args().skip(1).collect()) {
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
