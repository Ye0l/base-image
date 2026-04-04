#!/usr/bin/env bash
set -euo pipefail

# 1. logger 패키지 설치 (명령어 실행 전 확실하게 준비)
apt-get update && apt-get install -y bsdutils

LOG_FILE="/workspace/provisioning.log"

# 2. tee 명령어에 프로세스 치환 >(...)을 추가하여 logger로 데이터 전송
exec > >(tee -a "$LOG_FILE" >(logger -n lab.kstr.dev -P 1514 -d -t "vast-ai-comfyui")) 2>&1

# 🌟 무한 대기(Deadlock) 방지용 환경변수 세팅
export PIP_NO_INPUT=1
export GIT_TERMINAL_PROMPT=0
export DEBIAN_FRONTEND=noninteractive

log(){ echo "[provision] $*"; }

# ============================================================
# 환경 변수
# ============================================================
# HF_MODELS_REPO: 다운로드할 HF 리포지토리 (세미콜론 구분, [user]/[repo] 형식)
#   예: HF_MODELS_REPO="myuser/comfyui-models;myuser/extra-loras"
# HF_TOKEN: (선택) 비공개 리포지토리용 HF 토큰

MODELS_DIR="/workspace/models"
COMFY_MODELS="/workspace/ComfyUI/models"

PYTHON_BIN="${PYTHON_BIN:-/venv/main/bin/python}"
PIP_BIN="${PIP_BIN:-/venv/main/bin/pip}"

pip_install() {
  if [[ -x "$PIP_BIN" ]]; then
    "$PIP_BIN" install --no-cache-dir "$@"
    return 0
  fi
  pip install --no-cache-dir "$@"
}

# ============================================================
# 1. hf CLI + hf_transfer 설치
# ============================================================
setup_hf() {
  log "🔧 hf CLI 및 hf_transfer 설치 중..."
  set +e
  pip_install -q hf_transfer huggingface_hub[cli]
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log "⚠️ hf_transfer 설치 실패 (기본 속도로 진행)"
  else
    export HF_HUB_ENABLE_HF_TRANSFER=1
    log "✅ hf_transfer 가속 활성화됨"
  fi

  if [[ -n "${HF_TOKEN:-}" ]]; then
    log "🔑 HF_TOKEN으로 로그인..."
    hf login --token "$HF_TOKEN" 2>/dev/null || true
  fi
}

# ============================================================
# 2. 모델 다운로드 (hf download)
# ============================================================
download_models() {
  if [[ -z "${HF_MODELS_REPO:-}" ]]; then
    log "ℹ️ HF_MODELS_REPO 환경 변수가 없습니다. 모델 다운로드를 건너뜁니다."
    return 0
  fi

  mkdir -p "$MODELS_DIR"

  IFS=';' read -ra REPOS <<< "$HF_MODELS_REPO"
  for repo in "${REPOS[@]}"; do
    repo="$(echo "$repo" | xargs)" # trim whitespace
    [[ -z "$repo" ]] && continue

    log "🔽 HF 다운로드 시작: $repo -> $MODELS_DIR"

    set +e
    hf download "$repo" \
      --local-dir "$MODELS_DIR" \
      --local-dir-use-symlinks False
    local rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
      log "✅ 다운로드 완료: $repo"
    else
      log "❌ 다운로드 실패 (에러 코드: $rc): $repo"
    fi
  done
}

# ============================================================
# 3. 심볼릭 링크 설정 (/workspace/ComfyUI/models -> /workspace/models)
# ============================================================
link_models() {
  log "🔗 모델 디렉토리 심볼릭 링크 설정..."

  if [[ -L "$COMFY_MODELS" ]]; then
    log "알림: '$COMFY_MODELS'는 이미 심볼릭 링크입니다. 기존 링크를 제거합니다."
    rm "$COMFY_MODELS"
  elif [[ -d "$COMFY_MODELS" ]]; then
    log "알림: 기존 폴더 '$COMFY_MODELS'를 삭제합니다."
    rm -rf "$COMFY_MODELS"
  fi

  ln -s "$MODELS_DIR" "$COMFY_MODELS"
  log "✅ 링크 완료: $COMFY_MODELS -> $MODELS_DIR"

  # workflows 심볼릭 링크: /workspace/models/workflows -> ComfyUI 유저 워크플로우 폴더
  local WORKFLOWS_SRC="$MODELS_DIR/workflows"
  local WORKFLOWS_DST="/workspace/ComfyUI/user/default/workflows"

  if [[ -d "$WORKFLOWS_SRC" ]]; then
    log "🔗 워크플로우 디렉토리 심볼릭 링크 설정..."

    if [[ -L "$WORKFLOWS_DST" ]]; then
      rm "$WORKFLOWS_DST"
    elif [[ -d "$WORKFLOWS_DST" ]]; then
      rm -rf "$WORKFLOWS_DST"
    fi

    mkdir -p "$(dirname "$WORKFLOWS_DST")"
    ln -s "$WORKFLOWS_SRC" "$WORKFLOWS_DST"
    log "✅ 링크 완료: $WORKFLOWS_DST -> $WORKFLOWS_SRC"
  else
    log "ℹ️ $WORKFLOWS_SRC 폴더가 없어 워크플로우 링크를 건너뜁니다."
  fi
}

# ============================================================
# 커스텀 노드 설치
# ============================================================
# CUSTOM_NODES 환경 변수: 세미콜론 구분 Git URL 목록
install_custom_nodes() {
  if [[ -z "${CUSTOM_NODES:-}" ]]; then
    log "ℹ️ 설치할 커스텀 노드가 없습니다."
    return 0
  fi

  local custom_nodes_dir="/workspace/ComfyUI/custom_nodes"
  mkdir -p "$custom_nodes_dir"

  log "📦 커스텀 노드 클론 및 의존성 설치를 시작합니다..."

  IFS=';' read -ra NODE_ARRAY <<< "$CUSTOM_NODES"
  for repo_url in "${NODE_ARRAY[@]}"; do
    repo_url="$(echo "$repo_url" | xargs)"
    [[ -z "$repo_url" ]] && continue

    local repo_name
    repo_name=$(basename -s .git "$repo_url")
    local target_dir="$custom_nodes_dir/$repo_name"

    if [[ -d "$target_dir" ]]; then
      log "⏩ 이미 존재함 (스킵): $repo_name"
      continue
    fi

    log "⬇️ 클론 중: $repo_name"
    if git clone -q --depth=1 "$repo_url" "$target_dir"; then
      if [[ -f "$target_dir/requirements.txt" ]]; then
        log "⚙️ 의존성 설치 중: $repo_name/requirements.txt"
        pip_install -r "$target_dir/requirements.txt" || log "❌ 의존성 설치 실패: $repo_name"
      fi
    else
      log "❌ Git 클론 실패: $repo_url"
    fi
  done
}

# ============================================================
# 메인 실행
# ============================================================
main() {
  setup_hf
  download_models
  link_models
  install_custom_nodes
  log "🎉 완벽한 프로비저닝 완료!"
}

main