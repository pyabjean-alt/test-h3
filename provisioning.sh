#!/bin/bash
# =============================================================================
# Muse Character Sheet H3 — RunPod provisioning script
# Base image: ghcr.io/ai-dock/comfyui:latest-cuda
# Runs automatically at pod boot via the PROVISIONING_SCRIPT env var.
#
# Model sources (checked 2026-09-27):
#   https://huggingface.co/wsxxxx/MiniMax-H3            (repackaged single-file weights for ComfyUI)
#   https://huggingface.co/Kijai/MiniMax-H3-experimental (w4a8 / fastvideo / extra LoRAs)
#   https://huggingface.co/MiniMaxAI/MiniMax-H3          (official, Diffusers-sharded — NOT used here)
# Both wsxxxx/MiniMax-H3 and Kijai/MiniMax-H3-experimental carry the same
# minimax-h3-community-license-agreement as the official repo, so they are
# gated: set HF_TOKEN to an account that has accepted the license on
# huggingface.co/MiniMaxAI/MiniMax-H3, or these downloads will 401/403.
# =============================================================================
set -euo pipefail
COMFYUI_DIR="${COMFYUI_DIR:-/opt/ComfyUI}"
[ -d "$COMFYUI_DIR" ] || COMFYUI_DIR="/workspace/ComfyUI"
PIP="${COMFYUI_VENV_PIP:-pip}"
CUSTOM_NODES="$COMFYUI_DIR/custom_nodes"
MODELS="$COMFYUI_DIR/models"
WORKFLOWS="$COMFYUI_DIR/user/default/workflows"
mkdir -p "$CUSTOM_NODES" \
         "$MODELS"/{diffusion_models,loras,text_encoders,vae,model_patches,checkpoints,embeddings} \
         "$WORKFLOWS"

log() { echo -e "\n\033[1;36m[provisioning]\033[0m $*"; }

clone_or_pull () {
  local url="$1" dir="$CUSTOM_NODES/$(basename "$1" .git)"
  if [ -d "$dir" ]; then
    log "Updating $(basename "$dir")"
    git -C "$dir" pull --ff-only || true
  else
    log "Cloning $(basename "$dir")"
    git clone --depth 1 "$url" "$dir"
  fi
  [ -f "$dir/requirements.txt" ] && "$PIP" install --no-cache-dir -r "$dir/requirements.txt" || true
}

# -----------------------------------------------------------------------------
# 1. Python deps
# Latest ComfyUI + comfy_kitchen need PyTorch >= 2.7 (list[int] custom-op schema).
# ai-dock images often still ship torch 2.4.1+cu121, which crashes at import:
#   ValueError: infer_schema(... stride: list[int] ...)
# -----------------------------------------------------------------------------
log "Checking PyTorch version in ComfyUI venv"
PY="${COMFYUI_VENV_PYTHON:-python3}"
TORCH_VER="$("$PY" -c 'import torch; print(torch.__version__.split("+")[0])' 2>/dev/null || echo 0.0.0)"
log "Detected torch=$TORCH_VER"
IFS='.' read -r TMAJ TMIN TREST <<< "${TORCH_VER}.0.0"
if [ "${TMAJ:-0}" -lt 2 ] || { [ "${TMAJ:-0}" -eq 2 ] && [ "${TMIN:-0}" -lt 7 ]; }; then
  log "Upgrading PyTorch to >=2.7 (cu124 wheels; L40S / recent drivers are fine)"
  "$PIP" install --upgrade --no-cache-dir \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu124 || \
    "$PIP" install --upgrade --no-cache-dir torch torchvision torchaudio
fi

log "Force-updating ComfyUI core (ai-dock's own AUTO_UPDATE is unreliable)"
if [ -d "$COMFYUI_DIR/.git" ]; then
  git -C "$COMFYUI_DIR" fetch --depth 1 origin master
  git -C "$COMFYUI_DIR" reset --hard origin/master
  log "Reinstalling ComfyUI core's own requirements.txt"
  "$PIP" install --no-cache-dir -r "$COMFYUI_DIR/requirements.txt"
else
  log "WARNING: $COMFYUI_DIR is not a git checkout, skipping core update"
fi

log "Installing PyAV + psutil + huggingface-cli into ComfyUI's own venv"
"$PIP" install --no-cache-dir av psutil "huggingface_hub[cli]"

# Last-resort pin if kitchen still cannot import on this torch
if ! "$PY" -c "import comfy_kitchen" >/dev/null 2>&1; then
  log "comfy_kitchen import failed — pinning comfy_kitchen==0.2.27 as fallback"
  "$PIP" install --no-cache-dir --force-reinstall "comfy_kitchen==0.2.27" || true
