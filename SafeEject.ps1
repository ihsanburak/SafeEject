Add-Type -AssemblyName System.Windows.Forms

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    try {
        $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Guvenli cikarma icin yonetici izni gerekiyor.`nUAC penceresinde Evet demen lazim.",
            "SafeEject", "OK", "Warning") | Out-Null
    }
    exit
}

$script:SafeEjectVersion = "2026-06-01.11"
$script:LogPath = Join-Path $env:TEMP "SafeEject.log"

function Write-SafeEjectLog {
    param([string]$Message)
    try {
        $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $script:SafeEjectVersion, $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {
    }
}

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class SafeEjectUsbEjector20260601 {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize, IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, int ulFlags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Request_Device_EjectW(uint dnDevInst, out int pVetoType,
        StringBuilder pszVetoName, int ulNameLength, int ulFlags);

    [DllImport("cfgmgr32.dll")]
    static extern int CM_Get_Parent(out uint pdnDevInst, uint dnDevInst, int ulFlags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_IDW(uint dnDevInst, StringBuilder buffer, int bufferLen, int flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Query_And_Remove_SubTreeW(uint dnAncestor, out int pVetoType,
        StringBuilder pszVetoName, int ulNameLength, int ulFlags);

    const uint GENERIC_READ    = 0x80000000;
    const uint GENERIC_WRITE   = 0x40000000;
    const uint FILE_SHARE_READ = 0x00000001;
    const uint FILE_SHARE_WRITE = 0x00000002;
    const uint OPEN_EXISTING   = 3;
    const uint FSCTL_LOCK_VOLUME     = 0x00090018;
    const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

    static void ForceClose(string path) {
        if (String.IsNullOrWhiteSpace(path)) return;

        string normalizedPath = path;
        if (normalizedPath.StartsWith("\\\\?\\Volume{", StringComparison.OrdinalIgnoreCase))
            normalizedPath = normalizedPath.TrimEnd('\\');

        IntPtr handle = CreateFile(normalizedPath,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);

        if (handle == new IntPtr(-1)) return;

        uint br;
        // Lock denenir (basarisiz olsa da devam et)
        DeviceIoControl(handle, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero);
        // Zorla dismount - acik handle'lar gecersiz olur
        DeviceIoControl(handle, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero);
        CloseHandle(handle);
    }

    static string TryRequestEject(uint devInst, string deviceId) {
        StringBuilder veto = new StringBuilder(260);
        int vetoType;
        int result = CM_Request_Device_EjectW(devInst, out vetoType, veto, 260, 0);
        if (result == 0) return "SUCCESS";

        string vetoName = veto.ToString();
        if (String.IsNullOrWhiteSpace(vetoName)) vetoName = "unknown";
        return "FAILED:" + deviceId + "|vetoType=" + vetoType + "|vetoName=" + vetoName;
    }

    public static string RemoveDeviceNode(string pnpDeviceId) {
        uint devInst;
        int locateResult = CM_Locate_DevNodeW(out devInst, pnpDeviceId, 0);
        if (locateResult != 0) return "REMOVE_DEVICE_NOT_FOUND:" + locateResult;

        StringBuilder veto = new StringBuilder(260);
        int vetoType;
        int result = CM_Query_And_Remove_SubTreeW(devInst, out vetoType, veto, 260, 0);
        if (result == 0) return "REMOVE_SUCCESS";

        string vetoName = veto.ToString();
        if (String.IsNullOrWhiteSpace(vetoName)) vetoName = "unknown";
        return "REMOVE_FAILED:" + result + "|vetoType=" + vetoType + "|vetoName=" + vetoName;
    }

    public static string Eject(string pnpDeviceId, int diskNumber, string[] driveLetters, string[] volumePaths) {
        // 1) Tum volume'lari zorla kapat
        foreach (string letter in driveLetters) {
            ForceClose("\\\\.\\" + letter.TrimEnd('\\', ':') + ":");
        }
        foreach (string volumePath in volumePaths) {
            ForceClose(volumePath);
        }
        // Fiziksel disk handle'ini da kapat
        ForceClose("\\\\.\\PhysicalDrive" + diskNumber);
        System.Threading.Thread.Sleep(500);

        // 2) Disk/USB storage dugumunu bul ve eject et.
        // En ust USB parent'i erken cikarmaya calismak STORAGE\Volume veto'suna yol acabiliyor.
        uint devInst;
        if (CM_Locate_DevNodeW(out devInst, pnpDeviceId, 0) != 0)
            return "DEVICE_NOT_FOUND";

        uint current = devInst;
        uint usbParent = 0;
        string usbParentId = "";
        string lastFailure = "";

        for (int i = 0; i < 12; i++) {
            StringBuilder id = new StringBuilder(260);
            CM_Get_Device_IDW(current, id, 260, 0);
            string deviceId = id.ToString();

            if (deviceId.StartsWith("USBSTOR\\", StringComparison.OrdinalIgnoreCase) ||
                deviceId.StartsWith("SCSI\\DISK", StringComparison.OrdinalIgnoreCase)) {
                string result = TryRequestEject(current, deviceId);
                if (result == "SUCCESS") return result;
                lastFailure = result;
            } else if (usbParent == 0 &&
                       deviceId.StartsWith("USB\\", StringComparison.OrdinalIgnoreCase)) {
                usbParent = current;
                usbParentId = deviceId;
            }

            uint parent;
            if (CM_Get_Parent(out parent, current, 0) != 0) break;
            current = parent;
        }

        if (usbParent != 0) {
            string result = TryRequestEject(usbParent, usbParentId);
            if (result == "SUCCESS") return result;
            lastFailure = result;
        }

        if (!String.IsNullOrEmpty(lastFailure)) return lastFailure;
        return "NO_USB_PARENT";
    }
}

public class SafeEjectRestartManager20260601 {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;
        public uint ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, IntPtr rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded,
        ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);

    public static int[] GetLockingProcessIds(string[] paths) {
        uint handle;
        string key = Guid.NewGuid().ToString();
        if (RmStartSession(out handle, 0, key) != 0) return new int[0];

        try {
            int registerResult = RmRegisterResources(handle, (uint)paths.Length, paths, 0, IntPtr.Zero, 0, null);
            if (registerResult != 0) return new int[0];

            uint needed = 0;
            uint count = 0;
            uint reasons = 0;
            int result = RmGetList(handle, out needed, ref count, null, ref reasons);
            if (needed == 0) return new int[0];

            count = needed;
            RM_PROCESS_INFO[] processes = new RM_PROCESS_INFO[count];
            result = RmGetList(handle, out needed, ref count, processes, ref reasons);
            if (result != 0) return new int[0];

            List<int> ids = new List<int>();
            for (int i = 0; i < count; i++) {
                int pid = processes[i].Process.dwProcessId;
                if (!ids.Contains(pid)) ids.Add(pid);
            }
            return ids.ToArray();
        } finally {
            RmEndSession(handle);
        }
    }
}
"@

function Get-UsbDisks {
    $disks = Get-Disk | Where-Object { $_.BusType -eq "USB" }
    foreach ($disk in $disks) {
        $wmiDisk = Get-WmiObject Win32_DiskDrive | Where-Object { $_.Index -eq $disk.Number }
        $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        $letters = @($partitions | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter)" })
        $volumePaths = @($partitions.AccessPaths | Where-Object { $_ -like "\\?\Volume{*}\" })
        $lettersDisplay = if ($letters.Count -gt 0) { ($letters | ForEach-Object { "$_`:" }) -join ", " } else { "(harf yok)" }
        [PSCustomObject]@{
            DiskNumber  = $disk.Number
            Model       = $disk.FriendlyName
            SizeGB      = [math]::Round($disk.Size / 1GB, 1)
            IsOffline   = $disk.IsOffline
            Letters     = $lettersDisplay
            LetterArr   = $letters
            VolumePaths = $volumePaths
            PnpDeviceId = $wmiDisk.PNPDeviceID
        }
    }
}

