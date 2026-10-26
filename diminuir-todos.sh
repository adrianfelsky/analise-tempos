#!/usr/bin/env bash

set -uo pipefail

# Quantos videos processar ao mesmo tempo.
MAX_JOBS="${MAX_JOBS:-2}"

# Qualidade da conversao.
# Menor CRF = melhor qualidade e arquivo maior.
CRF="${CRF:-27}"

# Velocidade de codificacao.
PRESET="${PRESET:-veryfast}"

# Limites.
LIMIT_BYTES=$((400 * 1024 * 1024))
TARGET_BYTES=$((380 * 1024 * 1024))


# ============================================================
# VALIDACOES
# ============================================================

if ! [[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERRO: MAX_JOBS deve ser um numero inteiro >= 1."
    exit 2
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERRO: ffmpeg nao encontrado no PATH."
    exit 2
fi

if ! command -v ffprobe >/dev/null 2>&1; then
    echo "ERRO: ffprobe nao encontrado no PATH."
    exit 2
fi


# ============================================================
# ENCONTRAR VIDEOS
# ============================================================

VIDEOS=()

while IFS= read -r -d '' arquivo
do
    VIDEOS+=("$arquivo")
done < <(
    find . \
        -maxdepth 1 \
        -type f \
        -iname '*.mp4' \
        ! -iname '*-pt[0-9][0-9][0-9].mp4' \
        ! -name '.*-convertendo-*' \
        -print0 |
        sort -z
)


if [[ ${#VIDEOS[@]} -eq 0 ]]; then
    echo "Nenhum arquivo MP4 encontrado."
    exit 0
fi


# ============================================================
# PROCESSAR UM VIDEO
# ============================================================

processar_video() {

    local input="$1"

    local dir
    local base
    local stem
    local convertido

    local tamanho
    local duracao
    local bps
    local segmento
    local pattern

    local partes
    local overs
    local tentativa
    local parte


    dir="$(dirname "$input")"
    base="$(basename "$input")"
    stem="${base%.*}"

    convertido="$dir/.${stem}-convertendo-720p-$$-$RANDOM.mp4"


    echo
    echo "=============================================="
    echo "[CONVERTENDO] $base"
    echo "Resolucao: 1280x720"
    echo "Audio: removido"
    echo "CRF: $CRF"
    echo "=============================================="


    # ========================================================
    # PRIMEIRO: CONVERTER PARA 720p
    # ========================================================

    if ! ffmpeg \
        -hide_banner \
        -loglevel error \
        -nostdin \
        -y \
        -i "$input" \
        -map 0:v:0 \
        -vf "scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1" \
        -c:v libx264 \
        -preset "$PRESET" \
        -crf "$CRF" \
        -pix_fmt yuv420p \
        -an \
        -movflags +faststart \
        "$convertido"
    then

        rm -f "$convertido"

        echo "[ERRO] $base: falha na conversao."

        return 1

    fi


    tamanho="$(
        wc -c < "$convertido" |
        tr -d ' '
    )"


    # ========================================================
    # SE FICOU COM ATE 400 MiB
    # ========================================================

    if (( tamanho <= LIMIT_BYTES )); then

        if mv -f "$convertido" "$input"; then

            echo
            echo "[OK] $base"
            echo "Resolucao: 1280x720"
            echo "Tamanho: $((tamanho / 1024 / 1024)) MiB"
            echo "O original foi substituido pelo video 720p."
            echo

            return 0

        fi


        rm -f "$convertido"

        echo "[ERRO] $base: nao foi possivel substituir o original."

        return 1

    fi


    # ========================================================
    # SE PASSOU DE 400 MiB
    # ========================================================

    echo
    echo "[CORTANDO] $base"
    echo "O video 720p ficou com $((tamanho / 1024 / 1024)) MiB."
    echo "Ele sera dividido em partes de ate 400 MiB."


    duracao="$(
        ffprobe \
            -v error \
            -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 \
            "$convertido" |
        tr -d '\r'
    )"


    if [[ -z "$duracao" ]]; then

        rm -f "$convertido"

        echo "[ERRO] $base: nao foi possivel obter a duracao."

        return 1

    fi


    # Bitrate medio real do video convertido.
    bps="$(
        awk \
            -v bytes="$tamanho" \
            -v seconds="$duracao" \
            'BEGIN {
                printf "%.0f", (bytes * 8) / seconds
            }'
    )"


    # Duracao inicial estimada para partes de aproximadamente 380 MiB.
    segmento="$(
        awk \
            -v target="$TARGET_BYTES" \
            -v rate="$bps" \
            'BEGIN {
                segundos = int((target * 8) / rate)

                if (segundos < 30) {
                    segundos = 30
                }

                print segundos
            }'
    )"


    pattern="$dir/${stem}-pt%03d.mp4"


    # Remove partes antigas com o mesmo nome.
    rm -f \
        "$dir/${stem}-pt"[0-9][0-9][0-9].mp4 \
        2>/dev/null || true


    # ========================================================
    # DIVIDIR E VALIDAR AS PARTES
    # ========================================================

    for tentativa in 1 2 3 4 5
    do

        rm -f \
            "$dir/${stem}-pt"[0-9][0-9][0-9].mp4 \
            2>/dev/null || true


        echo
        echo "[DIVIDINDO] $base"
        echo "Tentativa: $tentativa/5"
        echo "Duracao aproximada por parte: ${segmento}s"


        if ! ffmpeg \
            -hide_banner \
            -loglevel error \
            -nostdin \
            -y \
            -i "$convertido" \
            -map 0:v:0 \
            -c:v libx264 \
            -preset "$PRESET" \
            -crf "$CRF" \
            -pix_fmt yuv420p \
            -an \
            -force_key_frames "expr:gte(t,n_forced*$segmento)" \
            -f segment \
            -segment_time "$segmento" \
            -reset_timestamps 1 \
            -segment_format mp4 \
            "$pattern"
        then

            rm -f "$convertido"

            echo "[ERRO] $base: falha ao dividir o video."

            return 1

        fi


        partes=(
            "$dir/${stem}-pt"[0-9][0-9][0-9].mp4
        )


        overs=0


        for parte in "${partes[@]}"
        do

            if [[ ! -f "$parte" ]]; then
                continue
            fi


            if (( $(wc -c < "$parte") > LIMIT_BYTES )); then

                overs=1

                break

            fi

        done


        # ====================================================
        # TODAS AS PARTES ESTAO ABAIXO DE 400 MiB
        # ====================================================

        if (( overs == 0 )); then

            rm -f "$convertido"

            # O original so e removido depois que todas as
            # partes forem geradas e validadas.
            rm -f "$input"


            echo
            echo "[OK] $base"
            echo "Dividido em ${#partes[@]} parte(s)."
            echo "Todas as partes ficaram com ate 400 MiB."
            echo "O arquivo original foi removido."
            echo

            return 0

        fi


        # Se alguma parte passou de 400 MiB,
        # reduz a duracao em 10% e tenta novamente.
        segmento=$((segmento * 90 / 100))


        if (( segmento < 30 )); then
            break
        fi

    done


    # ========================================================
    # FALHA NA DIVISAO
    # ========================================================

    rm -f "$convertido"

    rm -f \
        "$dir/${stem}-pt"[0-9][0-9][0-9].mp4 \
        2>/dev/null || true


    echo
    echo "[ERRO] $base"
    echo "Nao foi possivel gerar partes de ate 400 MiB."
    echo "O arquivo original foi preservado."
    echo

    return 1
}


