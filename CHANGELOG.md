# Changelog
## RetailBank EDW Modernization Programme

All notable changes to this project are documented here.

---

## [v1.0.0] — 2026-08-24 🎉 Initial Release

### ✅ Completed
- Full project delivered and version-controlled on GitHub

### 🏗️ SQL Server Implementation
- Reverse-engineered legacy SQL Server architecture
- Documented all 7 source systems and data flows
- Identified and corrected schema design flaws
- Remediated all 5 stored procedures:
  - `usp_LoadCustomerMaster`
  - `usp_LoadCustomerMasterExceptions`
  - `usp_LoadCustomerPortfolio`
  - `usp_LoadCustomerPortfolioExceptions`
  - `usp_LoadPortfolioExceptionReport`
- Implemented configuration-driven column mapping
- Enhanced audit trail and error handling
- End-to-end SQL Server testing completed (Business Date: 2026-01-31)

### ☁️ Azure Databricks Migration
- Designed Bronze → Silver → Gold Delta Lake architecture
- Built and tested 5 PySpark notebooks:
  - `nb_01_CustomerMaster` — 7-source consolidation
  - `nb_02_CustomerMasterExceptions` — Data quality rules
  - `nb_03_CustomerPortfolio` — Portfolio aggregation ($3.26M validated)
  - `nb_04_PortfolioExceptions` — DQ rule enforcement
  - `nb_05_PortfolioExceptionReport` — Executive KPI reporting
- Implemented Delta Lake ACID transactions
- Automated audit logging across all notebooks

### 🔍 Validation & Reconciliation
- Cross-platform reconciliation executed (SQL Server vs Databricks)
- Row count validation: ✅ PASS (19 accounts matched)
- Balance validation: ✅ PASS ($3,261,330.00 matched)
- Exception hash comparison implemented (SHA256)
- Root cause analysis completed for all identified gaps

### 📁 Repository
- 25 project files committed to GitHub
- Professional README added
- Project presentation included (25 slides)

---

## [v1.1.0] — Planned 🗓️

### 🔧 In Progress
- Complete DQ001 rule implementation in `nb_04`
- Re-run cross-platform reconciliation
- Resolve exception count discrepancy (2 HIGH severity)

---

## [v2.0.0] — Planned 🗓️

### 🚀 Production Deployment
- User acceptance testing (UAT)
- Production Databricks environment setup
- Historical data migration
- Parallel run (SQL Server + Databricks)
- Full production cutover

---

*Format based on [Keep a Changelog](https://keepachangelog.com)*
