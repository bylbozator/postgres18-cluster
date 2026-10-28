<#
.SYNOPSIS
    Создание ВМ Hyper-V (Ubuntu 24.04) для лабораторного кластера Percona PPG 18.

.DESCRIPTION
    Шаги, которые скрипт автоматизирует:
      1) облачный образ Ubuntu 24.04 (qcow2) конвертируется в VHDX (qemu-img);
      2) создаётся seed-диск с cloud-init (NoCloud, метка CIDATA);
      3) создаётся ВМ поколения 2, 4 vCPU / 4 GB RAM, диск 40 GB;
      4) ВМ запускается, cloud-init сам создаёт пользователя student и SSH-ключ.

    Требуется запуск от имени администратора (Hyper-V).
    qemu-img нужен только на шаге конвертации облачного образа:
        qemu-img convert -f qcow2 -O vhdx noble-server-cloudimg-amd64.img pg18-os.vhdx
    (сборка qemu-img для Windows: https://qemu.weilnetz.de/w64/)
#>

param(
    [string]$Base     = "C:\pg18vm",
    [string]$VmName   = "pg18-lab",
    [int]$MemoryGB    = 4,
    [int]$CpuCount    = 4,
    [int]$DiskGB      = 40,
    [string]$Switch   = "Default Switch"
)

$ErrorActionPreference = 'Stop'

$osImage = Join-Path $Base 'pg18-os.vhdx'
$seed    = Join-Path $Base 'pg18-seed.vhdx'
$seedSrc = Join-Path $Base 'seed'

if (-not (Test-Path $osImage)) { throw "Нет файла $osImage (сконвертируйте облачный образ в VHDX)" }
if (-not (Test-Path $seedSrc))  { throw "Нет каталога $seedSrc с user-data и meta-data" }

# --- seed-диск с cloud-init ---
if (Test-Path $seed) {
    try { Dismount-VHD -Path $seed -ErrorAction SilentlyContinue } catch {}
    Remove-Item $seed -Force
}
New-VHD -Path $seed -SizeBytes 64MB -Fixed | Out-Null
$disk = Mount-VHD -Path $seed -Passthru | Get-Disk
Set-Disk -Number $disk.Number -IsOffline $false
Set-Disk -Number $disk.Number -IsReadOnly $false
Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction SilentlyContinue | Out-Null
$part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'CIDATA' -Confirm:$false | Out-Null
$letter = (Get-Partition -DiskNumber $disk.Number | Where-Object DriveLetter).DriveLetter
Copy-Item (Join-Path $seedSrc 'user-data')   -Destination "${letter}:" -Force
Copy-Item (Join-Path $seedSrc 'meta-data')   -Destination "${letter}:" -Force
Copy-Item (Join-Path $seedSrc 'vendor-data') -Destination "${letter}:" -Force -ErrorAction SilentlyContinue
Dismount-VHD -Path $seed

# --- основной диск до нужного размера ---
if ((Get-VHD -Path $osImage).Size -lt ($DiskGB * 1GB)) {
    Resize-VHD -Path $osImage -SizeBytes ($DiskGB * 1GB)
}

# --- сама виртуальная машина ---
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { Remove-VM -Name $VmName -Force }
New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) -VHDPath $osImage -SwitchName $Switch | Out-Null
Set-VMProcessor -VMName $VmName -Count $CpuCount
Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false
Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
Add-VMHardDiskDrive -VMName $VmName -Path $seed -ControllerType SCSI
$osDisk = Get-VMHardDiskDrive -VMName $VmName | Where-Object { $_.Path -eq $osImage }
Set-VMFirmware -VMName $VmName -FirstBootDevice $osDisk
Start-VM -Name $VmName

Start-Sleep -Seconds 5
Get-VM -Name $VmName | Select-Object Name, State, @{n = 'RAM_GB'; e = { $_.MemoryAssigned / 1GB } }
Get-VMNetworkAdapter -VMName $VmName | Select-Object Name, SwitchName, MacAddress, @{n = 'IP'; e = { $_.IPAddresses -join ',' } }
