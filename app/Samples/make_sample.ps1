# Generates the synthetic clip that the end-to-end test seeds into the simulator's Photos library.
# Smooth moving gradients are easy to compress, so the test exercises the success path. H.264 at a
# padded constant 8 Mbps makes the file large enough to be worth optimizing, and there is an audio track.
# Needs an ffmpeg with libx264. Pass -Ffmpeg with a full path if ffmpeg is not on PATH.
param([string]$Ffmpeg = "ffmpeg")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

& $Ffmpeg -y -v error `
    -f lavfi -i "gradients=size=1280x720:rate=30:speed=0.02" `
    -f lavfi -i "sine=frequency=440:sample_rate=44100" `
    -t 5 -c:v libx264 -preset medium -b:v 8M -minrate 8M -maxrate 8M -bufsize 8M `
    -x264-params "nal-hrd=cbr:force-cfr=1" -pix_fmt yuv420p `
    -c:a aac -b:a 96k -shortest -movflags +faststart e2e-sample.mp4

Get-ChildItem e2e-sample.mp4 | Select-Object Name, Length
