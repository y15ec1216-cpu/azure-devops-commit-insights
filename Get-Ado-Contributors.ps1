<# ======================================================================
  Get-Ado-Contributors.ps1
  Extract commit authors (contributors) from Azure DevOps across
  selected projects/repos for a date range. Exports:
    1) All commits CSV
    2) Unique contributors CSV (AuthorName/Email + commit counts)

  HOW TO USE:
    1) Edit CONFIG (OrgUrl, Pat, Projects).
    2) Run:  powershell -ExecutionPolicy Bypass -File .\Get-Ado-Contributors.ps1
====================================================================== #>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ======================
# ====== CONFIG ========
# ======================
# Organization URL (REQUIRED)
$OrgUrl = "https://dev.azure.com/Your org here"

# Personal Access Token (REQUIRED) – paste between quotes
# PAT must have scopes: Code (Read) + Project and Team (Read)
$Pat = "PAT Token should be here"

# Specific projects (comma-separated). Defaulted to your request.
# Leave empty "" to scan ALL projects you can access.
$Projects = "Enter the project you want"

# Date window (ISO yyyy-MM-dd)
$FromDate = "2025-10-01"
$ToDate   = "2025-11-01"

# Output directory for CSVs
$OutDir   = "."

# ======================
# ==== END CONFIG ======
# ======================


# ----------------------
# Helpers
# ----------------------
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
      return Invoke-RestMethod -Method GET -Uri $Url -Headers $Headers
    } catch {
      if ($i -ge $MaxRetry - 1) { throw }
      Start-Sleep -Seconds (2 * ($i + 1))
    }
  }
}

# ----------------------
# Validation & inputs
# ----------------------
if ([string]::IsNullOrWhiteSpace($OrgUrl) -or $OrgUrl -notmatch '^https?://') {
  throw "Please set a valid Org URL in CONFIG (e.g., https://dev.azure.com/your-org)."
}

if ([string]::IsNullOrWhiteSpace($Pat) -or $Pat -eq "<paste-your-PAT-here>") {
  # Safe fallback prompt if PAT left blank
  $Pat = Read-Host -Prompt "Enter Azure DevOps PAT" -MaskInput
  if ([string]::IsNullOrWhiteSpace($Pat)) {
    throw "PAT is required. Create one with Code(Read) + Project and Team(Read)."
  }
}

$Headers = New-AuthHeaderFromPat -Token $Pat

# Normalize the project filter (avoid .Count on $null under StrictMode)
$SelectedProjects = @()
if (-not [string]::IsNullOrWhiteSpace($Projects)) {
  $SelectedProjects = $Projects.Split(',') |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ }
}

Write-Host "Using Org: $OrgUrl" -ForegroundColor Cyan
Write-Host "FromDate: $FromDate" -ForegroundColor Cyan
if ($ToDate) { Write-Host "ToDate:   $ToDate" -ForegroundColor Cyan }

# ----------------------
# API wrappers (with paging via headers where applicable)
# ----------------------
function Test-OrgAndToken {
  param(
    [Parameter(Mandatory=$true)][string] $OrgUrl,
    [Parameter(Mandatory=$true)][hashtable] $Headers
  )
  $url = "$OrgUrl/_apis/projects?`$top=1&api-version=7.1-preview.4"
  $null = Invoke-AdoGet -Url $url -Headers $Headers
}

function Get-AdoProjects {
  param(
    [Parameter(Mandatory=$true)][string]    $OrgUrl,
    [Parameter(Mandatory=$true)][hashtable] $Headers
  )
  $apiVer = "7.1-preview.4"
  $all = @()
  $cont = $null

  do {
    $url = if ($cont) {
      "$OrgUrl/_apis/projects?continuationToken=$([uri]::EscapeDataString($cont))&api-version=$apiVer"
    } else {
      "$OrgUrl/_apis/projects?api-version=$apiVer"
    }

    # Use IWR to access headers (x-ms-continuationtoken)
    $resp  = Invoke-WebRequest -Method GET -Uri $url -Headers $Headers
    $json  = $resp.Content | ConvertFrom-Json
    if ($json.value) { $all += $json.value }
    $cont = $resp.Headers['x-ms-continuationtoken']
  } while ($cont)

  return $all
}

function Get-AdoRepos {
  param(
    [Parameter(Mandatory=$true)][string]    $OrgUrl,
    [Parameter(Mandatory=$true)][hashtable] $Headers,
    [Parameter(Mandatory=$true)][string]    $ProjectName
  )
  $apiVer = "7.1-preview.1"
  $all = @()
  $cont = $null

  do {
    $url = if ($cont) {
      "$OrgUrl/$($ProjectName)/_apis/git/repositories?continuationToken=$([uri]::EscapeDataString($cont))&api-version=$apiVer"
    } else {
      "$OrgUrl/$($ProjectName)/_apis/git/repositories?api-version=$apiVer"
    }

    $resp = Invoke-WebRequest -Method GET -Uri $url -Headers $Headers
    $json = $resp.Content | ConvertFrom-Json
    if ($json.value) { $all += $json.value }
    $cont = $resp.Headers['x-ms-continuationtoken']
  } while ($cont)

  return $all
}

