<# ======================================================================
  Get-Ado-Contributors.ps1
  Purpose:
    Extract authors (who wrote) and committers (who pushed) from Azure DevOps
    across selected projects/repos for a date range.

  Key Features:
    • Leave $Projects = "" to scan ALL accessible projects in the org
    • Skips projects/repos without access (401/403) or missing (404)
    • Labels project access issues in per-project CSVs via a Status column
    • Exports:
        1) All commits
        2) Unique contributors (authors) per repo
        3) Unique committers (pushers) per repo
        4) Contributors by project (with Status)
        5) Committers by project  (with Status)
        6) Org-wide unique contributors
        7) Org-wide unique committers
        8) (Optional) Repo issues log CSV

  HOW TO USE:
    1) Edit CONFIG (OrgUrl, Pat, Projects, dates).
    2) Run:  powershell -ExecutionPolicy Bypass -File .\Get-Ado-Contributors.ps1
====================================================================== #>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ======================
# ====== CONFIG ========
# ======================
# Organization URL (MUST include org name)
$OrgUrl = "https://dev.azure.com/$org"     # e.g., https://dev.azure.com/<your-org>

# Personal Access Token (PAT) – must have scopes:
#   • Code (Read)
#   • Project and Team (Read)
$Pat = "PAT KEY"

# Specific projects (comma-separated) or "" for ALL accessible projects
$Projects = ""  # "" => all projects; e.g. "ProjectA,ProjectB"

# Date window (ISO yyyy-MM-dd). FromDate is server-side; ToDate is client-side filter.
$FromDate = "2025-08-01"
$ToDate   = "2025-11-01"   # or "" to disable upper bound

# Output directory
$OutDir = "C:\Users\KhanM8\Downloads\AdoReports"

# Emit a repo issues CSV (for missing/forbidden repos etc.)
$EmitRepoIssuesCsv = $true

# ======================
# ==== HELPERS =========
# ======================
function New-AuthHeaderFromPat {
  param([Parameter(Mandatory=$true)][string] $Token)
  $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
  return @{ Authorization = "Basic $basic" }
}

function Invoke-AdoGet {
  param(
    [Parameter(Mandatory=$true)][string] $Url,
    [hashtable] $Headers,
    [int] $MaxRetry = 3
  )
  for ($i=0; $i -lt $MaxRetry; $i++) {
    try {
      return Invoke-RestMethod -Method GET -Uri $Url -Headers $Headers -ErrorAction Stop
    } catch {
      $code = $null
      if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
        $code = $_.Exception.Response.StatusCode.Value__
      }
      if ($code -eq 401 -or $code -eq 403) { throw "ACCESS_DENIED" }
      if ($code -eq 404)                    { throw "NOT_FOUND" }
      if ($i -ge $MaxRetry - 1) { throw }
      Start-Sleep -Seconds (2 * ($i + 1))
    }
  }
}

function Test-OrgAndToken {
  param([string]$OrgUrl, [hashtable]$Headers)
  $url = "$OrgUrl/_apis/projects?`$top=1&api-version=7.1-preview.4"
  $null = Invoke-AdoGet -Url $url -Headers $Headers
}

# ======================
# ==== API WRAPPERS ====
# ======================
function Get-AdoProjects {
  param([string]$OrgUrl, [hashtable]$Headers)
  $apiVer = "7.1-preview.4"
  $all = @()
  $cont = $null

  do {
    $url = if ($cont) {
      "$OrgUrl/_apis/projects?continuationToken=$([uri]::EscapeDataString($cont))&api-version=$apiVer"
    } else {
      "$OrgUrl/_apis/projects?api-version=$apiVer"
    }

    # Use IWR to read x-ms-continuationtoken
    $resp  = Invoke-WebRequest -Method GET -Uri $url -Headers $Headers -ErrorAction Stop
    $json  = $resp.Content | ConvertFrom-Json
    if ($json.value) { $all += $json.value }
    $cont = $resp.Headers['x-ms-continuationtoken']
  } while ($cont)

  return $all
}

