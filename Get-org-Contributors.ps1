<# ======================================================================
  Get-Ado-Committers-AllOrgs.ps1
  Purpose: List unique committers (who pushed) across ALL organizations,
           projects, and repos visible to the provided PAT, for the last 6 months.

  Behavior:
    • Uses a PAT embedded directly in the script
    • Auto-discovers ALL organizations for the PAT user
    • Skips orgs/projects/repos without access and logs a warning
    • Exports:
        1) All commits across all orgs (CSV)
        2) Unique committers across all orgs (CSV)
        3) Per-org unique committer counts (CSV)
    • Prints a clear per-org summary + grand total
====================================================================== #>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ======================
# ====== CONFIG ========
# ======================
# Paste your PAT here (with Org scope: All accessible orgs; Scopes: Code Read + Project and Team Read)
$Pat = "Your pat here"

# Date window (last 6 months by default)
$FromDate = (Get-Date).AddMonths(-6).ToString('yyyy-MM-dd')
$ToDate   = (Get-Date).ToString('yyyy-MM-dd')

# Output directory
$OutDir   = "."

# ======================
# ==== FUNCTIONS =======
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
      if ($_.Exception.PSObject.Properties.Name -contains 'Response') {
        $code = $_.Exception.Response.StatusCode.Value__
        if ($code -eq 401 -or $code -eq 403) { throw "ACCESS_DENIED" }
      }
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

# --- Discover accessible orgs for the PAT user ---
function Get-PatMemberId {
  param([hashtable]$Headers)
  $url = "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1-preview.3"
  (Invoke-RestMethod -Method GET -Uri $url -Headers $Headers).id
}

function Get-AccessibleOrganizations {
  param([hashtable]$Headers)
  $memberId = Get-PatMemberId -Headers $Headers
  $url = "https://app.vssps.visualstudio.com/_apis/accounts?memberId=$memberId&api-version=7.1-preview.1"
  $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $Headers
  $resp.value | ForEach-Object { $_.AccountUri.TrimEnd('/') } | Sort-Object -Unique
}

# --- Per-org helpers ---
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
    # use IWR to read continuation header
    $resp = Invoke-WebRequest -Method GET -Uri $url -Headers $Headers -ErrorAction SilentlyContinue
    if (-not $resp -or $resp.StatusCode -ne 200) {
      Write-Warning "  ⚠ Unable to list projects for $OrgUrl (status: $($resp.StatusCode))"
      break
    }
    $json = $resp.Content | ConvertFrom-Json
    if ($json.value) { $all += $json.value }
    $cont = $resp.Headers['x-ms-continuationtoken']
  } while ($cont)
  return $all
}

function Get-AdoRepos {
  param([string]$OrgUrl, [hashtable]$Headers, [string]$ProjectName)
  $apiVer = "7.1-preview.1"
  try {
    $url = "$OrgUrl/$ProjectName/_apis/git/repositories?api-version=$apiVer"
    (Invoke-RestMethod -Method GET -Uri $url -Headers $Headers -ErrorAction Stop).value
  } catch {
    if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response.StatusCode.Value__ -eq 403) {
      Write-Host "  ⚠ No access to project: $ProjectName — skipping" -ForegroundColor Yellow
      return @()
    }
    Write-Host "  ⚠ Error listing repos for project: $ProjectName — skipping" -ForegroundColor Yellow
    return @()
  }
}

function Get-AdoCommits {
  param(
    [string]$OrgUrl,
    [hashtable]$Headers,
    [string]$ProjectName,
    [string]$RepoId,
    [string]$FromDate,
    [string]$ToDate
  )
  $apiVer = "7.1-preview.1"
  $top  = 200
  $skip = 0
  $results = @()
  $resp = $null

  do {
    $url = "$OrgUrl/$ProjectName/_apis/git/repositories/$RepoId/commits" +
           "?searchCriteria.fromDate=$FromDate&`$top=$top&`$skip=$skip&api-version=$apiVer"
    try {
      $resp = Invoke-AdoGet -Url $url -Headers $Headers
    } catch {
      if ($_.Exception -eq "ACCESS_DENIED" -or ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response.StatusCode.Value__ -eq 403)) {
        Write-Host "    ⚠ No access to repo: $RepoId in $ProjectName — skipping" -ForegroundColor Yellow
        return @()
      }
      Write-Host "    ⚠ Error fetching commits for repo $RepoId in $ProjectName — skipping" -ForegroundColor Yellow
      return @()
    }

    if ($null -ne $resp -and $resp.value) {
      $batch = if ($ToDate) {
        $to = Get-Date $ToDate
        $resp.value | Where-Object { (Get-Date $_.committer.date) -le $to }
      } else { $resp.value }
      $results += $batch
    }

    $more = ($null -ne $resp -and $resp.PSObject.Properties.Name -contains 'count' -and $resp.count -ge $top)
    $skip += $top
  } while ($more)

  return $results
}

# ======================
# ===== MAIN FLOW ======
# ======================
if ([string]::IsNullOrWhiteSpace($Pat) -or $Pat -eq "<YOUR_PAT_HERE>") { throw "PAT must be set in the script." }
$Headers = New-AuthHeaderFromPat -Token $Pat