function Get-AdoCommits {
  param(
    [Parameter(Mandatory=$true)][string]    $OrgUrl,
    [Parameter(Mandatory=$true)][hashtable] $Headers,
    [Parameter(Mandatory=$true)][string]    $ProjectName,
    [Parameter(Mandatory=$true)][string]    $RepoId,
    [Parameter(Mandatory=$true)][string]    $FromDate,
    [string] $ToDate
  )
  $apiVer = "7.1-preview.1"
  $top  = 200
  $skip = 0
  $results = @()

  do {
    $url = "$OrgUrl/$($ProjectName)/_apis/git/repositories/$RepoId/commits" +
           "?searchCriteria.fromDate=$([uri]::EscapeDataString($FromDate))" +
           "&`$top=$top&`$skip=$skip&api-version=$apiVer"

    $resp = Invoke-AdoGet -Url $url -Headers $Headers
    $batch = $resp.value

    if ($ToDate) {
      $to = Get-Date $ToDate
      $batch = $batch | Where-Object { (Get-Date $_.author.date) -le $to }
    }

    $results += $batch
    $skip += $top
    $more = ($resp.count -and ($resp.count -ge $top))
  } while ($more)

  return $results
}

# ----------------------
# Validate and fetch projects
# ----------------------
Write-Host "Validating organization access and PAT..." -ForegroundColor Yellow
Test-OrgAndToken -OrgUrl $OrgUrl -Headers $Headers
Write-Host "Validation OK." -ForegroundColor Green

Write-Host "Fetching projects..." -ForegroundColor Yellow
$allProjects = Get-AdoProjects -OrgUrl $OrgUrl -Headers $Headers
if (-not $allProjects) { throw "No projects found or access denied." }

# Guarded project selection (no .Count on null)
if (-not [string]::IsNullOrWhiteSpace($Projects)) {
  $targetProjects = $allProjects | Where-Object { $SelectedProjects -contains $_.name }
  if (-not $targetProjects) {
    throw "The provided Projects filter didn't match any accessible projects. Check names in CONFIG: $Projects"
  }
} else {
  $targetProjects = $allProjects
}

# ----------------------
# Iterate repos/commits
# ----------------------
$commitRows = New-Object System.Collections.Generic.List[object]

