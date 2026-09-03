# Practical Guide: Using the Toolbox from China
# 国内用户使用指南

> This guide documents how to use the toolbox from within mainland China, where `huggingface.co` is unreachable. It covers mirror configuration and a download workaround for an `huggingface_hub` compatibility issue.
>
> 本文记录在国内网络环境下的使用方法,解决 `huggingface.co` 不可达以及 `huggingface_hub` 兼容性问题导致的模型下载失败。

---

## The Problem / 问题

All model weights are hosted on HuggingFace. In mainland China, `huggingface.co` is not directly reachable, so the bundled `model_manager` / `get_*.sh` scripts fail with:

所有模型权重托管在 HuggingFace。国内无法直接访问 `huggingface.co`,容器自带的 `model_manager` / `get_*.sh` 脚本会报错:

```
huggingface_hub.errors.FileMetadataError: Distant resource does not seem to be on huggingface.co.
```

There are two distinct causes behind this single error message:

这个错误有两个不同的根因:

1. **`HF_ENDPOINT` is not set** — `hf` connects to `huggingface.co` by default, which times out or returns a polluted DNS response. / 脚本未设置 `HF_ENDPOINT`,`hf` 默认直连 `huggingface.co`,超时或被 DNS 污染。
2. **`huggingface_hub` 0.36.2 metadata bug** — even with the endpoint correctly set (verified via `ord()` that the env var is clean, `constants.ENDPOINT` is correct, and `hf_hub_url()` builds the right URL), the library still fails. / 即使 endpoint 设置正确,容器内的 `huggingface_hub` 0.36.2 仍会失败。

---

## Fix 1: Set the Mirror Endpoint / 设置镜像端点

Add these to the top of each `get_*.sh` script (or export them before running `model_manager`):

在每个 `get_*.sh` 脚本头部添加(或在运行 `model_manager` 前 export):

```bash
export HF_ENDPOINT="https://hf-mirror.com"
export HF_HUB_DISABLE_XET=1
export HF_HUB_ENABLE_HF_TRANSFER=0
```

- `HF_ENDPOINT` — points to the hf-mirror.com mirror / 指向 hf-mirror.com 镜像
- `HF_HUB_DISABLE_XET=1` — skips the hf_xet fast path, which bypasses the endpoint and talks to `xethub.hf.co` directly (also unreachable) / 跳过 hf_xet 快路径(绕过 endpoint 直连 xethub.hf.co,国内不通)
- `HF_HUB_ENABLE_HF_TRANSFER=0` — disables hf_transfer, which ignores the mirror / 关闭 hf_transfer(不认镜像)

---

## Fix 2: Bypass huggingface_hub with curl / 用 curl 绕过 huggingface_hub

If Fix 1 alone doesn't work (due to the 0.36.2 bug), bypass `huggingface_hub` entirely and download with `curl`. This script downloads LTX-2 files from the mirror, with resume support and size verification:

如果 Fix 1 仍失败(0.36.2 bug),用以下脚本绕过 `huggingface_hub`,直接用 `curl` 下载。支持断点续传和大小校验:

