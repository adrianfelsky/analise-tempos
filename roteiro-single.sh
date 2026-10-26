#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Uso: roteiro-single.sh video.mp4" >&2; exit 2; }
INPUT="$1"; [[ -f "$INPUT" ]] || { echo "Arquivo nao encontrado: $INPUT" >&2; exit 2; }
for c in python ffmpeg ffprobe powershell.exe; do command -v "$c" >/dev/null || { echo "$c nao encontrado." >&2; exit 2; }; done
[[ -n "${GEMINI_API_KEY:-}" ]] || { echo "Defina GEMINI_API_KEY antes de executar." >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABS_INPUT="$(cd "$(dirname "$INPUT")" && pwd -W)/$(basename "$INPUT")"
BASE="$(basename "$INPUT")"; STEM="${BASE%.*}"
WORK_UNIX="$(cd "$(dirname "$INPUT")" && pwd)/.${STEM}_analise_tmp"
WORK_WIN="$(cygpath -w "$WORK_UNIX")"
OUT_UNIX="$(cd "$(dirname "$INPUT")" && pwd)/${STEM}_analise.csv"
mkdir -p "$WORK_UNIX"
cleanup(){ [[ "${KEEP_TEMP:-0}" == 1 ]] || rm -rf "$WORK_UNIX"; }
trap cleanup EXIT
MANIFEST_WIN=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$SCRIPT_DIR/cortar-em-400mb-windows.ps1")" "$ABS_INPUT" "$WORK_WIN" | tr -d '\r' | tail -n 1)
MANIFEST_UNIX="$(cygpath -u "$MANIFEST_WIN")"
python "$SCRIPT_DIR/analisar_video_gemini.py" "$MANIFEST_UNIX" "$OUT_UNIX" "${GEMINI_MODEL:-gemini-3.8-flash}"
echo "Criado: $OUT_UNIX"