# Returns: @{ Repos = <array>; Access = "OK"|"ACCESS_DENIED"|"ERROR" }
function Get-AdoRepos {
  param([string]$OrgUrl, [hashtable]$Headers, [string]$ProjectName)
  $apiVer = "7.1-preview.1"
  $all = @()
  $cont = $null
  try {
    do {
      $url = if ($cont) {
        "$OrgUrl/$($ProjectName)/_apis/git/repositories?continuationToken=$([uri]::EscapeDataString($cont))&api-version=$apiVer"
      } else {
        "$OrgUrl/$($ProjectName)/_apis/git/repositories?api-version=$apiVer"
      }
      $resp = Invoke-WebRequest -Method GET -Uri $url -Headers $Headers -ErrorAction Stop
      $json = $resp.Content | ConvertFrom-Json
      if ($json.value) { $all += $json.value }
      $cont = $resp.Headers['x-ms-continuationtoken']
    } while ($cont)
    return [pscustomobject]@{ Repos = $all; Access = "OK" }
  } catch {
    if ($_.Exception.PSObject.Properties.Name -contains 'Response') {
      $code = $_.Exception.Response.StatusCode.Value__
      if ($code -eq 401 -or $code -eq 403) {
        Write-Host "  ⚠ No access to project: $ProjectName — skipping" -ForegroundColor Yellow
        return [pscustomobject]@{ Repos = @(); Access = "ACCESS_DENIED" }
      }
    }
    Write-Host "  ⚠ Error listing repos for project: $ProjectName — skipping" -ForegroundColor Yellow
    return [pscustomobject]@{ Repos = @(); Access = "ERROR" }
  }
}

function Get-AdoCommits {
  param(
    [string] $OrgUrl,
    [hashtable] $Headers,
    [string] $ProjectName,
    [string] $RepoId,
    [string] $FromDate,
    [string] $ToDate,
    [string] $RepoName = $null
  )
  $apiVer = "7.1-preview.1"
  $top  = 200
  $skip = 0
  $results = @()

  do {
    $url = "$OrgUrl/$($ProjectName)/_apis/git/repositories/$RepoId/commits" +
           "?searchCriteria.fromDate=$([uri]::EscapeDataString($FromDate))" +
           "&`$top=$top&`$skip=$skip&api-version=$apiVer"
    try {
      $resp = Invoke-AdoGet -Url $url -Headers $Headers
    } catch {
      # PowerShell 5.1-safe label (no ??)
      $repoLabel = if ([string]::IsNullOrWhiteSpace($RepoName)) { $RepoId } else { $RepoName }

      if ($_.Exception -eq "ACCESS_DENIED") {
        Write-Host ("    ⚠ No access to repo: {0} ({1}) — skipping" -f $repoLabel, $ProjectName) -ForegroundColor Yellow
        return @()
      }
      if ($_.Exception -eq "NOT_FOUND") {
        Write-Host ("    ⚠ Repo not found (deleted/renamed?): {0} ({1}) — skipping" -f $repoLabel, $ProjectName) -ForegroundColor Yellow
        return @()
      }
      Write-Host ("    ⚠ Error fetching commits for repo {0} ({1}) — skipping" -f $repoLabel, $ProjectName) -ForegroundColor Yellow
      return @()
    }

    $batch = $resp.value
    if ($ToDate) {
      $to = Get-Date $ToDate
      # committer.date reflects "who pushed"
      $batch = $batch | Where-Object { (Get-Date $_.committer.date) -le $to }
    }
    if ($batch) { $results += $batch }

    $skip += $top
    $more = ($resp -and $resp.value -and $resp.value.Count -ge $top)
  } while ($more)

  return $results
}

# ======================
# ===== MAIN FLOW ======
# ======================
if ($OrgUrl -notmatch '^https?://dev\.azure\.com/[^/]+$') {
  throw "Please set a valid Org URL (e.g., https://dev.azure.com/your-org). Current: '$OrgUrl'"
}
if ([string]::IsNullOrWhiteSpace($Pat) -or $Pat -eq "<paste-your-PAT-here>") {
  $Pat = Read-Host -Prompt "Enter Azure DevOps PAT" -MaskInput
  if ([string]::IsNullOrWhiteSpace($Pat)) { throw "PAT is required." }
}

$Headers = New-AuthHeaderFromPat -Token $Pat

