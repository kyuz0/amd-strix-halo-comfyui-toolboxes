FROM registry.fedoraproject.org/fedora:rawhide

# Base packages (keep compilers/headers for Triton JIT at runtime)
RUN dnf -y install --setopt=install_weak_deps=False --nodocs \
    libdrm-devel python3.13 python3.13-devel git rsync libatomic bash ca-certificates curl \
    gcc gcc-c++ binutils make git ffmpeg-free vim dialog \
    && dnf clean all && rm -rf /var/cache/dnf/*

# Python venv
RUN /usr/bin/python3.13 -m venv /opt/venv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH=/opt/venv/bin:$PATH
ENV PIP_NO_CACHE_DIR=1
RUN printf 'source /opt/venv/bin/activate\n' > /etc/profile.d/venv.sh
RUN python -m pip install --upgrade pip setuptools wheel

# Helper scripts (ComfyUI-only)
COPY scripts/get_wan22.sh /opt/
COPY scripts/set_extra_paths.sh /opt/
COPY scripts/get_qwen_image.sh /opt/
COPY scripts/get_hunyuan15.sh /opt/
COPY scripts/get_ltx2.sh /opt/
COPY scripts/get_minimax_h3.sh /opt/
COPY scripts/benchmark_workflows.py /opt/
COPY scripts/collect_perf_logs.py /opt/
COPY scripts/model_manager.py /opt/
RUN chmod 0755 /opt/model_manager.py && ln -s /opt/model_manager.py /opt/venv/bin/model_manager
COPY workflows/API /opt/comfy-workflows


# ROCm + PyTorch (TheRock multi-arch release, scoped to Strix Halo gfx1151)
RUN python -m pip install \
    --index-url https://rocm.nightlies.amd.com/whl-multi-arch/ \
    --pre "torch[device-gfx1151]" "torchvision[device-gfx1151]" torchaudio

WORKDIR /opt

# ComfyUI
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI 
WORKDIR /opt/ComfyUI
ENV FLASH_ATTENTION_TRITON_AMD_ENABLE="TRUE"
ENV FLASH_ATTENTION_FWD_TRITON_AMD_CONFIG_JSON='{"BLOCK_M":128,"BLOCK_N":64,"waves_per_eu":1,"PRE_LOAD_V":false,"num_stages":1,"num_warps":8}'
RUN python -m pip install -r requirements.txt && \
    python -m pip install --prefer-binary \
    pillow opencv-python-headless imageio imageio-ffmpeg scipy "huggingface_hub[hf_transfer]" pyyaml websocket-client && \
    pip install flash-attn --no-build-isolation

COPY workflows/input/ai-server.jpg /opt/ComfyUI/input/
COPY workflows/input/ai-server-2.png /opt/ComfyUI/input/
COPY workflows/input/example2.jpg /opt/ComfyUI/input/

COPY workflows/*.json /opt/ComfyUI/user/default/workflows/

# ComfyUI plugins
WORKDIR /opt/ComfyUI/custom_nodes
RUN git clone --depth=1 https://github.com/cubiq/ComfyUI_essentials /opt/ComfyUI/custom_nodes/ComfyUI_essentials 
RUN git clone --depth=1 https://github.com/kyuz0/ComfyUI-AMDGPUMonitor /opt/ComfyUI/custom_nodes/ComfyUI-AMDGPUMonitor 
RUN git clone --depth=1 https://github.com/kyuz0/ComfyUI-GGUF-H3 /opt/ComfyUI/custom_nodes/ComfyUI-GGUF && \
    python -m pip install -r /opt/ComfyUI/custom_nodes/ComfyUI-GGUF/requirements.txt
RUN git clone --depth=1 https://github.com/Larryvrh/ComfyUI-MiniMax-H3-Turbo /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-Turbo

# Permissions & trims (keep compilers/headers and installed shared libraries intact)
RUN chmod -R a+rwX /opt && chmod +x /opt/*.sh || true && \
    find /opt/venv -type d -name "__pycache__" -prune -exec rm -rf {} + && \
    python -m pip cache purge || true && rm -rf /root/.cache/pip || true && \
    dnf clean all && rm -rf /var/cache/dnf/*

# Catch incompatible or damaged PyTorch shared libraries before publishing an image.
RUN python -c 'import torch; print(torch.__version__)'

# Enable torch TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL
COPY scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh

# Banner script (runs on login). Use a high sort key so it runs after venv.sh and 01-rocm-env...
COPY scripts/99-toolbox-banner.sh /etc/profile.d/99-toolbox-banner.sh
RUN chmod 0644 /etc/profile.d/99-toolbox-banner.sh

# Keep /opt/venv/bin first after user dotfiles
COPY scripts/zz-venv-last.sh /etc/profile.d/zz-venv-last.sh
RUN chmod 0644 /etc/profile.d/zz-venv-last.sh

# Disable core dumps in interactive shells (helps with recovering faster from ROCm crashes)
RUN printf 'ulimit -S -c 0\n' > /etc/profile.d/90-nocoredump.sh && chmod 0644 /etc/profile.d/90-nocoredump.sh

CMD ["/bin/bash"]
