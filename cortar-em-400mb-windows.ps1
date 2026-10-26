param(
  [Parameter(Mandatory=$true,Position=0)][string]$InputFile,
  [Parameter(Mandatory=$true,Position=1)][string]$OutputDir
)
$ErrorActionPreference='Stop'
$LimitBytes=400MB
$TargetBytes=380MB
$Crf=if($env:CRF){$env:CRF}else{'27'}
foreach($cmd in @('ffmpeg','ffprobe')){if(-not(Get-Command $cmd -ErrorAction SilentlyContinue)){throw "$cmd nao encontrado no PATH."}}
$InputFile=(Resolve-Path -LiteralPath $InputFile).Path
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir=(Resolve-Path -LiteralPath $OutputDir).Path
$Stem=[IO.Path]::GetFileNameWithoutExtension($InputFile)
$Converted=Join-Path $OutputDir "$Stem-720p.mp4"
$Audio=& ffprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 $InputFile
$args=@('-hide_banner','-nostdin','-y','-i',$InputFile,'-map','0:v:0','-vf','scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1','-c:v','libx264','-preset','veryfast','-crf',$Crf,'-pix_fmt','yuv420p','-movflags','+faststart')
if($Audio){$args+=@('-map','0:a:0','-c:a','aac','-b:a','96k')}else{$args+=@('-an')}
$args+=$Converted
& ffmpeg @args
if($LASTEXITCODE-ne 0){throw "Falha ao converter para 720p."}
$results=@()
if((Get-Item $Converted).Length -le $LimitBytes){$results+=$Converted}
else{
  $duration=[double]::Parse((& ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $Converted).Trim(),[Globalization.CultureInfo]::InvariantCulture)
  $bps=((Get-Item $Converted).Length*8)/$duration
  $segment=[math]::Max(30,[math]::Floor(($TargetBytes*8)/$bps))
  Remove-Item $Converted -Force
  while($true){
    Get-ChildItem $OutputDir -Filter "$Stem-pt*.mp4" -ErrorAction SilentlyContinue | Remove-Item -Force
    $pattern=Join-Path $OutputDir "$Stem-pt%03d.mp4"
    & ffmpeg -hide_banner -nostdin -y -i $InputFile -map 0:v:0 -vf 'scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1' -c:v libx264 -preset veryfast -crf $Crf -pix_fmt yuv420p -force_key_frames "expr:gte(t,n_forced*$segment)" -f segment -segment_time $segment -reset_timestamps 1 -segment_format mp4 $pattern
    if($LASTEXITCODE-ne 0){throw 'Falha ao dividir o video.'}
    $parts=@(Get-ChildItem $OutputDir -Filter "$Stem-pt*.mp4" | Sort-Object Name)
    $overs=@($parts|Where-Object{$_.Length-gt $LimitBytes})
    if($overs.Count-eq 0){$results+=$parts.FullName;break}
    $segment=[math]::Floor($segment*0.90)
    if($segment-lt 30){throw 'Nao foi possivel manter as partes abaixo de 400 MB.'}
  }
}
$manifest=Join-Path $OutputDir 'partes.txt'
$results | Set-Content -LiteralPath $manifest -Encoding UTF8
Write-Output $manifest
