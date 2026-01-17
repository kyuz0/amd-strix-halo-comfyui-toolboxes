#!/usr/bin/env bash
# /opt/get_hunyuan15.sh (resume-friendly)
# Downloads models for ComfyUI HunyuanVideo 1.5 (T2V & I2V)
set -euo pipefail

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
HF="/opt/venv/bin/hf"

MODEL_HOME="$HOME/comfy-models"
STAGE="$MODEL_HOME/.hf_stage_hunyuan15"

# Repositories
REPO_MAIN="Comfy-Org/HunyuanVideo_1.5_repackaged"
REPO_VISION="Comfy-Org/sigclip_vision_384"

# Ensure directories exist
mkdir -p "$MODEL_HOME"/{text_encoders,vae,diffusion_models,clip_vision,latent_upscale_models,loras}
  mkdir -p "$STAGE"

  download_if_missing () {
    local repo="$1"
    local remote="$2"
    local dest_path="$3"
    
    local dest_dir="$MODEL_HOME/$dest_path"
    local dest_file="$dest_dir/$(basename "$remote")"
    local staged="$STAGE/$remote"
  
    if [[ -f "$dest_file" ]]; then
      echo "✓ Already present: $dest_file"
      return
    fi
  
    echo "↓ Downloading $(basename "$remote") → $dest_file"
    mkdir -p "$(dirname "$staged")"
    mkdir -p "$dest_dir"
  
    "$HF" download "$repo" "$remote" \
        --repo-type model \
        --cache-dir "$HF_HOME" \
        --local-dir "$STAGE"
    mv -f "$staged" "$dest_file"
  }
  
  usage() {
  cat <<'USAGE'
  Usage: get_hunyuan15.sh <target>
  
  Targets:
    common     Text Encoders, VAE, CLIP Vision (Shared dependencies)
               - text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors
               - text_encoders/byt5_small_glyphxl_fp16.safetensors
               - vae/hunyuanvideo15_vae_fp16.safetensors
               - clip_vision/sigclip_vision_patch14_384.safetensors (Only for I2V)
  
    720p-t2v   Text-to-Video Model (FP16)
               - diffusion_models/hunyuanvideo1.5_720p_t2v_fp16.safetensors
  
    720p-i2v   Image-to-Video Model (FP16)
               - diffusion_models/hunyuanvideo1.5_720p_i2v_fp16.safetensors
  
    upscale    Upscaling Models (1080p SR + Latent Upsampler)
               - diffusion_models/hunyuanvideo1.5_1080p_sr_distilled_fp16.safetensors
               - latent_upscale_models/hunyuanvideo15_latent_upsampler_1080p.safetensors

    lora       HunyuanVideo 1.5 LoRAs
               - loras/hunyuanvideo1.5_t2v_480p_lightx2v_4step_lora_rank_32_bf16.safetensors
  
    all        Download EVERYTHING (T2V, I2V, Upscale, LoRA, Common)
  
  Maintenance:
    clean-stage   Remove staging folder (keeps final models)
    clean-cache   Remove Hugging Face cache (~/.cache/huggingface)
  
USAGE
  }
  
  case "${1:-}" in
    common)
      echo "==> Text Encoders, VAE, & CLIP Vision"
      download_if_missing "$REPO_MAIN" "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" "text_encoders"
      download_if_missing "$REPO_MAIN" "split_files/text_encoders/byt5_small_glyphxl_fp16.safetensors" "text_encoders"
      download_if_missing "$REPO_MAIN" "split_files/vae/hunyuanvideo15_vae_fp16.safetensors" "vae"
      download_if_missing "$REPO_VISION" "sigclip_vision_patch14_384.safetensors" "clip_vision"
      ;;
  
    720p-t2v)
      echo "==> 720p Text-to-Video Model"
      download_if_missing "$REPO_MAIN" "split_files/diffusion_models/hunyuanvideo1.5_720p_t2v_fp16.safetensors" "diffusion_models"
      ;;
      
    720p-i2v)
      echo "==> 720p Image-to-Video Model"
      download_if_missing "$REPO_MAIN" "split_files/diffusion_models/hunyuanvideo1.5_720p_i2v_fp16.safetensors" "diffusion_models"
      ;;
      
    upscale)
      echo "==> 1080p Upscaling Models"
      download_if_missing "$REPO_MAIN" "split_files/diffusion_models/hunyuanvideo1.5_1080p_sr_distilled_fp16.safetensors" "diffusion_models"
      download_if_missing "$REPO_MAIN" "split_files/latent_upscale_models/hunyuanvideo15_latent_upsampler_1080p.safetensors" "latent_upscale_models"
      ;;

    lora)
      echo "==> HunyuanVideo 1.5 LoRAs"
      download_if_missing "$REPO_MAIN" "split_files/loras/hunyuanvideo1.5_t2v_480p_lightx2v_4step_lora_rank_32_bf16.safetensors" "loras"
      ;;
  
    all)
      echo "==> Downloading Full Suite (T2V + I2V + Upscale + LoRA)..."
      "$0" common
      "$0" 720p-t2v
      "$0" 720p-i2v
      "$0" upscale
      "$0" lora
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