function Dismount-DriveLetters {
    param([string[]]$Letters)

    foreach ($letter in $Letters) {
        if ([string]::IsNullOrWhiteSpace($letter)) { continue }

        $driveLetter = "$($letter.TrimEnd(':')):"
        try {
            $escaped = $driveLetter.Replace("\", "\\").Replace("'", "''")
            $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$escaped'" -ErrorAction Stop
            if ($volume) {
                Invoke-CimMethod -InputObject $volume -MethodName Dismount -Arguments @{
                    Force = $true
                    Permanent = $false
                } -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            # FSCTL_DISMOUNT_VOLUME asagida ikinci bir sans olarak deneniyor.
        }
    }
}

function Dismount-VolumePaths {
    param([string[]]$VolumePaths)

    foreach ($volumePath in $VolumePaths) {
        if ([string]::IsNullOrWhiteSpace($volumePath)) { continue }

        try {
            $escaped = $volumePath.Replace("\", "\\").Replace("'", "''")
            $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DeviceID='$escaped'" -ErrorAction Stop
            if ($volume) {
                Write-SafeEjectLog "Dismounting volume path via CIM: $volumePath"
                Invoke-CimMethod -InputObject $volume -MethodName Dismount -Arguments @{
                    Force = $true
                    Permanent = $false
                } -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            Write-SafeEjectLog "CIM dismount failed for $volumePath : $($_.Exception.Message)"
        }

        try {
            Write-SafeEjectLog "Dismounting volume path via fsutil: $volumePath"
            $fsutilOutput = & fsutil volume dismount "$volumePath" 2>&1
            Write-SafeEjectLog "fsutil dismount output: $($fsutilOutput -join ' | ')"
        } catch {
            Write-SafeEjectLog "fsutil dismount failed for $volumePath : $($_.Exception.Message)"
        }
    }
}

function Set-UsbDiskOffline {
    param([int]$DiskNumber)

    try {
        Write-SafeEjectLog "Setting disk $DiskNumber offline"
        Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction Stop
        Start-Sleep -Seconds 1

        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        Write-SafeEjectLog "Disk $DiskNumber offline state after Set-Disk: IsOffline=$($disk.IsOffline), OperationalStatus=$($disk.OperationalStatus)"

        if ($disk.IsOffline) {
            return $true
        }
    } catch {
        Write-SafeEjectLog "Set-Disk offline failed for disk $DiskNumber : $($_.Exception.Message)"
    }

    return $false
}

function Set-UsbDiskOnline {
    param([int]$DiskNumber)

    try {
        Write-SafeEjectLog "Setting disk $DiskNumber online"
        Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop
        Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1

        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        Write-SafeEjectLog "Disk $DiskNumber online state after Set-Disk: IsOffline=$($disk.IsOffline), OperationalStatus=$($disk.OperationalStatus)"
        return (-not $disk.IsOffline)
    } catch {
        Write-SafeEjectLog "Set-Disk online failed for disk $DiskNumber : $($_.Exception.Message)"
    }

    return $false
}

function Get-AvailableDriveLetter {
    param([string]$PreferredLetter = "D")

    $used = @()
    try {
        $used = @((Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter)".ToUpperInvariant() }))
    } catch {
    }

    $preferred = $PreferredLetter.TrimEnd(":").ToUpperInvariant()
    if ($preferred -and $used -notcontains $preferred) {
        return $preferred
    }

    foreach ($code in ([int][char]'E')..([int][char]'Z')) {
        $letter = [char]$code
        if ($used -notcontains "$letter") {
            return "$letter"
        }
    }

    return $null
}

function Ensure-UsbDiskDriveLetter {
    param(
        [int]$DiskNumber,
        [string]$PreferredLetter = "D"
    )

    try {
        $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Where-Object { $_.Type -ne "Reserved" })
        foreach ($partition in $partitions) {
            if ($partition.DriveLetter) {
                Write-SafeEjectLog "Disk $DiskNumber partition $($partition.PartitionNumber) already has drive letter $($partition.DriveLetter)"
                return $true
            }
        }

        $targetPartition = $partitions | Sort-Object Size -Descending | Select-Object -First 1
        if (-not $targetPartition) {
            Write-SafeEjectLog "No partition found for drive letter restore on disk $DiskNumber"
            return $false
        }

        $letter = Get-AvailableDriveLetter -PreferredLetter $PreferredLetter
        if ([string]::IsNullOrWhiteSpace($letter)) {
            Write-SafeEjectLog "No available drive letter found for disk $DiskNumber"
            return $false
        }

        $accessPath = "$letter`:\"
        Write-SafeEjectLog "Assigning drive letter $accessPath to disk $DiskNumber partition $($targetPartition.PartitionNumber)"
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $targetPartition.PartitionNumber -AccessPath $accessPath -ErrorAction Stop
        return $true
    } catch {
        Write-SafeEjectLog "Add-PartitionAccessPath failed for disk $DiskNumber : $($_.Exception.Message)"
    }

    try {
        $volumePath = (Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop |
            ForEach-Object { $_.AccessPaths } |
            Where-Object { $_ -like "\\?\Volume{*}\" } |
            Select-Object -First 1)
        $letter = Get-AvailableDriveLetter -PreferredLetter $PreferredLetter

        if ($volumePath -and $letter) {
            Write-SafeEjectLog "Assigning drive letter fallback with mountvol $letter`: $volumePath"
            $mountvolOutput = & mountvol "$letter`:" "$volumePath" 2>&1
            Write-SafeEjectLog "mountvol assign output: $($mountvolOutput -join ' | ')"
            Start-Sleep -Seconds 1
            return [bool](Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue)
        }
    } catch {
        Write-SafeEjectLog "mountvol assign failed for disk $DiskNumber : $($_.Exception.Message)"
    }

    return $false
}

function Remove-DriveLetterMounts {
    param(
        [int]$DiskNumber,
        [string[]]$Letters
    )

    foreach ($letter in $Letters) {
        if ([string]::IsNullOrWhiteSpace($letter)) { continue }

        $accessPath = "$($letter.TrimEnd(':')):\"
        try {
            $partitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop |
                Where-Object { $_.AccessPaths -contains $accessPath }

            foreach ($partition in $partitions) {
                Write-SafeEjectLog "Removing access path $accessPath from disk $DiskNumber partition $($partition.PartitionNumber)"
                Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $accessPath -ErrorAction Stop
            }
        } catch {
            Write-SafeEjectLog "Remove access path failed for $accessPath : $($_.Exception.Message)"
        }
    }
}

function Get-DriveLockingProcesses {
    param([string[]]$Letters)

    $paths = @()
    foreach ($letter in $Letters) {
        if ([string]::IsNullOrWhiteSpace($letter)) { continue }
        $paths += "$($letter.TrimEnd(':')):\"
    }

    if ($paths.Count -eq 0) { return @() }

    Write-SafeEjectLog "Checking locking processes for paths: $($paths -join ', ')"
    $pids = [SafeEjectRestartManager20260601]::GetLockingProcessIds($paths)
    $currentPid = $PID

    $processes = foreach ($processId in $pids) {
        if ($processId -le 4 -or $processId -eq $currentPid) { continue }
        try {
            Get-Process -Id $processId -ErrorAction Stop
        } catch {
        }
    }

    return @($processes | Sort-Object Id -Unique)
}

function Stop-DriveLockingProcesses {
    param([System.Diagnostics.Process[]]$Processes)

    if (-not $Processes -or $Processes.Count -eq 0) { return }

    $lines = $Processes | ForEach-Object {
        $title = if ($_.MainWindowTitle) { " - $($_.MainWindowTitle)" } else { "" }
        "$($_.ProcessName) (PID $($_.Id))$title"
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Bu surucuyu kullanan uygulamalar bulundu:`n`n$($lines -join "`n")`n`nKapatip guvenli cikarmayi tekrar deneyeyim mi?",
        "SafeEject $script:SafeEjectVersion",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-SafeEjectLog "User declined closing locking processes"
        return
    }

    foreach ($process in $Processes) {
        try {
            Write-SafeEjectLog "Closing process $($process.ProcessName) pid=$($process.Id)"
            if ($process.MainWindowHandle -ne 0) {
                $null = $process.CloseMainWindow()
            }
        } catch {
            Write-SafeEjectLog "CloseMainWindow failed for pid=$($process.Id): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 3

    foreach ($process in $Processes) {
        try {
            $fresh = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
            if ($fresh) {
                Write-SafeEjectLog "Force stopping process $($fresh.ProcessName) pid=$($fresh.Id)"
                Stop-Process -Id $fresh.Id -Force -ErrorAction Stop
            }
        } catch {
            Write-SafeEjectLog "Stop-Process failed for pid=$($process.Id): $($_.Exception.Message)"
        }
    }
}

function Get-VetoNameFromResult {
    param([string]$Result)

    if ($Result -match "vetoName=(.+)$") {
        $name = $Matches[1].Trim()
    } elseif ($Result -like "FAILED:STORAGE\Volume*") {
        $name = $Result.Substring("FAILED:".Length).Trim()
    } else {
        return $null
    }

    if ($name -match '^(STORAGE\\Volume\\\{[0-9a-fA-F-]+\}#[0-9a-fA-F]+)') {
        return $Matches[1].ToUpperInvariant()
    }

    if ($name -match '^(STORAGE\\Volume\\[^|"\r\n]+)') {
        return $Matches[1].Trim().ToUpperInvariant()
    }

    return $name
}

function Get-FailedDeviceIdFromResult {
    param([string]$Result)

    if ($Result -match '^FAILED:([^|]+)') {
        return $Matches[1].Trim()
    }

    return $null
}

function Remove-VetoedVolumeDevice {
    param([string]$Result)

    $vetoName = Get-VetoNameFromResult -Result $Result
    if ([string]::IsNullOrWhiteSpace($vetoName)) { return $false }

    if ($vetoName -notlike "STORAGE\Volume*") {
        Write-SafeEjectLog "Veto device is not a storage volume, not removing: $vetoName"
        return $false
    }

    Write-SafeEjectLog "Removing vetoed storage volume device: $vetoName"
    $removeResult = [SafeEjectUsbEjector20260601]::RemoveDeviceNode($vetoName)
    Write-SafeEjectLog "Remove vetoed storage volume result: $removeResult"
    if ($removeResult -eq "REMOVE_SUCCESS") { return $true }

    try {
        $pnpDevice = Get-PnpDevice -InstanceId $vetoName -ErrorAction Stop
        Write-SafeEjectLog "PnP fallback found veto device status=$($pnpDevice.Status), class=$($pnpDevice.Class)"
    } catch {
        Write-SafeEjectLog "PnP fallback could not find veto device: $($_.Exception.Message)"
    }

    try {
        $pnputilOutput = & pnputil /remove-device "$vetoName" /subtree /force 2>&1
        Write-SafeEjectLog "pnputil remove-device output: $($pnputilOutput -join ' | ')"
        Start-Sleep -Seconds 1
        $stillThere = Get-PnpDevice -InstanceId $vetoName -ErrorAction SilentlyContinue
        return (-not $stillThere)
    } catch {
        Write-SafeEjectLog "pnputil remove-device failed: $($_.Exception.Message)"
    }

    return $false
}

function Remove-UsbHardwareDevice {
    param(
        [string]$DeviceId,
        [int]$DiskNumber
    )

    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        Write-SafeEjectLog "USB hardware removal skipped: empty device id"
        return $false
    }

    if ($DeviceId -notlike "USB\*" -and $DeviceId -notlike "USBSTOR\*" -and $DeviceId -notlike "SCSI\*") {
        Write-SafeEjectLog "USB hardware removal skipped for non-removable-looking device id: $DeviceId"
        return $false
    }

    try {
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if (-not $disk.IsOffline) {
            Write-SafeEjectLog "USB hardware removal skipped because disk $DiskNumber is not offline"
            return $false
        }
    } catch {
        Write-SafeEjectLog "USB hardware removal disk check failed: $($_.Exception.Message)"
    }

    Write-SafeEjectLog "Trying hardware eject/remove for device: $DeviceId"
    $removeResult = [SafeEjectUsbEjector20260601]::RemoveDeviceNode($DeviceId)
    Write-SafeEjectLog "Hardware RemoveDeviceNode result: $removeResult"
    if ($removeResult -eq "REMOVE_SUCCESS") { return $true }

    try {
        $pnputilOutput = & pnputil /remove-device "$DeviceId" /subtree /force 2>&1
        Write-SafeEjectLog "pnputil hardware remove-device output: $($pnputilOutput -join ' | ')"
        Start-Sleep -Seconds 1
        $stillThere = Get-PnpDevice -InstanceId $DeviceId -ErrorAction SilentlyContinue
        return (-not $stillThere -or $stillThere.Status -ne "OK")
    } catch {
        Write-SafeEjectLog "pnputil hardware remove-device failed: $($_.Exception.Message)"
    }

    return $false
}

$drives = Get-UsbDisks

if ($drives.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "Bagli USB surucu bulunamadi.",
        "SafeEject $script:SafeEjectVersion", "OK", "Information") | Out-Null
    exit
}

if ($drives.Count -eq 1) {
    $selected = $drives[0]
} else {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "SafeEject"
    $form.Size = New-Object System.Drawing.Size(440, 220)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Guvenle cikarilacak surucuyu sec:"
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size = New-Object System.Drawing.Size(410, 20)
    $form.Controls.Add($lbl)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(12, 36)
    $list.Size = New-Object System.Drawing.Size(410, 100)
    foreach ($d in $drives) {
        $list.Items.Add("$($d.Letters) - $($d.Model) ($($d.SizeGB) GB)")
    }
    $list.SelectedIndex = 0
    $form.Controls.Add($list)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Guvenli Cikar"
    $btn.Location = New-Object System.Drawing.Point(12, 145)
    $btn.Size = New-Object System.Drawing.Size(410, 32)
    $btn.DialogResult = "OK"
    $form.Controls.Add($btn)
    $form.AcceptButton = $btn

    if ($form.ShowDialog() -ne "OK") { exit }
    $selected = $drives[$list.SelectedIndex]
}

Write-SafeEjectLog "Started from $PSCommandPath as admin=$(Test-IsAdmin)"
Write-SafeEjectLog "Selected disk=$($selected.DiskNumber), model=$($selected.Model), letters=$($selected.Letters), volumes=$(($selected.VolumePaths) -join ', '), pnp=$($selected.PnpDeviceId)"

if ($selected.IsOffline) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "$($selected.Model) su an offline gorunuyor.`nKullanmak icin online yapayim mi?",
        "SafeEject $script:SafeEjectVersion",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)

    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        if (Set-UsbDiskOnline -DiskNumber $selected.DiskNumber) {
            if (Ensure-UsbDiskDriveLetter -DiskNumber $selected.DiskNumber -PreferredLetter "D") {
                [System.Windows.Forms.MessageBox]::Show(
                    "$($selected.Model) online yapildi ve surucu harfi geri verildi.",
                    "SafeEject $script:SafeEjectVersion", "OK", "Information") | Out-Null
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "$($selected.Model) online yapildi, ama surucu harfi otomatik verilemedi.`nDisk Management uzerinden harf ataman gerekebilir.",
                    "SafeEject $script:SafeEjectVersion", "OK", "Warning") | Out-Null
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "$($selected.Model) online yapilamadi.`nDisk Management uzerinden manuel online yapman gerekebilir.",
                "SafeEject $script:SafeEjectVersion - Hata", "OK", "Warning") | Out-Null
        }
    }
    exit
}

if ($selected.LetterArr.Count -eq 0 -and $selected.VolumePaths.Count -gt 0) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "$($selected.Model) online, ama surucu harfi yok. Bu yuzden Bu Bilgisayar'da gorunmez.`nSurucu harfi atayip gorunur yapayim mi?",
        "SafeEject $script:SafeEjectVersion",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)

    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        if (Ensure-UsbDiskDriveLetter -DiskNumber $selected.DiskNumber -PreferredLetter "D") {
            [System.Windows.Forms.MessageBox]::Show(
                "$($selected.Model) icin surucu harfi geri verildi.",
                "SafeEject $script:SafeEjectVersion", "OK", "Information") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "$($selected.Model) icin surucu harfi verilemedi.`nDisk Management uzerinden manuel harf ataman gerekebilir.",
                "SafeEject $script:SafeEjectVersion - Hata", "OK", "Warning") | Out-Null
        }
        exit
    }
}

