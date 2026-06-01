# SafeEject Installer
# Masaustu ve/veya Start Menu kisayolu olusturur

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$exePath = Join-Path $PSScriptRoot "dist\SafeEject.exe"
$scriptPath = Join-Path $PSScriptRoot "SafeEject.ps1"

if (-not (Test-Path $exePath) -and -not (Test-Path $scriptPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "SafeEject.exe veya SafeEject.ps1 bu klasorde bulunamadi.",
        "SafeEject Installer", "OK", "Error") | Out-Null
    exit 1
}

# Secim formu
$form = New-Object System.Windows.Forms.Form
$form.Text = "SafeEject - Kurulum"
$form.Size = New-Object System.Drawing.Size(380, 230)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = "Kisayol nereye eklensin?"
$lbl.Location = New-Object System.Drawing.Point(16, 16)
$lbl.Size = New-Object System.Drawing.Size(340, 20)
$lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lbl)

$chkDesktop = New-Object System.Windows.Forms.CheckBox
$chkDesktop.Text = "Masaustu"
$chkDesktop.Location = New-Object System.Drawing.Point(24, 50)
$chkDesktop.Size = New-Object System.Drawing.Size(320, 24)
$chkDesktop.Checked = $true
$form.Controls.Add($chkDesktop)

$chkStart = New-Object System.Windows.Forms.CheckBox
$chkStart.Text = "Baslat Menusu (Tum Uygulamalar)"
$chkStart.Location = New-Object System.Drawing.Point(24, 80)
$chkStart.Size = New-Object System.Drawing.Size(320, 24)
$chkStart.Checked = $true
$form.Controls.Add($chkStart)

$btn = New-Object System.Windows.Forms.Button
$btn.Text = "Kur"
$btn.Location = New-Object System.Drawing.Point(16, 140)
$btn.Size = New-Object System.Drawing.Size(340, 36)
$btn.DialogResult = "OK"
$btn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($btn)
$form.AcceptButton = $btn

if ($form.ShowDialog() -ne "OK") { exit }

$wsh = New-Object -ComObject WScript.Shell
if (Test-Path $exePath) {
    $target = $exePath
    $args   = ""
} else {
    $target = "powershell.exe"
    $args   = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
}
$icon   = "imageres.dll,53"
$desc   = "USB diskleri guvenle cikar"
$created = @()
$failed  = @()

function New-Shortcut($path) {
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $lnk = $wsh.CreateShortcut($path)
        $lnk.TargetPath       = $target
        $lnk.Arguments        = $args
        $lnk.IconLocation     = $icon
        $lnk.Description      = $desc
        $lnk.WorkingDirectory = $PSScriptRoot
        $lnk.Save()
        $script:created += $path
    } catch {
        $script:failed += "$path`n  $($_.Exception.Message)"
    }
}

if ($chkDesktop.Checked) {
    New-Shortcut ([Environment]::GetFolderPath("Desktop") + "\SafeEject.lnk")
}

if ($chkStart.Checked) {
    $startDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    New-Shortcut "$startDir\SafeEject.lnk"
}

$msg = ""
if ($created.Count -gt 0) { $msg += "Olusturulan kisayollar:`n" + ($created -join "`n") }
if ($failed.Count -gt 0)  { $msg += "`n`nBasarisiz:`n" + ($failed -join "`n") }

[System.Windows.Forms.MessageBox]::Show($msg, "SafeEject - Kurulum Tamamlandi", "OK", "Information") | Out-Null
