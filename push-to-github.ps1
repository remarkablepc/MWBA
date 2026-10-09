<#
push-to-github.ps1

Helper to initialize a local git repo, add a safe .gitignore, and create a private GitHub repository
using the GitHub CLI (`gh`). This script is interactive and does not expose secrets.

Usage:
  Open an elevated PowerShell prompt, cd to the MWBA folder and run:
    .\push-to-github.ps1 -RepoName MWBA -Owner <your-github-username>

Notes:
 - Requires `git` and `gh` (GitHub CLI) to be installed and authenticated (`gh auth login`).
 - This script will NOT push files excluded by .gitignore. Review .gitignore first.
 - Do NOT commit BitLocker keys or other secrets. Use repo secrets for CI instead.
#>

param(
    [Parameter(Mandatory=$true)][string]$RepoName,
    [Parameter(Mandatory=$true)][string]$Owner,
    [string]$DefaultBranch = 'main'
)

function WarnAndExit($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

# Preconditions
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { WarnAndExit 'git is not installed or not in PATH.' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { WarnAndExit 'gh (GitHub CLI) is not installed or not in PATH.' }

Write-Host "Initializing local repository in: $PWD" -ForegroundColor Cyan
if (-not (Test-Path .git)) {
    git init
    git checkout -b $DefaultBranch
} else {
    Write-Host 'Repository already initialized locally.' -ForegroundColor Yellow
}

# Ensure .gitignore exists
if (-not (Test-Path .gitignore)) {
    Write-Host 'No .gitignore found; creating a default one.' -ForegroundColor Yellow
    "# Default .gitignore" | Out-File -FilePath .gitignore -Encoding utf8
}

Write-Host 'Staging files (respects .gitignore)...' -ForegroundColor Cyan
git add .

Write-Host 'Committing (if needed)...' -ForegroundColor Cyan
try {
    git commit -m "Initial commit: MWBA v0.2.0" -q
} catch {
    Write-Host 'No changes to commit or commit failed (already committed).' -ForegroundColor Yellow
}

# Create private repo via gh
$fullName = "$Owner/$RepoName"
$exists = gh repo view $fullName --json name -q 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Repository $fullName already exists on GitHub." -ForegroundColor Yellow
    Write-Host 'Skipping creation. Attempting to set remote and push.'
} else {
    Write-Host "Creating private GitHub repo: $fullName" -ForegroundColor Cyan
    gh repo create $fullName --private --source=. --remote=origin --push
    if ($LASTEXITCODE -ne 0) { WarnAndExit 'gh repo create failed. Check gh auth and network.' }
}

Write-Host 'Push complete. Configure branch protection and secrets in the GitHub web UI as needed.' -ForegroundColor Green