$lastFailedDeviceId = $null

$lockingProcesses = Get-DriveLockingProcesses -Letters $selected.LetterArr
if ($lockingProcesses.Count -gt 0) {
    Write-SafeEjectLog "Locking processes found: $(($lockingProcesses | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', ')"
    Stop-DriveLockingProcesses -Processes $lockingProcesses
} else {
    Write-SafeEjectLog "No locking processes found"
}

Dismount-DriveLetters -Letters $selected.LetterArr
Dismount-VolumePaths -VolumePaths $selected.VolumePaths
$result = [SafeEjectUsbEjector20260601]::Eject($selected.PnpDeviceId, $selected.DiskNumber, $selected.LetterArr, $selected.VolumePaths)
Write-SafeEjectLog "First eject result: $result"
if ($result -like "FAILED:*") { $lastFailedDeviceId = Get-FailedDeviceIdFromResult -Result $result }

if ($result -like "FAILED:STORAGE\Volume*" -or $result -match "vetoName=STORAGE\\Volume") {
    $lockingProcesses = Get-DriveLockingProcesses -Letters $selected.LetterArr
    if ($lockingProcesses.Count -gt 0) {
        Write-SafeEjectLog "Locking processes found before retry: $(($lockingProcesses | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', ')"
        Stop-DriveLockingProcesses -Processes $lockingProcesses
    }

    $removedVetoDevice = Remove-VetoedVolumeDevice -Result $result
    if ($removedVetoDevice) {
        Start-Sleep -Seconds 1
        $result = [SafeEjectUsbEjector20260601]::Eject($selected.PnpDeviceId, $selected.DiskNumber, $selected.LetterArr, $selected.VolumePaths)
        Write-SafeEjectLog "Retry after removing vetoed volume device: $result"
        if ($result -like "FAILED:*") { $lastFailedDeviceId = Get-FailedDeviceIdFromResult -Result $result }
    }
}

