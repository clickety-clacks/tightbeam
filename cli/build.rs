fn main() {
    println!(
        "cargo:rustc-env=TIGHTBEAM_BUILD_TARGET={}",
        std::env::var("TARGET").expect("Cargo sets TARGET for build scripts")
    );
}
