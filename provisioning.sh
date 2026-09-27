#!/bin/bash
# =============================================================================
# Muse Character Sheet H3 — RunPod provisioning script
# Base image: ghcr.io/ai-dock/comfyui:latest-cuda   (see README.md)
# Runs automatically at pod boot via the PROVISIONING_SCRIPT env var.
# Style/env-var naming inspired by the existing MiniMax H3 RunPod template
# (download_minimax_h3 / minimax_quant / civitai_token / CIVITAI_LORAS /
# CIVITAI_CHECKPOINTS / LLM_KEY / HF_TOKEN) plus the extras this specific
# character-sheet workflow needs on top of a plain MiniMax H3 install.
# =============================================================================
set -euo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/opt/ComfyUI}"
[ -d "$COMFYUI_DIR" ] || COMFYUI_DIR="/workspace/ComfyUI"
PIP="${COMFYUI_VENV_PIP:-pip}"
CUSTOM_NODES="$COMFYUI_DIR/custom_nodes"
MODELS="$COMFYUI_DIR/models"
WORKFLOWS="$COMFYUI_DIR/user/default/workflows"
mkdir -p "$CUSTOM_NODES" "$MODELS"/{diffusion_models,loras,text_encoders,vae} "$WORKFLOWS"

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
# 1. Python deps this workflow's custom nodes rely on
# -----------------------------------------------------------------------------
log "Force-updating ComfyUI core (ai-dock's own AUTO_UPDATE is unreliable)"
if [ -d "$COMFYUI_DIR/.git" ]; then
  git -C "$COMFYUI_DIR" fetch --depth 1 origin master
  git -C "$COMFYUI_DIR" reset --hard origin/master
  log "Reinstalling ComfyUI core's own requirements.txt (new core often needs new deps)"
  "$PIP" install --no-cache-dir -r "$COMFYUI_DIR/requirements.txt"
else
  log "WARNING: $COMFYUI_DIR is not a git checkout, skipping core update"
fi

log "Installing PyAV + psutil + huggingface-cli into ComfyUI's own venv"
"$PIP" install --no-cache-dir av psutil "huggingface_hub[cli]"

# -----------------------------------------------------------------------------
# 2. Custom nodes required to load this workflow
# -----------------------------------------------------------------------------
clone_or_pull "https://github.com/muse-collective-26/Muse-CharacterSheet-H3.git"
clone_or_pull "https://github.com/muse-collective-26/Muse-MiniMax-H3-Unified-Loader.git"
clone_or_pull "https://github.com/kijai/ComfyUI-KJNodes.git"
clone_or_pull "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
clone_or_pull "https://github.com/WASasquatch/was-node-suite-comfyui.git"
clone_or_pull "https://github.com/MohammadAboulEla/ComfyUI-iTools.git"

# Optional: only pulled if the matching feature is enabled below
if [ "${use_two_stage_sampling:-false}" = "true" ]; then
  clone_or_pull "https://github.com/jlucasmcrell/ComfyUI-H3-Multishot.git"
fi
if [ "${use_refmod:-true}" = "true" ]; then
  clone_or_pull "https://github.com/Luisacaotica/ComfyUI-MiniMaxH3Mod.git"
fi

# comfyui_memory_cleanup (RAMCleanup / VRAMCleanup nodes) — installed via
# ComfyUI-Manager's registry name since it isn't on a fixed public git URL
# across all mirrors. Verify the exact repo once and hardcode it here if you
# want it pinned instead of resolved through Manager.
if [ ! -d "$CUSTOM_NODES/comfyui_memory_cleanup" ] && [ -x "$CUSTOM_NODES/ComfyUI-Manager/cm-cli.py" ]; then
  log "Installing comfyui_memory_cleanup via ComfyUI-Manager"
  python "$CUSTOM_NODES/ComfyUI-Manager/cm-cli.py" install comfyui_memory_cleanup || \
    log "WARNING: could not auto-install comfyui_memory_cleanup — install it by name from the Manager UI"
fi

