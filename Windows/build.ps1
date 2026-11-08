[CmdletBinding()]
param(
    [switch]$SkipInstaller,
    [string]$Python = "python",
    [string]$Iscc = ""
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$projectDir = $PSScriptRoot
$buildDir = Join-Path $projectDir "build"
$distDir = Join-Path $projectDir "dist"
$releaseDir = Join-Path $projectDir "release"

# A caller can pass a repository-relative virtualenv Python executable.
if (Test-Path $Python -PathType Leaf) { $Python = (Resolve-Path $Python).Path }

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "Run this build on Windows. GitHub Actions supplies a Windows build machine."
}
New-Item -ItemType Directory -Force -Path $buildDir, $distDir, $releaseDir | Out-Null
Push-Location $projectDir
try {
    & $Python -m PyInstaller --noconfirm --clean --workpath $buildDir --distpath $distDir (Join-Path $projectDir "Imspect.spec")
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed with exit code $LASTEXITCODE" }
    $applicationDir = Join-Path $distDir "Imspect"
    if (-not (Test-Path (Join-Path $applicationDir "Imspect.exe"))) { throw "Missing packaged executable" }
    Copy-Item (Join-Path $projectDir "README.md") $applicationDir -Force
    Copy-Item (Join-Path $projectDir "THIRD_PARTY.md") $applicationDir -Force

    $portable = Join-Path $releaseDir "Imspect-0.3.1-Windows-x64-Portable.zip"
    if (Test-Path $portable) { Remove-Item $portable }
    Compress-Archive -Path $applicationDir -DestinationPath $portable -CompressionLevel Optimal

    if (-not $SkipInstaller) {
        if (-not $Iscc) {
            $compilerCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
            if ($compilerCommand) { $Iscc = $compilerCommand.Source }
        }
        if (-not $Iscc) {
            foreach ($candidate in @(
                "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
                "$env:ProgramFiles\Inno Setup 7\ISCC.exe"
            )) {
                if (Test-Path $candidate) { $Iscc = $candidate; break }
            }
        }
        if (-not $Iscc) { throw "Install Inno Setup 6 or later from https://jrsoftware.org/isdl.php, or pass -Iscc its full ISCC.exe path." }
        & $Iscc "/DSourceDir=$applicationDir" "/DOutputDir=$releaseDir" (Join-Path $projectDir "installer.iss")
        if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed with exit code $LASTEXITCODE" }
    }
    $hashLines = Get-ChildItem $releaseDir -File | Where-Object { $_.Extension -in ".exe", ".zip" } | Sort-Object Name | ForEach-Object {
        "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
    }
    $hashLines | Set-Content (Join-Path $releaseDir "SHA256SUMS.txt") -Encoding ascii
    Write-Host "Built packages in $releaseDir"
}
finally { Pop-Location }