if ($result -like "FAILED:STORAGE\Volume*" -or $result -match "vetoName=STORAGE\\Volume") {
    Write-SafeEjectLog "Storage volume veto detected; removing drive letter mounts and retrying"
    Remove-DriveLetterMounts -DiskNumber $selected.DiskNumber -Letters $selected.LetterArr
    Dismount-VolumePaths -VolumePaths $selected.VolumePaths
    Start-Sleep -Milliseconds 700
    $result = [SafeEjectUsbEjector20260601]::Eject($selected.PnpDeviceId, $selected.DiskNumber, $selected.LetterArr, $selected.VolumePaths)
    Write-SafeEjectLog "Retry after removing drive letters: $result"
    if ($result -like "FAILED:*") { $lastFailedDeviceId = Get-FailedDeviceIdFromResult -Result $result }
}

if ($result -ne "SUCCESS") {
    Write-SafeEjectLog "Eject did not succeed; trying offline fallback"
    if (Set-UsbDiskOffline -DiskNumber $selected.DiskNumber) {
        Start-Sleep -Seconds 1
        $afterOfflineResult = [SafeEjectUsbEjector20260601]::Eject($selected.PnpDeviceId, $selected.DiskNumber, $selected.LetterArr, $selected.VolumePaths)
        Write-SafeEjectLog "Retry after offline: $afterOfflineResult"

        if ($afterOfflineResult -eq "SUCCESS") {
            $result = "SUCCESS"
        } else {
            if ($afterOfflineResult -like "FAILED:*") {
                $lastFailedDeviceId = Get-FailedDeviceIdFromResult -Result $afterOfflineResult
            }

            if (Remove-UsbHardwareDevice -DeviceId $lastFailedDeviceId -DiskNumber $selected.DiskNumber) {
                $result = "HARDWARE_REMOVED_SUCCESS"
            } else {
                $result = "OFFLINE_SUCCESS"
            }
        }
    }
}