fi

# -----------------------------------------------------------------------------
# 2. Custom nodes
# -----------------------------------------------------------------------------
clone_or_pull "https://github.com/muse-collective-26/Muse-CharacterSheet-H3.git"
clone_or_pull "https://github.com/muse-collective-26/Muse-MiniMax-H3-Unified-Loader.git"
clone_or_pull "https://github.com/kijai/ComfyUI-KJNodes.git"
clone_or_pull "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
clone_or_pull "https://github.com/WASasquatch/was-node-suite-comfyui.git"
clone_or_pull "https://github.com/MohammadAboulEla/ComfyUI-iTools.git"

if [ "${use_two_stage_sampling:-false}" = "true" ]; then
  clone_or_pull "https://github.com/jlucasmcrell/ComfyUI-H3-Multishot.git"
fi
if [ "${use_refmod:-true}" = "true" ]; then
  clone_or_pull "https://github.com/Luisacaotica/ComfyUI-MiniMaxH3Mod.git"
fi

if [ ! -d "$CUSTOM_NODES/comfyui_memory_cleanup" ] && [ -x "$CUSTOM_NODES/ComfyUI-Manager/cm-cli.py" ]; then
  log "Installing comfyui_memory_cleanup via ComfyUI-Manager"
  python "$CUSTOM_NODES/ComfyUI-Manager/cm-cli.py" install comfyui_memory_cleanup || \
    log "WARNING: could not auto-install comfyui_memory_cleanup — install it by name from the Manager UI"
fi

if [ -f "$CUSTOM_NODES/Muse-CharacterSheet-H3/workflows/H3 Character Sheet.json" ]; then
  cp "$CUSTOM_NODES/Muse-CharacterSheet-H3/workflows/H3 Character Sheet.json" "$WORKFLOWS/"
fi

# -----------------------------------------------------------------------------
# 3. Hugging Face helper
#    wsxxxx/MiniMax-H3 mirrors ComfyUI's own folder layout at the repo root
#    (diffusion_models/, text_encoders/, vae/, loras/, embeddings/) — we
#    download the repo-relative path then flatten into ComfyUI/models/<folder>/
# -----------------------------------------------------------------------------
download_minimax_h3="${download_minimax_h3:-true}"
# int8 | fp8 | w4a8 | bf16 | false
minimax_quant="${minimax_quant:-int8}"
download_ref2va="${download_ref2va:-true}"
download_kijai_experimental="${download_kijai_experimental:-true}"
download_turbo_loras="${download_turbo_loras:-true}"

MINIMAX_REPO="${MINIMAX_REPO:-wsxxxx/MiniMax-H3}"

VENV_BIN="$(dirname "${COMFYUI_VENV_PYTHON:-/usr/bin/python3}")"
if [ -x "$VENV_BIN/hf" ]; then
  HF_BIN="$VENV_BIN/hf"
elif [ -x "$VENV_BIN/huggingface-cli" ]; then
  HF_BIN="$VENV_BIN/huggingface-cli"
else
  HF_BIN="hf"
fi

hf_login () {
  if [ -n "${HF_TOKEN:-}" ]; then
    "$HF_BIN" auth login --token "$HF_TOKEN" --add-to-git-credential 2>/dev/null || \
      huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential || true
  else
    log "WARNING: no HF_TOKEN set — wsxxxx/MiniMax-H3 and Kijai/MiniMax-H3-experimental carry MiniMax's gated community license, so downloads will likely 401 without an authenticated, license-accepted token"
  fi
}

# hf_get REPO REPO_RELATIVE_PATH DEST_DIR [DEST_FILENAME]
# Downloads one file and places ONLY the basename in DEST_DIR (no nested folders).
hf_get () {
  local repo="$1" rel="$2" dest="$3"
  local dest_name="${4:-$(basename "$rel")}"
  local target="$dest/$dest_name"
  mkdir -p "$dest"
  if [ -f "$target" ] && [ -s "$target" ]; then
    log "Already present: $target"
    return 0
  fi
  log "HF: $repo :: $rel  ->  $target"
  local tmp
  tmp="$(mktemp -d)"
  if "$HF_BIN" download "$repo" "$rel" --local-dir "$tmp"; then
    if [ -f "$tmp/$rel" ]; then
      mv "$tmp/$rel" "$target"
    elif [ -f "$tmp/$(basename "$rel")" ]; then
      mv "$tmp/$(basename "$rel")" "$target"
    else
      local found
      found="$(find "$tmp" -type f -name '*.safetensors' | head -n 1 || true)"
      if [ -n "$found" ]; then
        mv "$found" "$target"
      else
        log "WARNING: downloaded $repo/$rel but could not locate the file in $tmp"
      fi
    fi
  else
    log "WARNING: HF download failed for $repo/$rel"
  fi
  rm -rf "$tmp"
}

