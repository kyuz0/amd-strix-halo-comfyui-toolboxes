#!/usr/bin/env bash
# /opt/get_wan22.sh  (resume-friendly)
set -euo pipefail

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"   # persistent HF cache
HF="/opt/venv/bin/hf"

MODEL_HOME="$HOME/comfy-models"
STAGE="$MODEL_HOME/.hf_stage_wan22"                     # persistent staging (enables resume)

# Repositories
REPO_22="Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
REPO_21="Comfy-Org/Wan_2.1_ComfyUI_repackaged"
REPO_LORA="lightx2v/Wan2.2-Lightning"

mkdir -p "$MODEL_HOME"/{text_encoders,vae,diffusion_models,loras}
mkdir -p "$STAGE"

download_if_missing () {
  local repo="$1"
  local remote="$2"
  local dest_path="$3"  # Relative path under MODEL_HOME, e.g., "text_encoders" or "loras/subdir"
  
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
Usage: get_wan22.sh <target>

Targets:
  common     Text encoder + VAEs
             - text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors (from Wan 2.1)
             - vae/wan_2.1_vae.safetensors (from Wan 2.2)

  14b-t2v    14B T2V diffusion models (FP8)
             - diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors
             - diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors

  14b-i2v    14B I2V diffusion models (FP8)
             - diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors
             - diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors

  lora       Wan2.2 Lightning LoRAs
             - T2V (Seko V2): loras/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V2/...
             - I2V (Seko V1):   loras/Wan2.2-I2V-A14B-4steps-lora-rank64-Seko-V1/...

Maintenance:
  clean-stage   Remove staging folder (keeps final models)
  clean-cache   Remove Hugging Face cache (~/.cache/huggingface)

Notes:
- Downloads RESUME automatically via persistent --cache-dir and --local-dir.
USAGE
}

case "${1:-}" in
  common)
    echo "==> text encoder + VAEs"
    # Text Encoder from Wan 2.1
    download_if_missing "$REPO_21" "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "text_encoders"
    # VAE from Wan 2.2
    download_if_missing "$REPO_22" "split_files/vae/wan_2.1_vae.safetensors" "vae"
    ;;
  14b-t2v)
    echo "==> 14B Text→Video (FP8)"
    download_if_missing "$REPO_22" "split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors" "diffusion_models"
    download_if_missing "$REPO_22" "split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" "diffusion_models"
    ;;
  14b-i2v)
    echo "==> 14B Image→Video (FP8)"
    download_if_missing "$REPO_22" "split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors" "diffusion_models"
    download_if_missing "$REPO_22" "split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors" "diffusion_models"
    ;;
  lora)
    echo "==> Wan2.2 Lightning LoRAs (Seko V2)"
    LORA_SUBDIR_T2V="loras/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V2.0"
    download_if_missing "$REPO_LORA" "Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V2.0/high_noise_model.safetensors" "$LORA_SUBDIR_T2V"
    download_if_missing "$REPO_LORA" "Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V2.0/low_noise_model.safetensors" "$LORA_SUBDIR_T2V"

    LORA_SUBDIR_I2V="loras/Wan2.2-I2V-A14B-4steps-lora-rank64-Seko-V1"
    download_if_missing "$REPO_LORA" "Wan2.2-I2V-A14B-4steps-lora-rank64-Seko-V1/high_noise_model.safetensors" "$LORA_SUBDIR_I2V"
    download_if_missing "$REPO_LORA" "Wan2.2-I2V-A14B-4steps-lora-rank64-Seko-V1/low_noise_model.safetensors" "$LORA_SUBDIR_I2V"
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
