#requires -Version 5.1

[CmdletBinding()]
param(
    [string] $ReleaseBaseUrl = 'https://raw.githubusercontent.com/orelavvalero-cell/PowerChat-Global/main'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$installDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PowerChat'
$scriptTarget = Join-Path $installDirectory 'PowerChat.ps1'
$windowsAppsDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Microsoft\WindowsApps'
$launcherTarget = Join-Path $windowsAppsDirectory 'powerchat.cmd'

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null

$localSource = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'PowerChat.ps1' } else { '' }
if ($localSource -and (Test-Path -LiteralPath $localSource)) {
    Copy-Item -LiteralPath $localSource -Destination $scriptTarget -Force
}
elseif ($ReleaseBaseUrl) {
    $sourceUrl = "$($ReleaseBaseUrl.TrimEnd('/'))/PowerChat.ps1"
    Invoke-WebRequest -Uri $sourceUrl -OutFile $scriptTarget -UseBasicParsing
}
else {
    throw 'PowerChat.ps1 could not be found locally and no download address was provided.'
}

New-Item -ItemType Directory -Path $windowsAppsDirectory -Force | Out-Null
$launcher = "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%LOCALAPPDATA%\PowerChat\PowerChat.ps1`" %*`r`n"
[IO.File]::WriteAllText($launcherTarget, $launcher, [Text.Encoding]::ASCII)

Write-Host 'PowerChat installed successfully.' -ForegroundColor Green
Write-Host 'Open a new terminal and run: powerchat' -ForegroundColor Cyan
