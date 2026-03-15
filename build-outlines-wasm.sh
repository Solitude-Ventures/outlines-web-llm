#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
OUTLINES_CORE_REPO="https://github.com/dottxt-ai/outlines-core.git"
OUTLINES_CORE_TAG="0.2.14"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="outlines-wasm-builder"
OUTPUT_JS="$SCRIPT_DIR/outlines_wasm.js"
OUTPUT_WASM="$SCRIPT_DIR/outlines_wasm_bg.wasm"

if ! command -v docker &>/dev/null; then
  echo "ERROR: docker is required but not found in PATH" >&2
  exit 1
fi

# --- Write ephemeral build script (COPYed into the image) ---
cat > "$SCRIPT_DIR/.build-inner.sh" << 'INNER'
#!/usr/bin/env bash
set -euo pipefail

REPO="$1"; TAG="$2"

echo "==> Cloning outlines-core @ ${TAG}..."
git clone --depth 1 --branch "$TAG" "$REPO" /build/outlines-core 2>&1 | tail -1

# -- Patch Cargo.toml: make tokenizers optional --
echo "==> Patching Cargo.toml..."
sed -i '/^\[dependencies\.tokenizers\]/,/^$/{
  /^default-features/a\
optional = true
}' /build/outlines-core/Cargo.toml

sed -i 's/^hugginface-hub = \["hf-hub",/hugginface-hub = ["hf-hub", "tokenizers",/' \
  /build/outlines-core/Cargo.toml

# -- Patch error.rs: guard TokenizersError behind cfg --
echo "==> Patching error.rs..."
sed -i 's|    #\[error(transparent)\]|    #[cfg(feature = "hugginface-hub")]\n    #[error(transparent)]|' \
  /build/outlines-core/src/error.rs

# -- Create wrapper crate --
echo "==> Creating outlines-wasm wrapper..."
mkdir -p /build/outlines-wasm/src
cp /build/wrapper-Cargo.toml /build/outlines-wasm/Cargo.toml
cp /build/wrapper-lib.rs     /build/outlines-wasm/src/lib.rs

# -- Build --
echo "==> Building with wasm-pack..."
(cd /build/outlines-wasm && wasm-pack build --target web --release 2>&1)

# -- Output --
cp /build/outlines-wasm/pkg/outlines_wasm_bg.wasm /output/outlines_wasm_bg.wasm
cp /build/outlines-wasm/pkg/outlines_wasm.js      /output/outlines_wasm.js
SIZE=$(wc -c < /output/outlines_wasm_bg.wasm | tr -d ' ')
echo ""
echo "Build complete: outlines-core @ $TAG  |  outlines_wasm_bg.wasm ($(( SIZE / 1024 )) KB)"
INNER
chmod +x "$SCRIPT_DIR/.build-inner.sh"

# --- Write wrapper crate files (COPYed into the image) ---
cat > "$SCRIPT_DIR/.wrapper-Cargo.toml" << 'TOML'
[package]
name = "outlines-wasm"
version = "0.1.0"
edition = "2021"

[package.metadata.wasm-pack.profile.release]
wasm-opt = false

[lib]
crate-type = ["cdylib"]

[dependencies]
outlines-core = { path = "../outlines-core", default-features = false }
wasm-bindgen = "0.2"
serde_json = "1.0"
js-sys = "0.3"

