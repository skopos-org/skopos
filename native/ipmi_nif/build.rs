use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const REVISION: &str = "19d78782d795d0cf4ceefe655f616210c9143e62";

fn run(root: &Path, program: &str, args: &[&str]) {
    assert!(
        Command::new(program)
            .args(args)
            .current_dir(root)
            .status()
            .unwrap()
            .success(),
        "IPMI SDK build failed: {program}"
    );
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/transport.c");
    let out = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    let sdk = out.join("ipmitool");
    if !sdk.exists() {
        run(
            &out,
            "git",
            &[
                "clone",
                "--depth",
                "1",
                "--branch",
                "IPMITOOL_1_8_19",
                "https://github.com/ipmitool/ipmitool.git",
                "ipmitool",
            ],
        );
    }
    let revision = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(&sdk)
        .output()
        .unwrap();
    assert!(revision.status.success());
    assert_eq!(String::from_utf8(revision.stdout).unwrap().trim(), REVISION);
    if !sdk.join(".skopos-build-complete").exists() {
        run(&sdk, "sh", &["bootstrap"]);
        assert!(Command::new("./configure")
            .current_dir(&sdk)
            .env("CFLAGS", "-O2 -fPIC")
            .env("DEFAULT_INTF", "lanplus")
            .args([
                "--disable-ipmishell",
                "--disable-intf-open",
                "--disable-intf-imb",
                "--disable-intf-lipmi",
                "--disable-intf-serial",
                "--disable-intf-usb",
                "--enable-intf-lan",
                "--enable-intf-lanplus",
                "--with-pic"
            ])
            .status()
            .unwrap()
            .success());
        // LAN supplies shared firmware MD5 symbols; only lanplus is invoked.
        run(&sdk, "make", &["-j8"]);
        fs::write(sdk.join(".skopos-build-complete"), REVISION).unwrap();
    }
    run(&sdk, "git", &["diff", "--exit-code", "--quiet"]);
    let object = out.join("transport.o");
    assert!(Command::new("cc")
        .args(["-O2", "-fPIC", "-Wall", "-Wextra", "-Werror"])
        .arg(format!("-I{}", sdk.display()))
        .arg(format!("-I{}/include", sdk.display()))
        .args(["-c", "src/transport.c", "-o"])
        .arg(&object)
        .status()
        .unwrap()
        .success());
    assert!(Command::new("ar")
        .arg("crs")
        .arg(out.join("libtransport.a"))
        .arg(object)
        .status()
        .unwrap()
        .success());
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=transport");
    for directory in ["src/plugins/.libs", "lib/.libs"] {
        println!(
            "cargo:rustc-link-search=native={}/{}",
            sdk.display(),
            directory
        );
    }
    println!("cargo:rustc-link-lib=static=intf");
    println!("cargo:rustc-link-lib=static=ipmitool");
    println!("cargo:rustc-link-lib=crypto");
    println!("cargo:rustc-link-lib=m");
    println!("cargo:rustc-link-arg=-Wl,--wrap=socket,--wrap=select,--wrap=send,--wrap=recv,--wrap=lprintf,--wrap=printbuf,--wrap=ipmi_intf_session_cleanup,--wrap=lanplus_rakp2_hmac_matches,--wrap=lanplus_rakp4_hmac_matches,--exclude-libs,ALL");
    let notices =
        PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../../priv/native");
    fs::create_dir_all(&notices).unwrap();
    fs::copy(sdk.join("COPYING"), notices.join("ipmitool-COPYING")).unwrap();
    let mut licenses = format!("ipmitool 1.8.19 ({REVISION})\n\n");
    for directory in [
        "lib",
        "src/plugins/lan",
        "src/plugins/lanplus",
        "include/ipmitool",
    ] {
        let mut files = fs::read_dir(sdk.join(directory))
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect::<Vec<_>>();
        files.sort();
        for file in files {
            if matches!(
                file.extension().and_then(|ext| ext.to_str()),
                Some("c" | "h")
            ) {
                let source = fs::read_to_string(&file).unwrap();
                if let Some(end) = source.find("*/") {
                    licenses.push_str(&format!(
                        "{}\n{}\n\n",
                        file.strip_prefix(&sdk).unwrap().display(),
                        &source[..end + 2]
                    ));
                }
            }
        }
    }
    fs::write(notices.join("ipmitool-NOTICES"), licenses).unwrap();
}
