<#
.SYNOPSIS
    Arcane & Traefik Air-Gapped Bundler & Remote SSH Deployer (PowerShell version)
.DESCRIPTION
    Pulls required Docker images, packages the configuration files, certificates, and data,
    creates a compressed archive, transfers it to an air-gapped Ubuntu server via SSH/SCP,
    and optionally executes deploy_on_server.sh remotely.
.EXAMPLE
    .\bundle_and_push.ps1 -Target "ubuntu@192.168.1.100" -AutoRun
    .\bundle_and_push.ps1 -BundleOnly
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Target = "ubuntu@192.168.1.100",

    [Parameter(Mandatory = $false)]
    [int]$Port = 22,

    [Parameter(Mandatory = $false)]
    [string]$IdentityFile = "",

    [Parameter(Mandatory = $false)]
    [string]$Dest = "/opt/arcane-docker-manager",

    [Parameter(Mandatory = $false)]
    [switch]$AutoRun = $false,

    [Parameter(Mandatory = $false)]
    [switch]$BundleOnly = $false,

    [Parameter(Mandatory = $false)]
    [switch]$ExcludeData = $false,

    [Parameter(Mandatory = $false)]
    [string[]]$ExtraImages = @(),

    [Parameter(Mandatory = $false)]
    [string]$OutputBundle = "arcane-airgap-bundle.tar.gz"
)

# ==============================================================================
# ALL SCRIPT-LEVEL VARIABLES DEFINED AT THE TOP WITH DEFAULT VALUES
# ==============================================================================

$ErrorActionPreference = "Stop"

# --- Compose & Archive Filenames ---
$ComposeFile = "compose.yaml"
$ImageArchiveName = "docker-images.tar.gz"

# --- Image Definitions ---
$FallbackImages = @("ghcr.io/getarcaneapp/manager:v2.15.0", "traefik:v3.7.13")
$Images = @()
$ComposeLines = @()

# --- Temporary Directory Paths ---
$TempDir = ""
$StagingDir = ""
$ImagesTar = ""

# --- SSH / SCP Options ---
$SshArgs = @()
$ScpArgs = @()

# --- Interactive Prompts Temporary Buffers ---
$TargetInput = ""
$PortInput = ""
$KeyInput = ""
$DestInput = ""
$RunInput = ""

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Write-Info { param([string]$msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Write-Success { param([string]$msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "[WARNING] $msg" -ForegroundColor Yellow }
function Write-Err { param([string]$msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

# ==============================================================================
# MAIN LOGIC
# ==============================================================================

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "    Arcane & Traefik - Air-Gap Packager & Deployer       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Interactive mode if -Target not explicitly given and not in BundleOnly mode
$TargetExplicit = $PSBoundParameters.ContainsKey('Target')
if (-not $BundleOnly -and -not $TargetExplicit) {
    Write-Host "`nInteractive Mode (press Enter to accept default values):`n" -ForegroundColor Yellow
    $TargetInput = Read-Host "Target SSH host [Default: $Target]"
    if (-not [string]::IsNullOrWhiteSpace($TargetInput)) { $Target = $TargetInput }
    
    $PortInput = Read-Host "SSH Port [Default: $Port]"
    if (-not [string]::IsNullOrWhiteSpace($PortInput)) { $Port = [int]$PortInput }
    
    $KeyInput = Read-Host "SSH Identity file (Default: system default)"
    if (-not [string]::IsNullOrWhiteSpace($KeyInput)) { $IdentityFile = $KeyInput }
    
    $DestInput = Read-Host "Remote destination directory [Default: $Dest]"
    if (-not [string]::IsNullOrWhiteSpace($DestInput)) { $Dest = $DestInput }
    
    $RunInput = Read-Host "Automatically run deploy_on_server.sh on remote server? [y/N] (Default: n)"
    if ($RunInput -match "^[Yy]") { $AutoRun = $true }
}

# Pre-flight checks
Write-Info "Checking local tools..."
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err "Docker is required to pull and package images, but was not found."
    exit 1
}

if (-not $BundleOnly) {
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Write-Err "SSH client is required to connect to the remote server, but was not found."
        exit 1
    }
    if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
        Write-Err "SCP is required to transfer the bundle to the remote server, but was not found."
        exit 1
    }
}

# Image collection
Write-Info "Discovering Docker images required by the project..."
if (Test-Path $ComposeFile) {
    $ComposeLines = Get-Content $ComposeFile
    foreach ($line in $ComposeLines) {
        if ($line -match '^\s*image:\s*([^\s#]+)') {
            $Images += $matches[1].Trim('"').Trim("'")
        }
    }
}

if ($Images.Count -eq 0) {
    $Images = $FallbackImages
}

if ($ExtraImages.Count -gt 0) {
    $Images += $ExtraImages
}

Write-Info "Images to package:"
foreach ($img in $Images) {
    Write-Host "  - $img" -ForegroundColor Cyan
}

# Pull Docker images
Write-Info "Pulling Docker images from registry to ensure latest copies..."
foreach ($img in $Images) {
    Write-Info "Pulling $img..."
    & docker pull $img
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to pull $img"
        exit 1
    }
}
Write-Success "All Docker images verified locally."

# Staging
$TempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "arcane_bundle_" + [System.Guid]::NewGuid().ToString().Substring(0,8))
$StagingDir = Join-Path $TempDir "staging"
New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

