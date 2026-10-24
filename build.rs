fn main() {
    println!("cargo:rerun-if-changed=native/Pastty.m");
    println!("cargo:rerun-if-changed=native/Pastty.h");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("native/Pastty.m")
            .flag("-fobjc-arc")
            .flag("-fmodules")
            .flag("-mmacosx-version-min=14.0")
            .flag("-Wno-deprecated-declarations")
            .compile("pastty_native");
        for framework in [
            "AppKit",
            "Foundation",
            "Carbon",
            "CoreGraphics",
            "ImageIO",
            "ServiceManagement",
            "ApplicationServices",
            "UniformTypeIdentifiers",
        ] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
    }
}
