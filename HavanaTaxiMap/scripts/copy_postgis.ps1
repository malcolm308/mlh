$postgisBin = "$env:TEMP\postgis\extracted\postgis-bundle-pg18-3.6.2x64\bin"
$pgBin = "C:\Program Files\PostgreSQL\18\bin"

$files = Get-ChildItem $postgisBin -File
Write-Host "Copying $($files.Count) files to $pgBin"

foreach ($f in $files) {
    $dest = Join-Path $pgBin $f.Name
    Copy-Item $f.FullName $dest -Force
    Write-Host "  Copied: $($f.Name)"
}

Write-Host "Done!"
Get-ChildItem $pgBin -File | Measure-Object | Select-Object -ExpandProperty Count | ForEach-Object { Write-Host "Total files in bin: $_" }
