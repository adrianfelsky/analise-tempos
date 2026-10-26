import csv, os, re, sys, time
from pathlib import Path
from google import genai
import random
from google.genai import errors

SYSTEM = r'''Você é analista industrial de tempos e movimentos. Analise integralmente o vídeo, cubra toda a linha temporal e registre uma atividade por linha. Não invente nem presuma ações, ferramentas, materiais, intenções ou causas. Use "Não visível" quando a ação estiver oculta e "Não identificável" quando estiver visível mas não puder ser determinada.
Classifique: UT quando transforma, monta, conecta, fixa ou ajusta diretamente o produto; CNVA quando não transforma, mas é necessária e normalmente cíclica; FNVA quando é apoio necessário ocasional ou frequencial; TBD quando não houver evidência suficiente, houver espera/paralisação de causa desconhecida ou a ação não puder ser classificada. DT não é classificação.
Responda somente CSV, sem Markdown, explicações, duração ou TOTAL. Cabeçalho exato: Nº,Início,Fim,Descrição,Classificação. Use mm:ss ou hh:mm:ss, ordem cronológica, sem sobreposição para o mesmo operador.'''
PROMPT='''Analise integralmente esta parte do vídeo. O timestamp 00:00 corresponde ao início desta parte. Observe movimentos curtos, valide continuidade e retorne somente o CSV exigido.'''

def sec(s):
    p=[int(x) for x in s.strip().split(':')]
    return p[-1]+60*p[-2]+(3600*p[-3] if len(p)==3 else 0)
def stamp(n):
    n=max(0,int(round(n))); h,n=divmod(n,3600); m,s=divmod(n,60)
    return f'{h:02d}:{m:02d}:{s:02d}' if h else f'{m:02d}:{s:02d}'
def clean(text):
    text=text.strip().replace('```csv','').replace('```','').strip()
    lines=[x for x in text.splitlines() if x.strip()]
    for i,x in enumerate(lines):
        if x.lstrip('\ufeff').lower().startswith(('nº,','n°,','no,','numero,')):
            return '\n'.join(lines[i:])
    raise ValueError('Resposta sem cabecalho CSV reconhecivel')