# ============================================================
# CONCORRENCIA
# ============================================================

running=0
success=0
failed=0

pids=()

declare -A PID_VIDEO


reap_one() {

    local pid
    local video

    pid="${pids[0]}"
    video="${PID_VIDEO[$pid]}"

    pids=("${pids[@]:1}")


    if wait "$pid"; then

        ((success += 1))

    else

        ((failed += 1))

        echo "[FALHOU] $video"

    fi


    unset 'PID_VIDEO[$pid]'

    ((running -= 1))
}


# ============================================================
# EXECUCAO
# ============================================================

echo
echo "=============================================="
echo " CONVERTER PARA 720p E CORTAR ACIMA DE 400 MiB"
echo "=============================================="
echo
echo "Videos encontrados : ${#VIDEOS[@]}"
echo "Concorrencia       : $MAX_JOBS"
echo "CRF                : $CRF"
echo "Preset             : $PRESET"
echo


for video in "${VIDEOS[@]}"
do

    while (( running >= MAX_JOBS ))
    do
        reap_one
    done


    processar_video "$video" &

    pid=$!

    pids+=("$pid")

    PID_VIDEO[$pid]="$video"

    ((running += 1))

done


while (( running > 0 ))
do
    reap_one
done


echo
echo "=============================================="
echo " FINALIZADO"
echo "=============================================="
echo
echo "OK     : $success"
echo "Falhas : $failed"
echo "Total  : ${#VIDEOS[@]}"
echo


if (( failed == 0 )); then
    exit 0
else
    exit 1
fi