# Azure DevOps Commit Insights 🧠
> PowerShell tool to extract commit authors, committers, and activity insights from Azure DevOps projects — generate detailed CSV reports for analysis and governance.

---

## 🚀 Overview
**Azure DevOps Commit Insights** is a lightweight PowerShell script that analyzes commit activity across your Azure DevOps organization.

It connects directly to Azure DevOps REST APIs to fetch commit history from all (or selected) projects and repositories within a given date range.  
You get clear, exportable CSV reports showing:
- Who authored commits (contributors)
- Who pushed changes (committers)
- Total commits by repo, project, and organization
- Insights for auditing, analytics, and performance tracking

Ideal for:
- DevOps teams auditing code contributions  
- Engineering managers tracking activity  
- Cloud architects performing governance and compliance checks  

---

## 🛠️ Features
✅ Extract commits from **multiple projects** or all projects you have access to  
✅ Filter by date range (`FromDate` / `ToDate`)  
✅ Export **all commits**, **unique authors**, and **unique committers** to CSV  
✅ Get reports **by repository**, **by project**, and **organization-wide**  
✅ Uses Azure DevOps REST API with built-in retry and paging  
✅ No dependencies beyond PowerShell  

---

## ⚙️ Setup

### 1️⃣ Requirements
- Windows / Linux / macOS with **PowerShell 7+**
- An **Azure DevOps Personal Access Token (PAT)** with:
  - `Code (Read)`
  - `Project and Team (Read)`

### 2️⃣ Configuration
Edit the top section in `Get-Ado-Contributors.ps1`:

```powershell
# Organization URL
$OrgUrl = "https://dev.azure.com/<your-org>"

# Personal Access Token (PAT)
$Pat = "<your-PAT-token>"

# Specific projects (comma-separated)
$Projects = "Cloud and Data Competence Center"

# Date range
$FromDate = "2025-10-01"
$ToDate   = "2025-11-01"

# Output folder
$OutDir   = "."