Write-Host "Discovering accessible organizations..." -ForegroundColor Yellow
$OrgUrls = Get-AccessibleOrganizations -Headers $Headers
if (-not $OrgUrls -or $OrgUrls.Count -eq 0) { throw "No accessible organizations found for this PAT." }

$allCommitRows = New-Object System.Collections.Generic.List[object]
$perOrgCounts  = New-Object System.Collections.Generic.List[object]

foreach ($org in $OrgUrls) {
  Write-Host "`n=== Organization: $org ===" -ForegroundColor Cyan
  try {
    Test-OrgAndToken -OrgUrl $org -Headers $Headers
  } catch {
    Write-Host "  ⚠ Cannot access org $org — skipping" -ForegroundColor Yellow
    continue
  }

  $projects = Get-AdoProjects -OrgUrl $org -Headers $Headers
  if (-not $projects) {
    Write-Host "  ⚠ No accessible projects in $org — skipping" -ForegroundColor Yellow
    continue
  }

  $orgCommitRows = New-Object System.Collections.Generic.List[object]

  foreach ($proj in $projects) {
    Write-Host "  Project: $($proj.name)" -ForegroundColor Green
    $repos = Get-AdoRepos -OrgUrl $org -Headers $Headers -ProjectName $proj.name
    if (-not $repos) { continue }

    foreach ($repo in $repos) {
      Write-Host "    Repo: $($repo.name)" -ForegroundColor DarkYellow
      $commits = Get-AdoCommits -OrgUrl $org -Headers $Headers `
                                -ProjectName $proj.name -RepoId $repo.id `
                                -FromDate $FromDate -ToDate $ToDate
      foreach ($c in $commits) {
        $row = [pscustomobject]@{
          Organization   = $org
          Project        = $proj.name
          Repository     = $repo.name
          CommitId       = $c.commitId
          CommitterName  = $c.committer.name
          CommitterEmail = $c.committer.email
          CommitDate     = $c.committer.date
          AuthorName     = $c.author.name
          AuthorEmail    = $c.author.email
        }
        $allCommitRows.Add($row)
        $orgCommitRows.Add($row)
      }
    }
  }

  $orgUniqueCommitters = $orgCommitRows |
    Where-Object { $_.CommitterEmail -or $_.CommitterName } |
    Group-Object CommitterEmail, CommitterName |
    ForEach-Object {
      [pscustomobject]@{
        CommitterName  = $_.Group[0].CommitterName
        CommitterEmail = $_.Group[0].CommitterEmail
        Commits        = $_.Count
      }
    }

  $perOrgCounts.Add([pscustomobject]@{
    Organization      = $org
    UniqueCommitters  = ($orgUniqueCommitters | Measure-Object).Count
    TotalCommits      = $orgCommitRows.Count
  })
}

# ======================
# ====== OUTPUTS =======
# ======================

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$ts = Get-Date -Format "yyyyMMdd_HHmmss"

$allCommitsCsv = Join-Path $OutDir "ado_commits_allorgs_last6m_$ts.csv"
$allCommitRows | Export-Csv -Path $allCommitsCsv -NoTypeInformation -Encoding UTF8

$allOrgCommitters = $allCommitRows |
  Where-Object { $_.CommitterEmail -or $_.CommitterName } |
  Group-Object CommitterEmail, CommitterName |
  ForEach-Object {
    [pscustomobject]@{
      CommitterName  = $_.Group[0].CommitterName
      CommitterEmail = $_.Group[0].CommitterEmail
      Commits        = $_.Count
    }
  } |
  Sort-Object -Property Commits -Descending

$allOrgCommittersCsv = Join-Path $OutDir "ado_committers_allorgs_unique_last6m_$ts.csv"
$allOrgCommitters | Export-Csv -Path $allOrgCommittersCsv -NoTypeInformation -Encoding UTF8

$perOrgCsv = Join-Path $OutDir "ado_committers_by_org_last6m_$ts.csv"
$perOrgCounts | Sort-Object -Property Organization | Export-Csv -Path $perOrgCsv -NoTypeInformation -Encoding UTF8

$uniqueCountAll = ($allOrgCommitters | Measure-Object).Count
Write-Host "`n=====================" -ForegroundColor Cyan
Write-Host "Organizations scanned: $($OrgUrls.Count)" -ForegroundColor Cyan
Write-Host "Total Unique Committers across ALL orgs (Last 6 Months): $uniqueCountAll" -ForegroundColor Cyan
Write-Host "CSV (all commits):     $allCommitsCsv" -ForegroundColor Green
Write-Host "CSV (unique users):    $allOrgCommittersCsv" -ForegroundColor Green
Write-Host "CSV (by org summary):  $perOrgCsv" -ForegroundColor Green

Write-Host "`nCommitters (Name, Email, Commits):" -ForegroundColor Yellow
$allOrgCommitters | Select-Object CommitterName, CommitterEmail, Commits | Format-Table -AutoSize

Write-Host "`nPer-Org Summary:" -ForegroundColor Yellow
$perOrgCounts | Sort-Object -Property Organization | Format-Table -AutoSize
