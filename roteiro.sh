#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
Uso:
  ./roteiro.sh video1.mp4 video2.mp4 ...
  ./roteiro.sh *.mp4
  ./roteiro.sh pasta_com_videos/*.mp4

Variaveis opcionais:
  MAX_JOBS=2       numero maximo de videos processados simultaneamente
  GEMINI_MODEL=... modelo Gemini usado pelo analisador
  CRF=27           qualidade da conversao 720p
  KEEP_TEMP=1      preserva arquivos temporarios
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGLE="$SCRIPT_DIR/roteiro-single.sh"
[[ -x "$SINGLE" ]] || { echo "Erro: roteiro-single.sh nao encontrado/executavel." >&2; exit 2; }

MAX_JOBS="${MAX_JOBS:-2}"
[[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "MAX_JOBS deve ser inteiro >= 1." >&2; exit 2; }

VIDEOS=()
for f in "$@"; do
  if [[ -f "$f" ]]; then
    VIDEOS+=("$f")
  else
    echo "AVISO: ignorando arquivo inexistente: $f" >&2
  fi
done
[[ ${#VIDEOS[@]} -gt 0 ]] || { echo "Nenhum video valido recebido." >&2; exit 2; }

BATCH_ID="$(date +%Y%m%d-%H%M%S)-$$"
LOG_DIR="$SCRIPT_DIR/.roteiro_logs_$BATCH_ID"
mkdir -p "$LOG_DIR"

running=0
success=0
failed=0
pids=()
declare -A PID_VIDEO PID_LOG

start_job() {
  local video="$1" safe log
  safe="$(basename "$video")"
  safe="${safe//[^A-Za-z0-9._-]/_}"
  log="$LOG_DIR/${safe}.log"
  echo "[INICIO] $video"
  ( "$SINGLE" "$video" >"$log" 2>&1 ) &
  local pid=$!
  pids+=("$pid")
  PID_VIDEO[$pid]="$video"
  PID_LOG[$pid]="$log"
  ((running+=1))
}

reap_one() {
  local pid video log rc
  pid="${pids[0]}"
  pids=("${pids[@]:1}")
  video="${PID_VIDEO[$pid]}"; log="${PID_LOG[$pid]}"
  if wait "$pid"; then
    echo "[OK]     $video"
    ((success+=1))
  else
    rc=$?
    echo "[ERRO]   $video (codigo $rc) | log: $log" >&2
    ((failed+=1))
  fi
  unset 'PID_VIDEO[$pid]' 'PID_LOG[$pid]'
  ((running-=1))
}

for video in "${VIDEOS[@]}"; do
  while (( running >= MAX_JOBS )); do reap_one; done
  start_job "$video"
done
while (( running > 0 )); do reap_one; done

echo
echo "Processamento concluido. OK=$success ERROS=$failed TOTAL=${#VIDEOS[@]}"
if (( failed == 0 )); then
  rm -rf "$LOG_DIR"
  exit 0
else
  echo "Logs das falhas: $LOG_DIR" >&2
  exit 1
fi