def main():
    if len(sys.argv)!=4: raise SystemExit('uso: analisar_video_gemini.py partes.txt saida.csv modelo')
    manifest = Path(sys.argv[1])
    out = Path(sys.argv[2])
    model = sys.argv[3]
    key=os.getenv('GEMINI_API_KEY')
    if not key: raise SystemExit('GEMINI_API_KEY nao definida')
    client=genai.Client(api_key=key)
    videos=[Path(x.strip().lstrip('\ufeff')) for x in manifest.read_text(encoding='utf-8-sig').splitlines() if x.strip()]
    final=[]; offset=0
    for idx,video in enumerate(videos,1):
        print(
            f"[{idx}/{len(videos)}] {video.name} | Iniciando upload...",
            file=sys.stderr,
            flush=True
        )

        upload_inicio = time.time()

        try:
            f = client.files.upload(file=str(video))
        except Exception as e:
            print(
                f"[{idx}/{len(videos)}] {video.name} | ERRO NO UPLOAD: {e}",
                file=sys.stderr,
                flush=True
            )
            raise

        print(
            f"[{idx}/{len(videos)}] {video.name} | Upload concluído "
            f"({time.time() - upload_inicio:.1f}s)",
            file=sys.stderr,
            flush=True
        )

        # ============================================================
        # Aguardar processamento do vídeo pelo Gemini
        # ============================================================

        processamento_inicio = time.time()
        ultima_mensagem = 0
        TIMEOUT_PROCESSAMENTO = 30 * 60  # 30 minutos

        while True:

            f = client.files.get(name=f.name)

            estado = f.state.name if f.state else "DESCONHECIDO"

            agora = time.time()
            decorrido = agora - processamento_inicio

            # Mostra status aproximadamente a cada 10 segundos
            if agora - ultima_mensagem >= 10:
                print(
                    f"[{idx}/{len(videos)}] {video.name} | "
                    f"Gemini: {estado} | "
                    f"{decorrido:.0f}s",
                    file=sys.stderr,
                    flush=True
                )

                ultima_mensagem = agora

            if estado == "ACTIVE":
                break

            if estado == "FAILED":
                erro = getattr(f, "error", None)

                raise RuntimeError(
                    f"Gemini falhou ao processar {video.name}. "
                    f"Erro: {erro}"
                )

            if decorrido > TIMEOUT_PROCESSAMENTO:

                raise TimeoutError(
                    f"Timeout aguardando processamento de {video.name} "
                    f"após {decorrido:.0f}s."
                )

            time.sleep(5)


        print(
            f"[{idx}/{len(videos)}] {video.name} | "
            f"Vídeo ACTIVE. Iniciando análise...",
            file=sys.stderr,
            flush=True
        )


        # ============================================================
        # Executar análise
        # ============================================================

        analise_inicio = time.time()

        MAX_TENTATIVAS = 6

        for tentativa in range(1, MAX_TENTATIVAS + 1):

            print(
                f"[{idx}/{len(videos)}] {video.name} | "
                f"Iniciando análise | tentativa "
                f"{tentativa}/{MAX_TENTATIVAS}",
                file=sys.stderr,
                flush=True
            )

            analise_inicio = time.time()

            try:

                r = client.models.generate_content(
                    model=model,
                    contents=[f, PROMPT],
                    config={
                        "system_instruction": SYSTEM,
                        "temperature": 0,
                        "max_output_tokens": 65536
                    }
                )

                print(
                    f"[{idx}/{len(videos)}] {video.name} | "
                    f"Análise concluída "
                    f"({time.time() - analise_inicio:.1f}s)",
                    file=sys.stderr,
                    flush=True
                )

                # Deu certo. Sai do loop de retry.
                break

            except errors.ServerError as e:

                # Captura principalmente erros 5xx do servidor.
                status = getattr(e, "code", None)

                print(
                    f"[{idx}/{len(videos)}] {video.name} | "
                    f"Erro temporário do Gemini: {status or e}",
                    file=sys.stderr,
                    flush=True
                )

                if tentativa >= MAX_TENTATIVAS:
                    print(
                        f"[{idx}/{len(videos)}] {video.name} | "
                        f"ERRO: limite de tentativas atingido.",
                        file=sys.stderr,
                        flush=True
                    )
                    raise

                # Backoff exponencial com jitter:
                # aproximadamente 5, 10, 20, 40, 80... segundos
                espera_base = min(5 * (2 ** (tentativa - 1)), 120)
                espera = espera_base + random.uniform(0, 3)

                print(
                    f"[{idx}/{len(videos)}] {video.name} | "
                    f"Nova tentativa após {espera:.1f}s...",
                    file=sys.stderr,
                    flush=True
                )

                time.sleep(espera)

            except Exception as e:

                # Erros inesperados não ficam sendo repetidos indefinidamente.
                print(
                    f"[{idx}/{len(videos)}] {video.name} | "
                    f"ERRO NÃO RECUPERÁVEL NA ANÁLISE: {e}",
                    file=sys.stderr,
                    flush=True
                )

                raise

        print(
            f"[{idx}/{len(videos)}] {video.name} | "
            f"Análise concluída "
            f"({time.time() - analise_inicio:.1f}s). "
            f"Validando CSV...",
            file=sys.stderr,
            flush=True
        )
        rows=list(csv.reader(clean(r.text).splitlines()))
        if len(rows)<2: raise ValueError(f'Parte {idx} sem atividades')
        for row in rows[1:]:
            if len(row)<5: continue
            final.append([len(final)+1,stamp(sec(row[1])+offset),stamp(sec(row[2])+offset),row[3].strip(),row[4].strip().upper()])
        import subprocess
        d=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',str(video)],text=True).strip())
        offset+=d
        try: client.files.delete(name=f.name)
        except Exception: pass
    out.parent.mkdir(parents=True,exist_ok=True)
    with out.open('w',newline='',encoding='utf-8-sig') as fh:
        w=csv.writer(fh); w.writerow(['Nº','Início','Fim','Descrição','Classificação']); w.writerows(final)
    print(out)
if __name__=='__main__': main()