try {
    Write-Info "Saving Docker images to ${StagingDir}/${ImageArchiveName}..."
    $ImagesTar = Join-Path $TempDir "docker-images.tar"
    & docker save $Images -o $ImagesTar
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to save Docker images."
        exit 1
    }

    Write-Info "Compressing Docker images..."
    if (Get-Command gzip -ErrorAction SilentlyContinue) {
        & gzip -c $ImagesTar > (Join-Path $StagingDir $ImageArchiveName)
        Remove-Item $ImagesTar -Force
    } else {
        & tar -czf (Join-Path $StagingDir $ImageArchiveName) -C $TempDir "docker-images.tar"
        Remove-Item $ImagesTar -Force
    }
    Write-Success "Docker images saved and compressed."

    Write-Info "Copying project files..."
    if (Test-Path $ComposeFile) { Copy-Item $ComposeFile $StagingDir }
    if (Test-Path ".env") { Copy-Item ".env" $StagingDir }
    if (Test-Path ".env.example") { Copy-Item ".env.example" $StagingDir }
    if (Test-Path "traefik") { Copy-Item "traefik" $StagingDir -Recurse }
    if (Test-Path "projects") { Copy-Item "projects" $StagingDir -Recurse } else { New-Item -ItemType Directory -Path (Join-Path $StagingDir "projects") | Out-Null }
    if (Test-Path "arcane-backups") { Copy-Item "arcane-backups" $StagingDir -Recurse } else { New-Item -ItemType Directory -Path (Join-Path $StagingDir "arcane-backups") | Out-Null }

    if (-not $ExcludeData -and (Test-Path "arcane-data")) {
        Write-Info "Including arcane-data..."
        Copy-Item "arcane-data" $StagingDir -Recurse
    } else {
        New-Item -ItemType Directory -Path (Join-Path $StagingDir "arcane-data") | Out-Null
    }

    if (Test-Path "deploy_on_server.sh") {
        Copy-Item "deploy_on_server.sh" $StagingDir
    } else {
        Write-Err "deploy_on_server.sh missing from current directory."
        exit 1
    }

    Write-Info "Creating final package: $OutputBundle..."
    if (Test-Path $OutputBundle) { Remove-Item $OutputBundle -Force }
    & tar -czf $OutputBundle -C $StagingDir .
    Write-Success "Bundle successfully created: $OutputBundle"

    if ($BundleOnly) {
        Write-Host "`n==========================================================" -ForegroundColor Green
        Write-Host "             Bundle Ready for Offline Transfer!           " -ForegroundColor Green
        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host "Archive: $OutputBundle" -ForegroundColor Cyan
        Write-Host "Transfer this file to the air-gapped Ubuntu server and execute deploy_on_server.sh"
        return
    }

    $SshArgs = @("-p", $Port, "-o", "StrictHostKeyChecking=accept-new")
    $ScpArgs = @("-P", $Port, "-o", "StrictHostKeyChecking=accept-new")
    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $SshArgs += @("-i", $IdentityFile)
        $ScpArgs += @("-i", $IdentityFile)
    }

    Write-Info "Testing SSH connection to $Target..."
    & ssh $SshArgs $Target "echo 'SSH connection verified'"
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Could not connect to $Target via SSH."
        exit 1
    }
    Write-Success "SSH connection verified."

    Write-Info "Creating remote directory '$Dest'..."
    & ssh $SshArgs $Target "sudo mkdir -p '$Dest' && sudo chown -R `$(whoami) '$Dest' 2>/dev/null || mkdir -p '$Dest'"

    Write-Info "Uploading bundle via SCP..."
    & scp $ScpArgs $OutputBundle "${Target}:${Dest}/${OutputBundle}"
    if ($LASTEXITCODE -ne 0) {
        Write-Err "SCP upload failed."
        exit 1
    }
    Write-Success "Bundle uploaded to server."

    if ($AutoRun) {
        Write-Info "Running deploy_on_server.sh on remote server..."
        & ssh -t $SshArgs $Target "cd '$Dest' && tar -xzf '$OutputBundle' && chmod +x deploy_on_server.sh && (sudo ./deploy_on_server.sh || ./deploy_on_server.sh)"
    } else {
        Write-Host "`n==========================================================" -ForegroundColor Green
        Write-Host "         Bundle Successfully Pushed to Remote Server!      " -ForegroundColor Green
        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host "Uploaded to: ${Target}:${Dest}/${OutputBundle}`n"
        Write-Host "To deploy, SSH into the server and run:"
        Write-Host "  ssh -p $Port $Target" -ForegroundColor Cyan
        Write-Host "  cd $Dest" -ForegroundColor Cyan
        Write-Host "  tar -xzf $OutputBundle" -ForegroundColor Cyan
        Write-Host "  sudo ./deploy_on_server.sh" -ForegroundColor Cyan
    }

} finally {
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
