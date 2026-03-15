#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
OUTLINES_CORE_REPO="https://github.com/dottxt-ai/outlines-core.git"
OUTLINES_CORE_TAG="0.2.14"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.outlines-build"
OUTPUT_JS="$SCRIPT_DIR/outlines_wasm.js"
OUTPUT_WASM="$SCRIPT_DIR/outlines_wasm_bg.wasm"

# --- Prerequisites ---
for cmd in git rustup wasm-pack; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not found in PATH" >&2
    exit 1
  fi
done

if ! rustup target list --installed 2>/dev/null | grep -q wasm32-unknown-unknown; then
  echo "Adding wasm32-unknown-unknown target..."
  rustup target add wasm32-unknown-unknown
fi

# --- Clean slate ---
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "Build directory: $BUILD_DIR"

# --- Clone outlines-core at pinned tag ---
echo "Cloning outlines-core @ ${OUTLINES_CORE_TAG}..."
git clone --depth 1 --branch "$OUTLINES_CORE_TAG" \
  "$OUTLINES_CORE_REPO" "$BUILD_DIR/outlines-core" 2>&1 | tail -1

# --- Patch 1: Make tokenizers optional in Cargo.toml ---
# Stock has tokenizers as a required dependency. We make it optional so the
# crate can compile for wasm32 without pulling in native-only tokenizers code.
echo "Patching outlines-core/Cargo.toml..."
CARGO_TOML="$BUILD_DIR/outlines-core/Cargo.toml"

# Add optional = true to [dependencies.tokenizers]
sed -i.bak '/^\[dependencies\.tokenizers\]/,/^$/{
  /^default-features/a\
optional = true
}' "$CARGO_TOML"

# Add "tokenizers" to the hugginface-hub feature so it pulls tokenizers when enabled
sed -i.bak 's/^hugginface-hub = \["hf-hub",/hugginface-hub = ["hf-hub", "tokenizers",/' "$CARGO_TOML"

rm -f "$CARGO_TOML.bak"

# --- Patch 2: Guard TokenizersError behind cfg in error.rs ---
# Without this, error.rs references tokenizers::Error unconditionally which
# fails to compile when tokenizers is not enabled.
echo "Patching outlines-core/src/error.rs..."
ERROR_RS="$BUILD_DIR/outlines-core/src/error.rs"

sed -i.bak 's|    #\[error(transparent)\]|    #[cfg(feature = "hugginface-hub")]\n    #[error(transparent)]|' "$ERROR_RS"
rm -f "$ERROR_RS.bak"

# --- Verify patches compile ---
echo "Verifying outlines-core compiles for wasm32 (no default features)..."
(cd "$BUILD_DIR/outlines-core" && \
  cargo check --target wasm32-unknown-unknown --no-default-features --lib 2>&1 | tail -3)

# --- Create outlines-wasm wrapper crate ---
echo "Creating outlines-wasm wrapper crate..."
WASM_CRATE="$BUILD_DIR/outlines-wasm"
mkdir -p "$WASM_CRATE/src"

cat > "$WASM_CRATE/Cargo.toml" << 'TOML'
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

cat > "$WASM_CRATE/src/lib.rs" << 'RUST'
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

# --- Build with wasm-pack ---
echo "Building outlines-wasm with wasm-pack (release, --target web)..."
(cd "$WASM_CRATE" && wasm-pack build --target web --release 2>&1)

# --- Copy outputs ---
echo "Copying build artifacts..."
cp "$WASM_CRATE/pkg/outlines_wasm_bg.wasm" "$OUTPUT_WASM"
cp "$WASM_CRATE/pkg/outlines_wasm.js"      "$OUTPUT_JS"

WASM_SIZE=$(wc -c < "$OUTPUT_WASM" | tr -d ' ')
echo ""
echo "Build complete:"
echo "  outlines-core tag: $OUTLINES_CORE_TAG"
echo "  $OUTPUT_JS"
echo "  $OUTPUT_WASM ($(( WASM_SIZE / 1024 )) KB)"

# --- Clean up build directory ---
rm -rf "$BUILD_DIR"
echo "Cleaned up $BUILD_DIR"
