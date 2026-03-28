$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "lib\pinchflat_web"

$patterns = @(
  "text-(red|green|blue|yellow|orange)-",
  "bg-(red|green|blue|yellow|orange)-",
  "border-(red|green|blue|yellow|orange)-",
  "zinc-"
)

$files = Get-ChildItem -Path $target -Recurse -Include *.ex,*.heex
$matches = @()

foreach ($file in $files) {
  foreach ($pattern in $patterns) {
    $result = Select-String -Path $file.FullName -Pattern $pattern
    if ($result) {
      $matches += $result
    }
  }
}

if ($matches.Count -gt 0) {
  Write-Host "UI theme check failed. Found hardcoded palette classes in lib/pinchflat_web:" -ForegroundColor Red
  $matches | ForEach-Object {
    Write-Host "$($_.Path):$($_.LineNumber): $($_.Line.Trim())"
  }
  exit 1
}

Write-Host "UI theme check passed." -ForegroundColor Green
