#!/usr/bin/env bash
set -euo pipefail

# 1. logger 패키지 설치 (명령어 실행 전 확실하게 준비)
apt-get update && apt-get install -y bsdutils

LOG_FILE="/workspace/provisioning.log"

# 2. tee 명령어에 프로세스 치환 >(...)을 추가하여 logger로 데이터 전송
exec > >(tee -a "$LOG_FILE" >(logger -n lab.kstr.dev -P 1514 -d -t "vast-ai-comfyui")) 2>&1

# 🌟 [여기 추가] 무한 대기(Deadlock) 방지용 환경변수 세팅
export PIP_NO_INPUT=1
export GIT_TERMINAL_PROMPT=0
export DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. n8n 동적 데이터 호출 (Vast.ai 환경 변수 N8N_WEBHOOK_URL 필요)
# ============================================================
MY_WGET_MODELS=""
NODES=()

log(){ echo "[provision] $*"; }

if [ -n "${N8N_WEBHOOK_URL:-}" ]; then
    log "🌐 n8n API에서 프로비저닝 데이터를 동적으로 호출합니다..."
    
    MY_WGET_MODELS=$(wget -qO- --post-data='{"target": "models"}' \
        --header='Content-Type: application/json' "$N8N_WEBHOOK_URL" || echo "")
        
    MY_CUSTOM_NODES=$(wget -qO- --post-data='{"target": "nodes"}' \
        --header='Content-Type: application/json' "$N8N_WEBHOOK_URL" || echo "")

    # 커스텀 노드 리스트를 배열(NODES)로 변환
    if [ -n "$MY_CUSTOM_NODES" ] && [ "$MY_CUSTOM_NODES" != "null" ]; then
        IFS=';' read -ra NODE_ARRAY <<< "$MY_CUSTOM_NODES"
        for repo in "${NODE_ARRAY[@]}"; do
            [[ -z "${repo// }" ]] && continue
            NODES+=("$repo")
        done
    fi
fi



replace_with_link() {
    local SOURCE_DIR="$1"  # 링크할 원본 (b)
    local TARGET_LINK="$2" # 삭제하고 링크로 만들 이름 (a)

    echo "--- 작업 시작: $TARGET_LINK -> $SOURCE_DIR ---"

    # 대상(TARGET_LINK)이 존재하는지 확인
    if [ -e "$TARGET_LINK" ]; then
        if [ -L "$TARGET_LINK" ]; then
            echo "알림: '$TARGET_LINK'는 이미 심볼릭 링크입니다. 기존 링크를 제거합니다."
            rm "$TARGET_LINK"
        elif [ -d "$TARGET_LINK" ]; then
            echo "알림: 기존 폴더 '$TARGET_LINK'를 삭제합니다."
            rm -rf "$TARGET_LINK"
        else
            echo "알림: '$TARGET_LINK'가 일반 파일입니다. 삭제합니다."
            rm "$TARGET_LINK"
        fi
    fi

    # 원본(SOURCE_DIR) 존재 여부 확인 후 링크 생성
    if [ -d "$SOURCE_DIR" ]; then
        ln -s "$SOURCE_DIR" "$TARGET_LINK"
        echo "성공: '$TARGET_LINK'가 '$SOURCE_DIR'을(를) 가리키도록 설정되었습니다."
    else
        echo "오류: 원본 폴더 '$SOURCE_DIR'가 존재하지 않아 링크를 생성할 수 없습니다."
        return 1
    fi
}

replace_with_link "/workspace/ComfyUI/models/checkpoints" "/workspace/ComfyUI/models/unet"

# ============================================================
# DO NOT EDIT BELOW (커뮤니티 고수의 무적 엔진)
# ============================================================

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_WORKSPACE="/workspace/ComfyUI"
INTERNAL_COMFY="/opt/workspace-internal/ComfyUI"

PYTHON_BIN="${PYTHON_BIN:-/venv/main/bin/python}"
PIP_BIN="${PIP_BIN:-/venv/main/bin/pip}"
APT_INSTALL="${APT_INSTALL:-apt-get install -y --no-install-recommends}"

NODE_REQ_FAILS=()
MODEL_DL_FAILS=()
FAIL_ON_MODEL_DL="${FAIL_ON_MODEL_DL:-0}"

get_hf_token() {
  if [[ -n "${HF_TOKEN:-}" ]]; then
    echo "$HF_TOKEN"
    return 0
  fi
  echo ""
}

