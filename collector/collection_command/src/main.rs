//! `schublade-collector`: connect, enroll, survey, decide, collect, and status. The commands
//! arrive with the collection coordinator; until then the program names them and exits.

const USAGE: &str = "usage: schublade-collector <connect|enroll|survey|decide|collect|status> ...
The commands arrive with the collection coordinator.";

fn main() {
    eprintln!("{USAGE}");
    std::process::exit(2);
}
