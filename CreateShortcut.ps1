# Masaustune kisayol olusturur
$exePath = "$PSScriptRoot\dist\SafeEject.exe"
$scriptPath = "$PSScriptRoot\SafeEject.ps1"
$shortcutPath = [Environment]::GetFolderPath("Desktop") + "\SafeEject.lnk"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)

if (Test-Path $exePath) {
    $shortcut.TargetPath = $exePath
    $shortcut.Arguments = ""
} else {
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
}

$shortcut.IconLocation = "imageres.dll,53"  # USB ikonu
$shortcut.Description = "USB-C SSD Guvenli Cikar"
$shortcut.Save()

Write-Host "Kısayol olusturuldu: $shortcutPath" -ForegroundColor Green
