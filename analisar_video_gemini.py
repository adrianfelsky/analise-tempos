import csv, os, re, sys, time
from pathlib import Path
from google import genai

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
    manifest,out,model=map(Path,sys.argv[1:])
    key=os.getenv('GEMINI_API_KEY')
    if not key: raise SystemExit('GEMINI_API_KEY nao definida')
    client=genai.Client(api_key=key)
    videos=[Path(x.strip().lstrip('\ufeff')) for x in manifest.read_text(encoding='utf-8-sig').splitlines() if x.strip()]
    final=[]; offset=0
    for idx,video in enumerate(videos,1):
        print(f'Enviando parte {idx}/{len(videos)}: {video.name}',file=sys.stderr)
        f=client.files.upload(file=str(video))
        while not f.state or f.state.name=='PROCESSING':
            time.sleep(5); f=client.files.get(name=f.name)
        if f.state.name!='ACTIVE': raise RuntimeError(f'Upload falhou: {f.state.name}')
        r=client.models.generate_content(model=model,contents=[f,PROMPT],config={'system_instruction':SYSTEM,'temperature':0,'max_output_tokens':65536})
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