# The example workflow ships inside the Muse-CharacterSheet-H3 repo itself
if [ -f "$CUSTOM_NODES/Muse-CharacterSheet-H3/workflows/H3 Character Sheet.json" ]; then
  cp "$CUSTOM_NODES/Muse-CharacterSheet-H3/workflows/H3 Character Sheet.json" "$WORKFLOWS/"
fi

# -----------------------------------------------------------------------------
# 3. Base MiniMax H3 models (mirrors the existing template's toggle/quant)
# -----------------------------------------------------------------------------
download_minimax_h3="${download_minimax_h3:-true}"
minimax_quant="${minimax_quant:-int8}"   # int8 | fp8 | nvfp4 | false(=bf16)

VENV_BIN="$(dirname "${COMFYUI_VENV_PYTHON:-/usr/bin/python3}")"
if [ -x "$VENV_BIN/hf" ]; then
  HF_BIN="$VENV_BIN/hf"
elif [ -x "$VENV_BIN/huggingface-cli" ]; then
  HF_BIN="$VENV_BIN/huggingface-cli"
else
  HF_BIN="hf"
fi
hf_dl () { "$HF_BIN" download "$@"; }

if [ "$download_minimax_h3" = "true" ]; then
  log "Downloading MiniMax H3 base models (quant: $minimax_quant)"
  [ -n "${HF_TOKEN:-}" ] && huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential || true

  # NOTE: exact filenames differ per quant and shift as Comfy-Org/Kijai update
  # their repos. Check the file list on the repo before a fresh deploy:
  #   https://huggingface.co/Comfy-Org/MiniMax-H3
  #   https://huggingface.co/Kijai/MiniMax-H3_comfy
  #   https://huggingface.co/Kijai/MiniMax-H3-experimental
  # Override any of these with an explicit filename via env var if the repo
  # has moved on since this script was written.
  DIT_FILE="${MINIMAX_DIT_FILE:-minimax_h3_fastvideo_vsa_datafree_1300step_4step_${minimax_quant}_convrot.safetensors}"
  CLIP_FILE="${MINIMAX_CLIP_FILE:-qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors}"
  VAE_FILE="${MINIMAX_VAE_FILE:-minimax_h3_video_vae_fp16.safetensors}"
  AUDIO_VAE_FILE="${MINIMAX_AUDIO_VAE_FILE:-minimax_h3_audio_vae_fp32.safetensors}"
  TURBO_LORA_FILE="${MINIMAX_TURBO_LORA_FILE:-minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors}"

  hf_dl Comfy-Org/MiniMax-H3 "$CLIP_FILE"      --local-dir "$MODELS/text_encoders" || true
  hf_dl Comfy-Org/MiniMax-H3 "$VAE_FILE"       --local-dir "$MODELS/vae" || true
  hf_dl Comfy-Org/MiniMax-H3 "$AUDIO_VAE_FILE" --local-dir "$MODELS/vae" || true
  hf_dl Kijai/MiniMax-H3_comfy "$DIT_FILE"        --local-dir "$MODELS/diffusion_models" || true
  hf_dl Kijai/MiniMax-H3_comfy "$TURBO_LORA_FILE" --local-dir "$MODELS/loras" || true
fi

# -----------------------------------------------------------------------------
# 4. Community LoRAs / checkpoints from CivitAI (MysticXXX_MMH3-V1,
#    h3-realism-people-t2v-i2v-r2v, etc.) — put their model-VERSION ids in
#    CIVITAI_LORAS / CIVITAI_CHECKPOINTS as a comma-separated list.
# -----------------------------------------------------------------------------
civitai_download () {
  local id="$1" dest="$2"
  local token_qs=""
  [ -n "${civitai_token:-}" ] && token_qs="?token=${civitai_token}"
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
# 5. Your own RefMods (e.g. isabella_Rae1_mod) — comma-separated direct or
#    Google Drive URLs in REFMOD_URLS. Requires ComfyUI-MiniMaxH3Mod (step 2).
# -----------------------------------------------------------------------------
if [ -n "${REFMOD_URLS:-}" ]; then
  REFMOD_DIR="$CUSTOM_NODES/ComfyUI-MiniMaxH3Mod/mods"
  mkdir -p "$REFMOD_DIR"
  pip install --no-cache-dir gdown >/dev/null 2>&1 || true
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
