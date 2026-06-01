param(
    [string]$Runtime = "win-x64",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "src\SafeEject.Launcher\SafeEject.Launcher.csproj"
$output = Join-Path $root "dist"

dotnet publish $project `
    -c $Configuration `
    -r $Runtime `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:EnableCompressionInSingleFile=true `
    -o $output

Write-Host "Built: $output\SafeEject.exe" -ForegroundColor Green
