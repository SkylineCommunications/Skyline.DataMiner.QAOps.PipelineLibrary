$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath = Join-Path $PSScriptRoot 'Public'

foreach ($file in Get-ChildItem -Path $privatePath -Filter '*.ps1' -ErrorAction SilentlyContinue) {
    . $file.FullName
}

foreach ($file in Get-ChildItem -Path $publicPath -Filter '*.ps1' -ErrorAction SilentlyContinue) {
    . $file.FullName
}
