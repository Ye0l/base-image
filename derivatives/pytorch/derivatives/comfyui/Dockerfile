ARG PYTORCH_BASE=vastai/pytorch:2.10.0-cu128-cuda-12.9-mini-py312-2026-03-19

FROM ${PYTORCH_BASE}

# Maintainer details
LABEL org.opencontainers.image.source="https://github.com/vastai/"
LABEL org.opencontainers.image.description="ComfyUI image suitable for Vast.ai."
LABEL maintainer="Vast.ai Inc <contact@vast.ai>"

# Copy Supervisor configuration and startup scripts
COPY ./ROOT /

# Required or we will not build
ARG COMFYUI_REF

RUN \
    set -euo pipefail && \
    [[ -n "${COMFYUI_REF}" ]] || { echo "Must specify COMFYUI_REF" && exit 1; } && \
    . /venv/main/bin/activate && \
    # We have PyTorch pre-installed so we will check at the end of the install that it has not been clobbered
    torch_version_pre="$(python -c 'import torch; print (torch.__version__)')" && \
    # Fail build on dependency resolution if matching version is unavailable
    uv pip install --no-cache-dir torch=="${PYTORCH_VERSION}" xformers sageattention==1.0.6 --torch-backend "${PYTORCH_BACKEND}" && \
    # Get ComfyUI and install dependencies (torch should not be pinned to a specific version in the requirements.txt - If it is then our build will probably fail)
    cd /opt/workspace-internal/ && \
    git clone https://github.com/Comfy-Org/ComfyUI && \
    cd /opt/workspace-internal/ComfyUI && \
    git checkout "${COMFYUI_REF}" && \
    uv pip install --no-cache-dir \
        -r requirements.txt && \
    # Avoid Jupyter directory display bug
    cd /opt/workspace-internal/ComfyUI/models/ && \
    ln -s checkpoints ckpt && \
    # Install critical custom nodes
    cd /opt/workspace-internal/ComfyUI/custom_nodes && \
    git clone https://github.com/Comfy-Org/ComfyUI-Manager && \
    uv pip install --no-cache-dir -r ComfyUI-Manager/requirements.txt && \
    git clone https://github.com/SethRobinson/comfyui-workflow-to-api-converter-endpoint && \
    # Quick startup test in CPU mode to ensure requirements ready and startup succeeds
    cd /opt/workspace-internal/ComfyUI && \
    LD_PRELOAD=libtcmalloc_minimal.so.4 \
         python main.py \
            --cpu \
            --listen 127.0.0.1 \
            --port 11404 \
            --disable-auto-launch \
            --quick-test-for-ci && \
    mkdir -p /opt/workspace-internal/ComfyUI/user/default/ComfyUI-Manager/components && \
    # Test 1: Verify PyTorch version is unaltered
    torch_version_post="$(python -c 'import torch; print (torch.__version__)')" && \
    [[ $torch_version_pre = $torch_version_post ]] || { echo "PyTorch version mismatch (wanted ${torch_version_pre} but got ${torch_version_post})"; exit 1; }

ENV COMFYUI_ARGS="--disable-auto-launch --enable-cors-header --port 18188"

# Install API wrapper
RUN \
    set -euo pipefail && \
    apt-get update && \
    apt-get install -y --no-install-recommends libmagic1 && \
    cd /opt && \
    git clone https://github.com/ai-dock/comfyui-api-wrapper && \
    cd comfyui-api-wrapper && \
    uv venv -p 3.12 && \
    . .venv/bin/activate && \
    uv pip install -r requirements.txt && \
    deactivate && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 커스텀 노드 및 모델 다운로드를 위한 환경 변수 (실제 API URL로 변경 필요)
ARG CUSTOM_API_URL="https://your-api-url.com/endpoint"

RUN \
    set -euo pipefail && \
    apt-get update && \
    apt-get install -y --no-install-recommends curl wget && \
    . /venv/main/bin/activate && \
    cd /opt/workspace-internal/ComfyUI/custom_nodes && \
    \
    # 1. 커스텀 노드 다운로드 및 의존성 설치
    echo "Fetching custom nodes..." && \
    NODES_PAYLOAD='{"target": "nodes"}' && \
    NODES_LIST=$(curl -s -X POST -H "Content-Type: application/json" -d "$NODES_PAYLOAD" "${CUSTOM_API_URL}") && \
    # 응답 앞뒤의 큰따옴표 제거
    NODES_LIST=$(echo "$NODES_LIST" | sed 's/"//g') && \
    # 세미콜론(;)을 기준으로 배열 분리
    IFS=';' read -ra NODE_URLS <<< "$NODES_LIST" && \
    for url in "${NODE_URLS[@]}"; do \
        if [ -n "$url" ]; then \
            echo "Cloning node: $url" && \
            git clone "$url" && \
            repo_name=$(basename "$url" .git) && \
            if [ -f "$repo_name/requirements.txt" ]; then \
                uv pip install --no-cache-dir -r "$repo_name/requirements.txt"; \
            fi \
        fi; \
    done && \
    \
    # 2. 커스텀 모델 다운로드
    echo "Fetching custom models..." && \
    MODELS_PAYLOAD='{"target": "build"}' && \
    MODELS_LIST=$(curl -s -X POST -H "Content-Type: application/json" -d "$MODELS_PAYLOAD" "${CUSTOM_API_URL}") && \
    MODELS_LIST=$(echo "$MODELS_LIST" | sed 's/"//g') && \
    IFS=';' read -ra MODEL_ENTRIES <<< "$MODELS_LIST" && \
    for entry in "${MODEL_ENTRIES[@]}"; do \
        if [ -n "$entry" ]; then \
            IFS='|' read -r model_url dest_path <<< "$entry"; \
            # /workspace/ComfyUI 경로를 현재 도커 환경에 맞게 /opt/workspace-internal/ComfyUI 로 치환
            real_dest_path=$(echo "$dest_path" | sed 's|^/workspace/ComfyUI|/opt/workspace-internal/ComfyUI|'); \
            mkdir -p "$(dirname "$real_dest_path")" && \
            echo "Downloading model to: $real_dest_path" && \
            wget -qO "$real_dest_path" "$model_url" || echo "Warning: Failed to download $model_url"; \
        fi; \
    done && \
    \
    # 3. 캐시 및 임시 파일 정리
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Generally we do not ship with models, but this is used for benchmarking the comfyui-json pyworker
# Always use a new RUN or COPY for each model added to keep layers to a reasonable size
RUN \
    set -euo pipefail && \
    mkdir /opt/model_store && \
    . /venv/main/bin/activate && \
    hf download Comfy-Org/stable-diffusion-v1-5-archive v1-5-pruned-emaonly-fp16.safetensors \
        --local-dir "/opt/model_store" && \
    # Symlink stored models to avoid moving large file to overlay/volume 
    ln -s /opt/model_store/v1-5-pruned-emaonly-fp16.safetensors \
        /opt/workspace-internal/ComfyUI/models/checkpoints/v1-5-pruned-emaonly-fp16.safetensors && \
    rm -rf /opt/model_store/.cache && \
    rm -rf /root/.cache/huggingface

RUN rm -f /opt/supervisor-scripts/pyworker.sh /etc/supervisor/conf.d/pyworker.conf
# Defend against environment clashes when syncing to volume
RUN \
    set -euo pipefail && \
    env-hash > /.env_hash