[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
strip = true
panic = 'abort'
TOML

cat > "$SCRIPT_DIR/.wrapper-lib.rs" << 'RUST'
use std::sync::Mutex;

use js_sys::Uint32Array;
use outlines_core::index::Index;
use outlines_core::json_schema;
use outlines_core::primitives::Token;
use outlines_core::vocabulary::Vocabulary;
use wasm_bindgen::prelude::*;

static SLAB: Mutex<Vec<Option<Index>>> = Mutex::new(Vec::new());

#[wasm_bindgen]
pub fn compile_index(json_schema_str: &str, vocab_json: &str, eos_token_id: u32) -> Result<u32, JsValue> {
    let regex = json_schema::regex_from_str(json_schema_str, None, None)
        .map_err(|e| JsValue::from_str(&format!("regex: {e}")))?;

    let vocab_map: std::collections::HashMap<String, Vec<u32>> =
        serde_json::from_str(vocab_json)
            .map_err(|e| JsValue::from_str(&format!("vocab json: {e}")))?;

    let mut vocabulary = Vocabulary::new(eos_token_id);
    for (token_str, ids) in &vocab_map {
        let token_bytes: Token = token_str.as_bytes().to_vec();
        for &id in ids {
            if id != eos_token_id {
                vocabulary
                    .try_insert(token_bytes.clone(), id)
                    .map_err(|e| JsValue::from_str(&format!("vocab insert: {e}")))?;
            }
        }
    }

    let index = Index::new(&regex, &vocabulary)
        .map_err(|e| JsValue::from_str(&format!("index: {e}")))?;

    let mut slab = SLAB.lock().map_err(|e| JsValue::from_str(&format!("lock: {e}")))?;
    let handle = slab.len() as u32;
    slab.push(Some(index));
    Ok(handle)
}

#[wasm_bindgen]
pub fn initial_state(handle: u32) -> Result<u32, JsValue> {
    let slab = SLAB.lock().map_err(|e| JsValue::from_str(&format!("lock: {e}")))?;
    let index = slab
        .get(handle as usize)
        .and_then(|s| s.as_ref())
        .ok_or_else(|| JsValue::from_str("invalid handle"))?;
    Ok(index.initial_state())
}

#[wasm_bindgen]
pub fn allowed_tokens(handle: u32, state: u32) -> Result<Uint32Array, JsValue> {
    let slab = SLAB.lock().map_err(|e| JsValue::from_str(&format!("lock: {e}")))?;
    let index = slab
        .get(handle as usize)
        .and_then(|s| s.as_ref())
        .ok_or_else(|| JsValue::from_str("invalid handle"))?;

    match index.allowed_tokens(&state) {
        Some(tokens) => {
            let arr = Uint32Array::new_with_length(tokens.len() as u32);
            arr.copy_from(&tokens);
            Ok(arr)
        }
        None => Ok(Uint32Array::new_with_length(0)),
    }
}

#[wasm_bindgen]
pub fn next_state(handle: u32, state: u32, token_id: u32) -> Result<i64, JsValue> {
    let slab = SLAB.lock().map_err(|e| JsValue::from_str(&format!("lock: {e}")))?;
    let index = slab
        .get(handle as usize)
        .and_then(|s| s.as_ref())
        .ok_or_else(|| JsValue::from_str("invalid handle"))?;

    match index.next_state(&state, &token_id) {
        Some(s) => Ok(s as i64),
        None => Ok(-1),
    }
}

#[wasm_bindgen]
pub fn is_final_state(handle: u32, state: u32) -> Result<bool, JsValue> {
    let slab = SLAB.lock().map_err(|e| JsValue::from_str(&format!("lock: {e}")))?;
    let index = slab
        .get(handle as usize)
        .and_then(|s| s.as_ref())
        .ok_or_else(|| JsValue::from_str("invalid handle"))?;
    Ok(index.is_final_state(&state))
}

#[wasm_bindgen]
pub fn free_index(handle: u32) -> Result<(), JsValue> {
    let mut slab = SLAB.lock().map_err(|e| JsValue::from_str(&format!("lock: {e}")))?;
    if let Some(slot) = slab.get_mut(handle as usize) {
        *slot = None;
    }
    Ok(())
}
RUST

# --- Build Docker image ---
echo "Building Docker image ($IMAGE_NAME)..."
docker build -t "$IMAGE_NAME" -f - "$SCRIPT_DIR" << 'DOCKERFILE'
FROM rust:1.85-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN cargo install wasm-pack --version 0.13.1 --locked \
    && rustup target add wasm32-unknown-unknown

WORKDIR /build
COPY .build-inner.sh       /build/build-inner.sh
COPY .wrapper-Cargo.toml   /build/wrapper-Cargo.toml
COPY .wrapper-lib.rs       /build/wrapper-lib.rs

ENTRYPOINT ["/build/build-inner.sh"]
DOCKERFILE

# --- Clean up ephemeral files ---
rm -f "$SCRIPT_DIR/.build-inner.sh" "$SCRIPT_DIR/.wrapper-Cargo.toml" "$SCRIPT_DIR/.wrapper-lib.rs"

# --- Run build in container ---
echo ""
echo "Running build in container..."
docker run --rm \
  -v "$SCRIPT_DIR:/output" \
  "$IMAGE_NAME" \
  "$OUTLINES_CORE_REPO" "$OUTLINES_CORE_TAG"

# --- Verify ---
if [[ -f "$OUTPUT_WASM" && -f "$OUTPUT_JS" ]]; then
  WASM_SIZE=$(wc -c < "$OUTPUT_WASM" | tr -d ' ')
  echo ""
  echo "Done:"
  echo "  $OUTPUT_JS"
  echo "  $OUTPUT_WASM ($(( WASM_SIZE / 1024 )) KB)"
else
  echo "ERROR: Build artifacts not found" >&2
  exit 1
fi
