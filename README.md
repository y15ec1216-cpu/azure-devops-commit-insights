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

▶️ Run the Script
powershell -ExecutionPolicy Bypass -File .\Get-Ado-Contributors.ps1


You’ll see progress in the console, then multiple CSV files generated in your output directory.

📦 Output Files
File Name	Description
ado_commits_<timestamp>.csv	All commit records (authors + committers)
ado_unique_contributors_<timestamp>.csv	Unique authors and commit counts per repo
ado_unique_committers_<timestamp>.csv	Unique committers and counts per repo
ado_contributors_by_project_<timestamp>.csv	Authors summarized per project
ado_committers_by_project_<timestamp>.csv	Committers summarized per project
ado_contributors_org_unique_<timestamp>.csv	Org-wide deduped authors
ado_committers_org_unique_<timestamp>.csv	Org-wide deduped committers
📊 Example Use Cases

Engineering Metrics: Identify active contributors per repo or team.

Audit & Compliance: Track who’s committing code to sensitive repos.

Performance Reviews: Measure code contribution patterns.

Governance: Validate that service accounts or automation users follow policy.

💡 Example Output

Example contributor summary (CSV sample):

Project	Repository	AuthorName	AuthorEmail	CommitsCount
Cloud and Data Competence Center	api-core	John Doe	john.doe@akzonobel.com
	52
Cloud and Data Competence Center	api-utils	Jane Smith	jane.smith@akzonobel.com
	41
📚 Tech Notes

This script uses the following Azure DevOps REST APIs:

GET _apis/projects

GET _apis/git/repositories

GET _apis/git/repositories/{repoId}/commits

Full API reference: Microsoft Docs – Git Commits API

🧰 Troubleshooting
Issue	Possible Cause	Fix
Invoke-WebRequest / 401 Unauthorized	PAT invalid or expired	Generate a new PAT with Code (Read) + Project and Team (Read)
Empty output CSVs	Wrong project name or no commits in date range	Double-check $Projects and $FromDate / $ToDate
“No projects found or access denied”	Org URL incorrect	Use full format: https://dev.azure.com/<org>
📈 Future Enhancements

Planned features:

📊 Power BI dashboard template for visual analytics

🔄 Auto-scheduled execution (Azure Automation / GitHub Actions)

🌐 HTML report generation

🧮 Extended filtering by branch, committer, or keyword

🤝 Contributing

Pull requests are welcome!
Feel free to open issues or suggestions — contributions that add filters, metrics, or dashboard integrations are highly encouraged.

📜 License

Released under the MIT License
.

👤 Author

Meezan Khan
Cloud Solution Architect | DevOps & Azure Expert
🔗 GitHub
 • LinkedIn

📧 contact@meezankhan.com



---

## 🌟 Optional Add-Ons
You can later enhance this README with:
- **Badges** (from [shields.io](https://shields.io/)) — e.g.  
  ```markdown
  ![PowerShell](https://img.shields.io/badge/PowerShell-7+-blue)
  ![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-REST%20API-blue)
  ![License: MIT](https://img.shields.io/badge/License-MIT-green)


Sample screenshot of the CSV results

Link to blog/tutorial if you post about it
