fn main() {
    // Load .env file if it exists
    if let Ok(path) = dotenvy::dotenv() {
        println!("cargo:rerun-if-changed={}", path.display());
    }

    // Pass the API key to the build if set
    if let Ok(key) = std::env::var("OPENAI_API_KEY") {
        println!("cargo:rustc-env=OPENAI_API_KEY={}", key);
    }

    tauri_build::build()
}