if [ "$download_minimax_h3" = "true" ]; then
  hf_login
  log "Downloading MiniMax H3 models (repo=$MINIMAX_REPO, quant=$minimax_quant, ref2va=$download_ref2va, kijai_exp=$download_kijai_experimental)"

  CLIP_FILE="${MINIMAX_CLIP_FILE:-qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors}"
  AUDIO_VAE_FILE="${MINIMAX_AUDIO_VAE_FILE:-minimax_h3_audio_vae_fp32.safetensors}"
  # wsxxxx only lists an fp16 video VAE at repo root (no int8_convrot variant there —
  # that one lives in Kijai/MiniMax-H3-experimental, handled in the w4a8 case below)
  VAE_FILE="${MINIMAX_VAE_FILE:-minimax_h3_video_vae_fp16.safetensors}"

  # --- text encoder + VAEs ---
  hf_get "$MINIMAX_REPO" "text_encoders/${CLIP_FILE}" "$MODELS/text_encoders"
  hf_get "$MINIMAX_REPO" "vae/${VAE_FILE}"            "$MODELS/vae"
  hf_get "$MINIMAX_REPO" "vae/${AUDIO_VAE_FILE}"      "$MODELS/vae"

  # --- diffusion weights ---
  case "$minimax_quant" in
    int8)
      FL2VA_FILE="${MINIMAX_DIT_FILE:-minimax_h3_fl2va_pruned_int8_convrot.safetensors}"
      REF2VA_FILE="${MINIMAX_REF2VA_FILE:-minimax_h3_ref2va_pruned_int8_convrot.safetensors}"
      hf_get "$MINIMAX_REPO" "diffusion_models/${FL2VA_FILE}"  "$MODELS/diffusion_models"
      if [ "$download_ref2va" = "true" ]; then
        hf_get "$MINIMAX_REPO" "diffusion_models/${REF2VA_FILE}" "$MODELS/diffusion_models"
      fi
      ;;
    fp8)
      FL2VA_FILE="${MINIMAX_DIT_FILE:-minimax_h3_fl2va_pruned_fp8_scaled.safetensors}"
      REF2VA_FILE="${MINIMAX_REF2VA_FILE:-minimax_h3_ref2va_pruned_fp8_scaled.safetensors}"
      hf_get "$MINIMAX_REPO" "diffusion_models/${FL2VA_FILE}"  "$MODELS/diffusion_models"
      if [ "$download_ref2va" = "true" ]; then
        hf_get "$MINIMAX_REPO" "diffusion_models/${REF2VA_FILE}" "$MODELS/diffusion_models"
      fi
      ;;
    bf16|false)
      FL2VA_FILE="${MINIMAX_DIT_FILE:-minimax_h3_fl2va_pruned_bf16.safetensors}"
      REF2VA_FILE="${MINIMAX_REF2VA_FILE:-minimax_h3_ref2va_pruned_bf16.safetensors}"
      hf_get "$MINIMAX_REPO" "diffusion_models/${FL2VA_FILE}"  "$MODELS/diffusion_models"
      if [ "$download_ref2va" = "true" ]; then
        hf_get "$MINIMAX_REPO" "diffusion_models/${REF2VA_FILE}" "$MODELS/diffusion_models"
      fi
      ;;
    w4a8|experimental)
      # Kijai experimental (flat repo root, not nested) — confirmed to also
      # host the int8 convrot video VAE and the FastVideo 4-step DiT.
      FL2VA_FILE="${MINIMAX_DIT_FILE:-minimax_h3_fl2va_pruned_w4a8_mixed.safetensors}"
      REF2VA_FILE="${MINIMAX_REF2VA_FILE:-minimax_h3_ref2va_pruned_w4a8_mixed.safetensors}"
      FASTVIDEO_FILE="${MINIMAX_FASTVIDEO_FILE:-minimax_h3_fastvideo_vsa_datafree_1300step_4step_int8_convrot.safetensors}"
      hf_get "Kijai/MiniMax-H3-experimental" "$FL2VA_FILE" "$MODELS/diffusion_models"
      if [ "$download_ref2va" = "true" ]; then
        hf_get "Kijai/MiniMax-H3-experimental" "$REF2VA_FILE" "$MODELS/diffusion_models"
      fi
      hf_get "Kijai/MiniMax-H3-experimental" "$FASTVIDEO_FILE" "$MODELS/diffusion_models"
      hf_get "Kijai/MiniMax-H3-experimental" "minimax_h3_video_vae_int8_convrot.safetensors" "$MODELS/vae"
      ;;
    *)
      log "WARNING: unknown minimax_quant='$minimax_quant' — expected int8|fp8|w4a8|bf16"
      ;;
  esac

  # Turbo LoRAs live under <repo>/loras/
  if [ "$download_turbo_loras" = "true" ]; then
    TURBO_LORA_FILE="${MINIMAX_TURBO_LORA_FILE:-minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors}"
    hf_get "$MINIMAX_REPO" "loras/${TURBO_LORA_FILE}" "$MODELS/loras"
    hf_get "$MINIMAX_REPO" "loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors" "$MODELS/loras"
    hf_get "$MINIMAX_REPO" "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" "$MODELS/loras"
  fi

  # Extra Kijai experimental LoRAs / 4-step flashgen / fun controlnet
  if [ "$download_kijai_experimental" = "true" ]; then
    hf_get "Kijai/MiniMax-H3-experimental" \
      "loras/minimax_h3_4step_lora_flashgen_v1.0_768p_fl2va_pruned_avg_rank_13_bf16.safetensors" \
      "$MODELS/loras"
    hf_get "Kijai/MiniMax-H3-experimental" \
      "loras/MiniMax-H3-FL2VA-Acc-8Step_pruned_comfy.safetensors" \
      "$MODELS/loras"
    if [ "$download_ref2va" = "true" ]; then
      hf_get "Kijai/MiniMax-H3-experimental" \
        "loras/MiniMax-H3-Ref2VA-Acc-8Step_pruned_comfy.safetensors" \
        "$MODELS/loras"
    fi
    if [ "${download_controlnet:-false}" = "true" ]; then
      hf_get "Kijai/MiniMax-H3-experimental" \
        "model_patches/minimax_h3_fun_controlnet_union_2.0_pruned_int8_convrot.safetensors" \
        "$MODELS/model_patches"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 4. CivitAI LoRAs / checkpoints