normalize_comfy_paths() {
  if [[ -d "$INTERNAL_COMFY" && -f "$INTERNAL_COMFY/main.py" ]]; then
    ln -sfn "$INTERNAL_COMFY" "$COMFY_WORKSPACE"
    log "Linked $COMFY_WORKSPACE -> $INTERNAL_COMFY"
  fi
}

pip_install() {
  if [[ -x "$PIP_BIN" ]]; then
    "$PIP_BIN" install --no-cache-dir "$@"
    return 0
  fi
  pip install --no-cache-dir "$@"
}

provisioning_enable_hf_transfer() {
  log "Enabling hf_transfer (best-effort)..."
  set +e
  pip_install -q hf_transfer huggingface_hub
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log "hf_transfer install failed (continuing with fallback)."
  else
    export HF_HUB_ENABLE_HF_TRANSFER=1
  fi
}

provisioning_hf_transfer_download() {
  local dir="$1"
  local url="$2"

  if [[ ! "$url" =~ ^https://huggingface\.co/ ]] || [[ "$url" != *"/resolve/"* ]]; then
    return 1
  fi

  local clean="${url%%\?*}"
  local rest="${clean#https://huggingface.co/}"
  local repo_id="${rest%%/resolve/*}"
  local after="${rest#${repo_id}/resolve/}"
  local rev="${after%%/*}"
  local file_path="${after#${rev}/}"

  mkdir -p "$dir"
  log "HF Python API attempt: repo=$repo_id rev=$rev file=$file_path -> $dir"

  set +e
  "$PYTHON_BIN" - <<'PY' "$repo_id" "$rev" "$file_path" "$dir"
import os, sys, shutil
repo_id, rev, file_path, out_dir = sys.argv[1:5]
token = os.environ.get("HF_TOKEN") or None

try:
    from huggingface_hub import hf_hub_download
    local_path = hf_hub_download(repo_id=repo_id, filename=file_path, revision=rev, token=token, cache_dir="/workspace/.hf_cache")
    os.makedirs(out_dir, exist_ok=True)
    dst = os.path.join(out_dir, os.path.basename(file_path))
    shutil.copy2(local_path, dst)
    print(f"[provision] HF Python DL OK -> {dst}")
    sys.exit(0)
except Exception as e:
    print("[provision] HF Python DL failed:", repr(e))
    sys.exit(1)
PY
  local rc=$?
  set -e
  [[ $rc -eq 0 ]] && return 0 || return 1
}

provisioning_download_to_dir() {
  local dir="$1"
  local url="$2"
  mkdir -p "$dir"

  local final_url="$url"
  local auth_header=""
  local hf_token="$(get_hf_token)"

  if [[ -n "$hf_token" ]] && [[ "$url" =~ huggingface\.co ]]; then
    auth_header="Authorization: Bearer ${hf_token}"
  fi

  if [[ -n "${CIVITAI_API_KEY:-}" ]] && [[ "$url" =~ civitai\.com ]]; then
    if [[ "$url" == *"?"* ]]; then
      final_url="${url}&token=${CIVITAI_API_KEY}"
    else
      final_url="${url}?token=${CIVITAI_API_KEY}"
    fi
  fi

  local name="${url%%\?*}"
  name="${name##*/}"

  log "🔽 다운로드 시작: $name"
  log "📂 저장 위치: $dir"

  if [[ "$url" =~ huggingface\.co ]]; then
    if provisioning_hf_transfer_download "$dir" "$final_url"; then
      log "✅ 다운로드 완료 (HF Transfer): $name"
      return 0
    fi
  fi

  set +e
  if command -v aria2c >/dev/null 2>&1; then
    # aria2c: 로그 도배 방지를 위해 5초마다 진행률 요약 출력 (--summary-interval=5)
    local aria2_opts=("-x" "16" "-s" "16" "-k" "1M" "--summary-interval=5" "--console-log-level=notice")
    if [[ -n "$auth_header" ]]; then
      aria2c "${aria2_opts[@]}" --header="$auth_header" -o "$name" -d "$dir" "$final_url"
    else
      aria2c "${aria2_opts[@]}" -o "$name" -d "$dir" "$final_url"
    fi
    rc=$?
  elif command -v wget >/dev/null 2>&1; then
    # wget: 로그 파일이 깨지지 않게 줄바꿈(noscroll)으로 진행률 깔끔하게 출력
    if [[ -n "$auth_header" ]]; then
      wget --header="$auth_header" --show-progress --progress=bar:force:noscroll -O "$dir/$name" "$final_url"
    else
      wget --show-progress --progress=bar:force:noscroll -O "$dir/$name" "$final_url"
    fi
    rc=$?
  else
    # curl: 깔끔한 프로그레스 바(-#) 출력
    if [[ -n "$auth_header" ]]; then
      curl -fL -# -H "$auth_header" -o "$dir/$name" "$final_url"
    else
      curl -fL -# -o "$dir/$name" "$final_url"
    fi
    rc=$?
  fi
  set -e

  if [[ $rc -eq 0 ]]; then
    log "✅ 다운로드 완료: $name"
  else
    log "❌ 다운로드 실패 (에러 코드: $rc): $name"
  fi

  return $rc
}

print_summary() {
  if [[ ${#NODE_REQ_FAILS[@]} -gt 0 ]]; then
    log "---- Node requirements failures ----"
    for x in "${NODE_REQ_FAILS[@]}"; do log "  - $x"; done
  fi
  if [[ ${#MODEL_DL_FAILS[@]} -gt 0 ]]; then
    log "---- Model download failures ----"
    for x in "${MODEL_DL_FAILS[@]}"; do log "  - $x"; done
  fi
}

# ============================================================
# 커스텀 노드 설치 함수 (새로 추가)
# ============================================================
provisioning_install_custom_nodes() {
  local custom_nodes_dir="${COMFY_WORKSPACE}/custom_nodes"
  mkdir -p "$custom_nodes_dir"

  # NODES 배열에 값이 없으면 스킵
  if [[ ${#NODES[@]} -eq 0 ]]; then
    log "ℹ️ 설치할 커스텀 노드가 없습니다."
    return 0
  fi

  log "📦 커스텀 노드 클론 및 의존성 설치를 시작합니다..."
  
  for repo_url in "${NODES[@]}"; do
    # URL에서 저장소 이름만 추출 (예: https://.../ComfyUI-Chibi-Nodes.git -> ComfyUI-Chibi-Nodes)
    local repo_name
    repo_name=$(basename -s .git "$repo_url")
    local target_dir="$custom_nodes_dir/$repo_name"

    # 이미 폴더가 존재하면 스킵
    if [[ -d "$target_dir" ]]; then
      log "⏩ 이미 존재함 (스킵): $repo_name"
      continue
    fi

    log "⬇️ 클론 중: $repo_name"
    # --depth 1 옵션으로 최신 커밋만 빠르게 가져옵니다.
    if git clone -q --depth=1 "$repo_url" "$target_dir"; then
      # requirements.txt 파일이 존재하면 파이썬 패키지 설치
      if [[ -f "$target_dir/requirements.txt" ]]; then
        log "⚙️ 의존성 설치 중: $repo_name/requirements.txt"
        if ! pip_install -r "$target_dir/requirements.txt"; then
          log "❌ 의존성 설치 실패: $repo_name"
          NODE_REQ_FAILS+=("$repo_name")
        fi
      fi
    else
      log "❌ Git 클론 실패: $repo_url"
      NODE_REQ_FAILS+=("$repo_url")
    fi
  done
}

# ============================================================
# 기존 메인 실행 함수 수정
# ============================================================
provisioning_start() {
  # normalize_comfy_paths

  # 1. 커스텀 노드 설치 실행 (추가된 부분)
  provisioning_install_custom_nodes

  # 2. n8n에서 받아온 모델들을 폴더에 맞춰 다운로드 (기존 로직)
  if [ -n "$MY_WGET_MODELS" ] && [ "$MY_WGET_MODELS" != "null" ]; then
      IFS=';' read -ra MODEL_ARRAY <<< "$MY_WGET_MODELS"
      for item in "${MODEL_ARRAY[@]}"; do
          [[ -z "${item// }" ]] && continue
          local url="${item%%|*}"
          local output_path="${item##*|}"
          # n8n에서 보낸 전체 경로(/workspace/.../파일명)에서 폴더 경로만 추출
          local dir_path=$(dirname "$output_path") 
          
          if ! provisioning_download_to_dir "$dir_path" "$url"; then
               log "MODEL DOWNLOAD FAILED: $url"
               MODEL_DL_FAILS+=("$url")
          fi
      done
  fi

  # 실패한 내역 출력
  print_summary
  log "🎉 완벽한 프로비저닝 완료!"
}

# 스크립트 실행
provisioning_start