if ($result -eq "SUCCESS") {
    [System.Windows.Forms.MessageBox]::Show(
        "$($selected.Model) ($($selected.Letters)) guvenle cikarildi.`nCihazi cekebilirsin.",
        "SafeEject $script:SafeEjectVersion", "OK", "Information") | Out-Null
} elseif ($result -eq "OFFLINE_SUCCESS") {
    [System.Windows.Forms.MessageBox]::Show(
        "$($selected.Model) offline alindi, ancak donanim kaldirma tamamlanamadi.`nWindows dosya sistemini kullanmiyor; yine de fan durmazsa sistem tepsisinden donanimi kaldirmayi dene.",
        "SafeEject $script:SafeEjectVersion", "OK", "Information") | Out-Null
} elseif ($result -eq "HARDWARE_REMOVED_SUCCESS") {
    [System.Windows.Forms.MessageBox]::Show(
        "$($selected.Model) offline alindi ve donanim olarak kaldirildi.`nCihazi cekebilirsin.",
        "SafeEject $script:SafeEjectVersion", "OK", "Information") | Out-Null
} elseif ($result -like "FAILED:*") {
    $reason = $result.Replace("FAILED:", "")
    if ($reason -like "STORAGE\Volume*") {
        $reason = "Windows surucuyu hala kullanimda goruyor. Tum Explorer pencerelerini, terminal D: konumundaysa terminali, Steam/yedekleme/senkronizasyon uygulamalarini kapatip tekrar dene."
    } elseif ($reason -match "vetoName=(.+)$") {
        $vetoName = $Matches[1]
        if ($vetoName -like "STORAGE\Volume*") {
            $reason = "Windows surucuyu hala kullanimda goruyor. Tum Explorer pencerelerini, terminal D: konumundaysa terminali, Steam/yedekleme/senkronizasyon uygulamalarini kapatip tekrar dene."
        } elseif ($vetoName -eq "unknown") {
            $reason = "Windows cihaz cikarma istegini reddetti, ancak ayrintili sebep dondurmedi."
        } else {
            $reason = $vetoName
        }
    }
    [System.Windows.Forms.MessageBox]::Show(
        "$($selected.Model) cikarilmadi.`nSebep: $reason`n`nLog: $script:LogPath",
        "SafeEject $script:SafeEjectVersion - Hata", "OK", "Warning") | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show(
        "Cihaz bulunamadi veya zaten cikarilmis.",
        "SafeEject $script:SafeEjectVersion", "OK", "Warning") | Out-Null
}
