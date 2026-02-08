FROM registry.fedoraproject.org/fedora:rawhide

# Base packages (keep compilers/headers for Triton JIT at runtime)
RUN --mount=type=cache,target=/var/cache/libdnf5/ \
    dnf -y --setopt=keepcache=1 --setopt=install_weak_deps=False --nodocs update

RUN --mount=type=cache,target=/var/cache/libdnf5/ \
    dnf -y --setopt=keepcache=1 --setopt=install_weak_deps=False --nodocs install \
    ca-certificates curl bash \
    libdrm-devel python3.13 python3.13-devel git rsync libatomic \
    gcc gcc-c++ binutils procps-ng make git ffmpeg-free nano dialog uv

# Python venv
ENV UV_CACHE_DIR=/root/.cache/uv
ENV UV_LINK_MODE=copy
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv --relocatable --python 3.13 /opt/venv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH=/opt/venv/bin:$PATH
RUN printf 'source /opt/venv/bin/activate\n' > /etc/profile.d/venv.sh

RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --upgrade setuptools wheel

# Helper scripts (ComfyUI-only)
COPY scripts/get_wan22.sh /opt/
COPY scripts/set_extra_paths.sh /opt/
COPY scripts/get_qwen_image.sh /opt/
COPY scripts/get_hunyuan15.sh /opt/
COPY scripts/benchmark_workflows.py /opt/
COPY scripts/collect_perf_logs.py /opt/
COPY scripts/model_manager.py /opt/
COPY workflows/API /opt/comfy-workflows


# ROCm + PyTorch (TheRock, include torchaudio for resolver; remove later)
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --index-url https://rocm.nightlies.amd.com/v2-staging/gfx1151 \
    --pre torch torchaudio torchvision

WORKDIR /opt

# Pin specific transformers version
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install transformers==4.56.2

# ComfyUI
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install -r /opt/ComfyUI/requirements.txt && \
    uv pip install \
    pillow opencv-python-headless imageio imageio-ffmpeg scipy "huggingface_hub[hf_transfer]" pyyaml websocket-client

COPY workflows/input/ai-server.jpg /opt/ComfyUI/input/
COPY workflows/input/ai-server-2.png /opt/ComfyUI/input/
COPY workflows/*.json /opt/ComfyUI/user/default/workflows/

# ComfyUI plugins
RUN git clone --depth=1 https://github.com/cubiq/ComfyUI_essentials /opt/ComfyUI/custom_nodes/ComfyUI_essentials
RUN git clone --depth=1 https://github.com/kyuz0/ComfyUI-AMDGPUMonitor /opt/ComfyUI/custom_nodes/ComfyUI-AMDGPUMonitor
RUN git clone --depth=1 https://github.com/city96/ComfyUI-GGUF /opt/ComfyUI/custom_nodes/ComfyUI-GGUF

# Qwen Image Studio
RUN git clone --depth=1 https://github.com/kyuz0/qwen-image-studio /opt/qwen-image-studio
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install -r /opt/qwen-image-studio/requirements.txt

# Wan Video Studio
RUN git clone --depth=1 https://github.com/kyuz0/wan-video-studio /opt/wan-video-studio
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install \
    opencv-python-headless diffusers tokenizers accelerate \
    imageio[ffmpeg] easydict ftfy dashscope imageio-ffmpeg decord librosa

# Permissions & trims (keep compilers/headers)
RUN echo "Disk usage of /opt before cleanup = $(du -hs /opt | cut -f 1) / $(du -ks /opt | cut -f 1)K" && \
    chmod -R a+rwX /opt && chmod +x /opt/*.sh || true && \
    find /opt/venv -type f -name "*.so" -exec strip -s {} + 2>/dev/null || true && \
    find /opt/venv -type d -name "__pycache__" -prune -exec rm -rf {} + && \
    echo "Disk usage of /opt after cleanup =  $(du -hs /opt | cut -f 1) / $(du -ks /opt | cut -f 1)K"

# Enable torch TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL
COPY scripts/01-rocm-env-for-triton.sh /etc/profile.d/01-rocm-env-for-triton.sh

# Banner script (runs on login). Use a high sort key so it runs after venv.sh and 01-rocm-env...
COPY scripts/99-toolbox-banner.sh /etc/profile.d/99-toolbox-banner.sh
RUN chmod 0644 /etc/profile.d/99-toolbox-banner.sh

# Keep /opt/venv/bin first after user dotfiles
COPY scripts/zz-venv-last.sh /etc/profile.d/zz-venv-last.sh
RUN chmod 0644 /etc/profile.d/zz-venv-last.sh

# Disable core dumps in interactive shells (helps with recovering faster from ROCm crashes)
RUN printf 'ulimit -S -c 0\n' > /etc/profile.d/90-nocoredump.sh && chmod 0644 /etc/profile.d/90-nocoredump.sh

RUN --mount=type=cache,target=/root/.cache/uv --mount=type=cache,target=/var/cache/libdnf5/ \
    echo "Disk usage of /root/.cache/uv =  $(du -hs /root/.cache/uv | cut -f 1)" && \
    echo "Disk usage of /var/cache/libdnf5/ =  $(du -hs /var/cache/libdnf5/ | cut -f 1)"

CMD ["/usr/bin/bash"]
