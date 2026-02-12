#!/usr/bin/env bash
# /opt/get_ltx2.sh  (resume-friendly)
set -euo pipefail

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"   # persistent HF cache
HF="/opt/venv/bin/hf"

MODEL_HOME="$HOME/comfy-models"
STAGE="$MODEL_HOME/.hf_stage_ltx2"                     # persistent staging (enables resume)

mkdir -p "$MODEL_HOME"/{checkpoints,text_encoders,loras,latent_upscale_models}
mkdir -p "$STAGE"

download_if_missing () {
  local repo="$1"
  local remote="$2"
  local dest_path="$3"  # Relative path under MODEL_HOME, e.g., "text_encoders"
  
  local dest_dir="$MODEL_HOME/$dest_path"
  local dest_file="$dest_dir/$(basename "$remote")"
  local staged="$STAGE/$remote"

  if [[ -f "$dest_file" ]]; then
    echo "✓ Already present: $dest_file"
    return
  fi

  echo "↓ Downloading $(basename "$remote") → $dest_file"
  mkdir -p "$(dirname "$staged")"        # ensure stage path exists
  mkdir -p "$dest_dir"                   # ensure dest dir exists

  "$HF" download "$repo" "$remote" \
      --repo-type model \
      --cache-dir "$HF_HOME" \
      --local-dir "$STAGE"
  mv -f "$staged" "$dest_file"
}

usage() {
  cat <<'USAGE'
Usage: get_ltx2.sh <target> [variant]

Targets:
  common       Text encoder (Gemma 3) + Spatial Upscaler
  checkpoint   LTX-2 19B Checkpoint (Default: BF16. Use 'fp8' as 2nd arg for FP8)
  lora         Distilled LoRA + Camera Control LoRA

Maintenance:
  clean-stage   Remove staging folder (keeps final models)
  clean-cache   Remove Hugging Face cache (~/.cache/huggingface)

Notes:
- Downloads RESUME automatically via persistent --cache-dir and --local-dir.
USAGE
}

case "${1:-}" in
  common)
    echo "==> Text Encoder + Spatial Upscaler"
    # Text Encoder: Gemma 3 12B IT FP4 Mixed
    download_if_missing "Comfy-Org/ltx-2" "split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors" "text_encoders"
    
    # Spatial Upscaler x2
    download_if_missing "Lightricks/LTX-2" "ltx-2-spatial-upscaler-x2-1.0.safetensors" "latent_upscale_models"
    ;;
  
  checkpoint)
    VARIANT="${2:-bf16}"
    echo "==> LTX-2 19B Checkpoint ($VARIANT)"
    
    if [[ "$VARIANT" == "fp8" ]]; then
        download_if_missing "Lightricks/LTX-2" "ltx-2-19b-dev-fp8.safetensors" "checkpoints"
    else
        # Default / BF16
        download_if_missing "Lightricks/LTX-2" "ltx-2-19b-dev.safetensors" "checkpoints"
    fi
    ;;
  
  lora)
    echo "==> LTX-2 LoRAs"
    # Distilled LoRA
    download_if_missing "Lightricks/LTX-2" "ltx-2-19b-distilled-lora-384.safetensors" "loras"
    
    # Camera Control LoRA
    # Using the specific repo for camera control if needed, or check if main repo has it.
    # User link: https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Left
    download_if_missing "Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Left" "ltx-2-19b-lora-camera-control-dolly-left.safetensors" "loras"
    ;;
  
  clean-stage)
    rm -rf "$STAGE"; echo "✓ Removed stage: $STAGE"
    ;;
  clean-cache)
    rm -rf "$HF_HOME"; echo "✓ Removed HF cache: $HF_HOME"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unknown target: $1" >&2
    usage
    exit 1
    ;;
esac

echo "✓ Done."