```python
#!/usr/bin/env python3
"""Download model files from hf-mirror.com (bypasses huggingface_hub)"""
import os, subprocess

MIRROR = "https://hf-mirror.com"
BASE = os.path.expanduser("~/comfy-models")
for d in ["checkpoints", "text_encoders", "loras", "latent_upscale_models"]:
    os.makedirs(os.path.join(BASE, d), exist_ok=True)

# (repo, repo_path, dest_subdir, expected_size_bytes)
# expected_size = None: trust curl exit code, skip size check
FILES = [
    ("Lightricks/LTX-2", "ltx-2-spatial-upscaler-x2-1.0.safetensors", "latent_upscale_models", 995765578),
    ("Comfy-Org/ltx-2", "split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors", "text_encoders", 9447702218),
    ("Lightricks/LTX-2", "ltx-2-19b-dev.safetensors", "checkpoints", None),
    ("Lightricks/LTX-2", "ltx-2-19b-distilled-lora-384.safetensors", "loras", None),
    ("Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Left", "ltx-2-19b-lora-camera-control-dolly-left.safetensors", "loras", None),
]

def get_size(path):
    return os.path.getsize(path) if os.path.exists(path) else 0

def download_one(repo, fpath, subdir, expected):
    fname = os.path.basename(fpath)
    dest = os.path.join(BASE, subdir, fname)
    url = f"{MIRROR}/{repo}/resolve/main/{fpath}"

    cur = get_size(dest)
    if expected and cur == expected:
        print("SKIP (complete):", fname); return True
    if cur > 0 and not expected:
        print("SKIP (exists):", fname, cur, "bytes"); return True

    print(f"\n=== {fname} ===", flush=True)
    for attempt in range(1, 16):
        cur = get_size(dest)
        if expected and cur == expected:
            print(f"  COMPLETE: {cur} bytes"); return True
        print(f"  attempt {attempt}/15, current: {cur} bytes", flush=True)
        cmd = ["curl", "-L", "-C", "-", "--retry", "5", "--retry-delay", "3",
               "--connect-timeout", "30", "--max-time", "7200", "-o", dest, url]
        ret = subprocess.run(cmd)
        cur = get_size(dest)
        print(f"  curl exited {ret.returncode}, size now: {cur} bytes", flush=True)
        if expected and cur == expected:
            print(f"  COMPLETE: {cur} bytes"); return True
        if not expected and cur > 0 and ret.returncode == 0:
            print(f"  DONE: {cur} bytes"); return True
    print(f"  FAILED after 15 attempts: {fname}"); return False

if __name__ == "__main__":
    for f in FILES:
        download_one(*f)
```

Adapt the `FILES` list for other workflows (Qwen Image, Wan 2.2, HunyuanVideo) by checking the corresponding `get_*.sh` script:

其它工作流(Qwen Image、Wan 2.2、HunyuanVideo)的文件清单,查看对应脚本获取:

```bash
grep -E 'download_if_missing' /opt/get_wan22.sh
```

---

## Diagnostic Trap: Terminal Display Illusion / 排查陷阱:终端显示假象

When debugging `HF_ENDPOINT`, terminal output (e.g. `repr()`, `grep`) may show backticks around the URL that aren't actually in the variable. Verify with `ord()`:

排查时,终端显示(`repr()`、`grep`)可能在 URL 两侧显示并不存在的反引号。用 `ord()` 验证真实内容:

```python
import os
url = os.environ.get("HF_ENDPOINT", "")
print("ords:", [ord(c) for c in url])
print("has backtick(96):", 96 in [ord(c) for c in url])  # False = clean
```

`ord()` bypasses the text display layer and reveals the true character codes. / `ord()` 绕过文本显示层,显示真实字符码。

---

## File Locations / 文件位置

| Content / 内容 | Location / 位置 | Notes / 说明 |
|---|---|---|
| Model files / 模型文件 | `~/comfy-models/` | Host home dir, visible in container / 宿主机家目录,容器内可见 |
| Download scripts / 下载脚本 | `/opt/get_*.sh` | In container, overwritten on refresh / 容器内,刷新会覆盖 |
| Model manager / 菜单工具 | `/opt/model_manager.py` | Calls `get_*.sh` via subprocess / 通过 subprocess 调用脚本 |

`toolbox` only mounts the home directory; `/opt` is an image layer invisible to the host file manager. Models in `~/comfy-models` survive container refreshes.

`toolbox` 只挂载家目录,`/opt` 是镜像层,宿主机文件管理器看不到。`~/comfy-models` 里的模型在刷新容器后保留。

---

## Summary / 小结

The container environment and ROCm setup are excellent. The obstacle for Chinese users is the HuggingFace network issue, amplified by two factors: unset endpoint and an `huggingface_hub` 0.36.2 bug. Both produce the same `FileMetadataError`. When a library has a bug, use the standard library to verify the server response directly, then bypass the library.

容器环境和 ROCm 配置本身很好。国内用户的障碍是 HuggingFace 网络问题,由 endpoint 未配置和 `huggingface_hub` 0.36.2 bug 叠加导致,两者表象相同。当库本身有 bug 时,用标准库直接验证服务端响应,然后绕过库实现下载。
