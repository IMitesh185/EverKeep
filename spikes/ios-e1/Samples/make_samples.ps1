# Generates the synthetic media that spike E1 loads into the simulator.
# Needs ffmpeg with libx265 on PATH. Run it from anywhere, then commit sample.mov and sample.jpg.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

ffmpeg -y -v error -f lavfi -i "testsrc2=size=1920x1080:rate=30" -t 5 -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p sample.mov
ffmpeg -y -v error -f lavfi -i "testsrc2=size=1920x1080" -frames:v 1 sample.jpg

Get-ChildItem sample.* | Select-Object Name, Length