# Normalize project filter
$SelectedProjects = @()
if (-not [string]::IsNullOrWhiteSpace($Projects)) {
  $SelectedProjects = $Projects.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

Write-Host "Using Org: $OrgUrl" -ForegroundColor Cyan
Write-Host "FromDate: $FromDate" -ForegroundColor Cyan
if ($ToDate) { Write-Host "ToDate:   $ToDate" -ForegroundColor Cyan }

Write-Host "Validating organization access and PAT..." -ForegroundColor Yellow
Test-OrgAndToken -OrgUrl $OrgUrl -Headers $Headers
Write-Host "Validation OK." -ForegroundColor Green

Write-Host "Fetching projects..." -ForegroundColor Yellow
$allProjects = Get-AdoProjects -OrgUrl $OrgUrl -Headers $Headers
if (-not $allProjects) { throw "No projects found or access denied." }

$targetProjects = if ($SelectedProjects.Count -gt 0) {
  $allProjects | Where-Object { $SelectedProjects -contains $_.name }
} else { $allProjects }

if (-not $targetProjects) {
  throw "The provided Projects filter didn't match any accessible projects. Check names in CONFIG: $Projects"
}

# Collectors
$commitRows     = New-Object System.Collections.Generic.List[object]
$projectIssues  = New-Object System.Collections.Generic.List[object]   # { Project, Status }
$repoIssues     = New-Object System.Collections.Generic.List[object]   # { Project, Repo, Reason }

# Iterate projects/repos/commits
foreach ($proj in $targetProjects) {
  $projName = $proj.name
  Write-Host "Project: $projName" -ForegroundColor Green

  $reposResult = Get-AdoRepos -OrgUrl $OrgUrl -Headers $Headers -ProjectName $projName
  if ($reposResult.Access -ne "OK") {
    $reason = if ($reposResult.Access -eq "ACCESS_DENIED") { "No access" } else { "Repo list error" }
    $projectIssues.Add([pscustomobject]@{ Project = $projName; Status = $reason })
    continue
  }

  $repos = $reposResult.Repos
  if (-not $repos) { continue }

  foreach ($repo in $repos) {
    Write-Host ("  Repo: {0}" -f $repo.name) -ForegroundColor DarkYellow
    $commits = Get-AdoCommits -OrgUrl $OrgUrl -Headers $Headers `
                              -ProjectName $projName -RepoId $repo.id `
                              -FromDate $FromDate -ToDate $ToDate `
                              -RepoName $repo.name
    if (-not $commits) {
      # capture repo-level issues when no commits returned from an error case
      $repoIssues.Add([pscustomobject]@{ Project = $projName; Repo = $repo.name; Reason = "Forbidden/NotFound/Other" })
      continue
    }

    foreach ($c in $commits) {
      $commitRows.Add([pscustomobject]@{
        Project          = $projName
        Repository       = $repo.name
        CommitId         = $c.commitId
        AuthorName       = $c.author.name
        AuthorEmail      = $c.author.email
        AuthorDate       = $c.author.date
        CommitterName    = $c.committer.name
        CommitterEmail   = $c.committer.email
        CommitterDate    = $c.committer.date
        Comment          = $c.comment
        Url              = $c.url
      })
    }
  }
}

# ======================
# ======= OUTPUTS ======
# ======================

# Ensure output directory exists
if (-not (Test-Path $OutDir)) { 
    New-Item -ItemType Directory -Path $OutDir | Out-Null 
}
$ts = Get-Date -Format "yyyyMMdd_HHmmss"

# Build unique committers org-wide (deduped)
$orgCommitters = $commitRows |
  Where-Object { $_.CommitterEmail -or $_.CommitterName } |
  Group-Object CommitterEmail, CommitterName |
  ForEach-Object {
    [pscustomobject]@{
      CommitterName  = $_.Group[0].CommitterName
      CommitterEmail = $_.Group[0].CommitterEmail
      TotalCommits   = $_.Count
    }
  } |
  Sort-Object -Property TotalCommits -Descending

# Transform into two-column proper table
$formatted = $orgCommitters | ForEach-Object {
    # Build "Name <email>" or just email if name empty
    $label = if ([string]::IsNullOrWhiteSpace($_.CommitterName)) { 
        $_.CommitterEmail 
    } else { 
        "{0} <{1}>" -f $_.CommitterName, $_.CommitterEmail 
    }

    [pscustomobject]@{
        "NameOrEmail"  = $label
        "TotalCommits" = $_.TotalCommits
    }
}

# Export
$csvPath = Join-Path $OutDir ("ado_committers_clean_{0}.csv" -f $ts)
$formatted | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# Total count
$uniqueCount = ($formatted | Measure-Object).Count

# Console output
Write-Host ""
Write-Host "===============================" -ForegroundColor Cyan
Write-Host "Total Unique Committers: $uniqueCount" -ForegroundColor Cyan
Write-Host "CSV Output: $csvPath" -ForegroundColor Green
Write-Host ""
Write-Host "Top committers preview:" -ForegroundColor Yellow
$formatted | Select-Object -First 15 | Format-Table -AutoSize