foreach ($proj in $targetProjects) {
  $projName = $proj.name
  Write-Host "Project: $projName" -ForegroundColor Green

  $repos = Get-AdoRepos -OrgUrl $OrgUrl -Headers $Headers -ProjectName $projName
  if (-not $repos) { continue }

  foreach ($repo in $repos) {
    Write-Host ("  Repo: {0}" -f $repo.name) -ForegroundColor DarkYellow
    $commits = Get-AdoCommits -OrgUrl $OrgUrl -Headers $Headers `
                              -ProjectName $projName -RepoId $repo.id `
                              -FromDate $FromDate -ToDate $ToDate
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

# ----------------------
# Outputs
# ----------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$allCommitsCsv   = Join-Path $OutDir "ado_commits_$ts.csv"
$contributorsCsv = Join-Path $OutDir "ado_unique_contributors_$ts.csv"

$commitRows | Export-Csv -Path $allCommitsCsv -NoTypeInformation -Encoding UTF8

# ===== Derived datasets =====
# 1) Authors (who wrote the changes) — per Project & Repo
$contributors = $commitRows |
  Where-Object { $_.AuthorEmail -or $_.AuthorName } |
  Group-Object Project, Repository, AuthorEmail, AuthorName |
  ForEach-Object {
    [pscustomobject]@{
      Project      = $_.Group[0].Project
      Repository   = $_.Group[0].Repository
      AuthorName   = $_.Group[0].AuthorName
      AuthorEmail  = $_.Group[0].AuthorEmail
      CommitsCount = $_.Count
    }
  } |
  Sort-Object -Property Project, Repository, CommitsCount -Descending

$contributors | Export-Csv -Path $contributorsCsv -NoTypeInformation -Encoding UTF8

# 2) Committers (who pushed into the repo) — per Project & Repo
$committersRepo = $commitRows |
  Where-Object { $_.CommitterEmail -or $_.CommitterName } |
  Group-Object Project, Repository, CommitterEmail, CommitterName |
  ForEach-Object {
    [pscustomobject]@{
      Project        = $_.Group[0].Project
      Repository     = $_.Group[0].Repository
      CommitterName  = $_.Group[0].CommitterName
      CommitterEmail = $_.Group[0].CommitterEmail
      CommitsCount   = $_.Count
    }
  } |
  Sort-Object -Property Project, Repository, CommitsCount -Descending

$committersCsv = Join-Path $OutDir "ado_unique_committers_$ts.csv"
$committersRepo | Export-Csv -Path $committersCsv -NoTypeInformation -Encoding UTF8

# 3) Authors by Project (across all repos)
$contributorsByProject = $commitRows |
  Where-Object { $_.AuthorEmail -or $_.AuthorName } |
  Group-Object Project, AuthorEmail, AuthorName |
  ForEach-Object {
    [pscustomobject]@{
      Project     = $_.Group[0].Project
      AuthorName  = $_.Group[0].AuthorName
      AuthorEmail = $_.Group[0].AuthorEmail
      Commits     = $_.Count
    }
  } |
  Sort-Object -Property Project, AuthorName

$contributorsByProjectCsv = Join-Path $OutDir "ado_contributors_by_project_$ts.csv"
$contributorsByProject | Export-Csv -Path $contributorsByProjectCsv -NoTypeInformation -Encoding UTF8

# 4) Committers by Project (across all repos)
$committersByProject = $commitRows |
  Where-Object { $_.CommitterEmail -or $_.CommitterName } |
  Group-Object Project, CommitterEmail, CommitterName |
  ForEach-Object {
    [pscustomobject]@{
      Project        = $_.Group[0].Project
      CommitterName  = $_.Group[0].CommitterName
      CommitterEmail = $_.Group[0].CommitterEmail
      Commits        = $_.Count
    }
  } |
  Sort-Object -Property Project, CommitterName

$committersByProjectCsv = Join-Path $OutDir "ado_committers_by_project_$ts.csv"
$committersByProject | Export-Csv -Path $committersByProjectCsv -NoTypeInformation -Encoding UTF8

# 5) Authors org-wide (deduped across all projects/repos)
$orgContributors = $commitRows |
  Where-Object { $_.AuthorEmail -or $_.AuthorName } |
  Group-Object AuthorEmail, AuthorName |
  ForEach-Object {
    [pscustomobject]@{
      AuthorName  = $_.Group[0].AuthorName
      AuthorEmail = $_.Group[0].AuthorEmail
      Commits     = $_.Count
    }
  } |
  Sort-Object -Property AuthorName

$orgContributorsCsv = Join-Path $OutDir "ado_contributors_org_unique_$ts.csv"
$orgContributors | Export-Csv -Path $orgContributorsCsv -NoTypeInformation -Encoding UTF8

# 6) Committers org-wide (deduped across all projects/repos)
$orgCommitters = $commitRows |
  Where-Object { $_.CommitterEmail -or $_.CommitterName } |
  Group-Object CommitterEmail, CommitterName |
  ForEach-Object {
    [pscustomobject]@{
      CommitterName  = $_.Group[0].CommitterName
      CommitterEmail = $_.Group[0].CommitterEmail
      Commits        = $_.Count
    }
  } |
  Sort-Object -Property CommitterName

$orgCommittersCsv = Join-Path $OutDir "ado_committers_org_unique_$ts.csv"
$orgCommitters | Export-Csv -Path $orgCommittersCsv -NoTypeInformation -Encoding UTF8

Write-Host "" 
Write-Host "DONE ✅" -ForegroundColor Cyan
Write-Host "All commits CSV:               $allCommitsCsv"
Write-Host "Unique contributors (authors): $contributorsCsv"
Write-Host "Unique committers (pushers):  $committersCsv"
Write-Host "Contributors by project:      $contributorsByProjectCsv"
Write-Host "Committers by project:        $committersByProjectCsv"
Write-Host "Org contributors (authors):   $orgContributorsCsv"
Write-Host "Org committers (pushers):     $orgCommittersCsv"

# Console summaries
$summaryAuthors = $contributors |
  Group-Object Project, Repository |
  ForEach-Object {
    $proj = $_.Group[0].Project
    $repo = $_.Group[0].Repository
    $totalCommits = ($commitRows | Where-Object { $_.Project -eq $proj -and $_.Repository -eq $repo }).Count
    [pscustomobject]@{
      Project       = $proj
      Repository    = $repo
      Contributors  = $_.Count
      TotalCommits  = $totalCommits
    }
  } | Sort-Object -Property Project, Repository

$summaryCommitters = $committersRepo |
  Group-Object Project, Repository |
  ForEach-Object {
    $proj = $_.Group[0].Project
    $repo = $_.Group[0].Repository
    $totalCommits = ($commitRows | Where-Object { $_.Project -eq $proj -and $_.Repository -eq $repo }).Count
    [pscustomobject]@{
      Project       = $proj
      Repository    = $repo
      Committers    = $_.Count
      TotalCommits  = $totalCommits
    }
  } | Sort-Object -Property Project, Repository

Write-Host "`nAuthors (per repo)" -ForegroundColor Yellow
$summaryAuthors | Format-Table -AutoSize

Write-Host "`nCommitters (per repo)" -ForegroundColor Yellow
$summaryCommitters | Format-Table -AutoSize