# -----------------------------------------------------------------------------
civitai_download () {
  local id="$1" dest="$2"
  local token_qs=""
  [ -n "${civitai_token:-}" ] && token_qs="?token=${civitai_token}"
  mkdir -p "$dest"
  log "CivitAI: downloading version $id -> $dest"
  wget -q --content-disposition -P "$dest" \
    "https://civitai.com/api/download/models/${id}${token_qs}" || \
    log "WARNING: CivitAI download failed for id $id (check the id and civitai_token)"
}

if [ -n "${CIVITAI_LORAS:-}" ]; then
  IFS=',' read -ra ids <<< "$CIVITAI_LORAS"
  for id in "${ids[@]}"; do civitai_download "$(echo "$id" | xargs)" "$MODELS/loras"; done
fi
if [ -n "${CIVITAI_CHECKPOINTS:-}" ]; then
  IFS=',' read -ra ids <<< "$CIVITAI_CHECKPOINTS"
  for id in "${ids[@]}"; do civitai_download "$(echo "$id" | xargs)" "$MODELS/checkpoints"; done
fi

# -----------------------------------------------------------------------------
# 5. RefMods
# -----------------------------------------------------------------------------
if [ -n "${REFMOD_URLS:-}" ]; then
  REFMOD_DIR="$CUSTOM_NODES/ComfyUI-MiniMaxH3Mod/mods"
  mkdir -p "$REFMOD_DIR"
  "$PIP" install --no-cache-dir gdown >/dev/null 2>&1 || true
  IFS=',' read -ra urls <<< "$REFMOD_URLS"
  for u in "${urls[@]}"; do
    u="$(echo "$u" | xargs)"
    log "Fetching RefMod: $u"
    if [[ "$u" == *drive.google.com* ]]; then
      gdown --fuzzy "$u" -O "$REFMOD_DIR/" || log "WARNING: gdown failed for $u"
    else
      wget -q --content-disposition -P "$REFMOD_DIR" "$u" || log "WARNING: download failed for $u"
    fi
  done
fi

log "Provisioning complete."
log "Expected layout:"
log "  $MODELS/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
log "  $MODELS/vae/minimax_h3_video_vae_fp16.safetensors"
log "  $MODELS/vae/minimax_h3_audio_vae_fp32.safetensors"
log "  $MODELS/diffusion_models/<fl2va + optional ref2va>"
log "  $MODELS/loras/<turbo / flashgen>"
