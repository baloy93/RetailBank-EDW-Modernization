# 🏦 RetailBank EDW Modernization
### SQL Server → Azure Databricks Migration

![Status](https://img.shields.io/badge/Status-Complete-brightgreen)
![Platform](https://img.shields.io/badge/Platform-Azure%20Databricks-orange)
![Language](https://img.shields.io/badge/Language-PySpark%20%7C%20SQL-blue)
![Database](https://img.shields.io/badge/Database-Delta%20Lake-red)

---

## 📌 Project Overview

This project documents the end-to-end migration of **RetailBank's Enterprise Data Warehouse (EDW)** from a legacy **Microsoft SQL Server** batch processing architecture to a modern, cloud-native **Azure Databricks** platform.

The migration consolidates data from **7 independent operational systems** into a single source of truth, enabling automated data quality detection, exception management, and executive reporting.

---

## 🏗️ Architecture

```
7 Source Systems
       │
       ▼
┌─────────────────────────────────────┐
│         SQL Server (Legacy)         │
│   Landing → Integration → Warehouse │
│         5 Stored Procedures         │
└─────────────────────────────────────┘
       │
       │  Migration
       ▼
┌─────────────────────────────────────┐
│       Azure Databricks (Target)     │
│   Bronze → Silver → Gold            │
│         5 PySpark Notebooks         │
│         Delta Lake Tables           │
└─────────────────────────────────────┘
       │
       ▼
  Reporting & Analytics
```

---

## 📂 Repository Structure

```
RetailBank-EDW-Modernization/
│
├── notebooks/                          # Azure Databricks PySpark notebooks
│   ├── nb_01_CustomerMaster.ipynb      # Customer consolidation from 7 sources
│   ├── nb_02_CustomerMasterExceptions.ipynb  # Customer data quality rules
│   ├── nb_03_CustomerPortfolio.ipynb   # Portfolio aggregation & balances
│   ├── nb_04_PortfolioExceptions.ipynb # DQ rule enforcement
│   ├── nb_05_PortfolioExceptionReport.ipynb  # KPI & executive reporting
│   ├── NB_CrossPlatform_Reconciliation.ipynb # SQL Server vs Databricks validation
│   └── NB_Schema_Migration.ipynb       # Schema migration notebook
│
├── SQL SERVER/                         # SQL Server implementation
│   ├── SQL_database_creation_script.sql
│   ├── Warehouse_usp_LoadCustomerMaster_updated.sql
│   ├── Warehouse_usp_LoadCustomerMasterExceptions_updated.sql
│   ├── Warehouse_usp_LoadCustomerPortfolio_updated.sql
│   ├── Warehouse_usp_LoadCustomerPortfolioExceptions_updated.sql
│   ├── Warehouse_usp_LoadPortfolioExceptionReport_updated.sql
│   ├── CAPTURE BASELINE DATA SQL Server.sql
│   └── SQL Server End-to-End Test Script.sql
│
├── Reconciliation/                     # Cross-platform validation results
│   ├── Baseline_CustomerMaster.csv
│   ├── Baseline_CustomerPortfolio.csv
│   ├── Baseline_CustomerPortfolioExceptions.csv
│   └── Baseline_PortfolioExceptionReport.csv
│
└── RetailBank_EDW_Modernization_25slides.pptx  # Project presentation
```

---

## 🔧 Source Systems

| System | Description | Customer ID Field |
|--------|-------------|-------------------|
| **CustomerHub** | CRM system | `CustomerNumber` |
| **DepositPro** | Savings & Current accounts | `CustomerNumber` |
| **LoanSphere** | Loan accounts | `ClientId` |
| **CardMaster** | Credit card accounts | `ClientNumber` |
| **WealthPlus** | Investment accounts | `InvestorId` |
| **MobileWallet** | Mobile banking | `CustomerId` |
| **FXConnect** | Forex trading | `ClientCode` |

---

## 📓 Notebooks

### nb_01 — Customer Master
Consolidates customer identities from all 7 source systems. Applies deduplication using source priority ranking and MERGEs into the `warehouse.customer_master` Delta table.

### nb_02 — Customer Master Exceptions
Validates customer records against defined business rules. Captures data quality issues with severity classification (CRITICAL / HIGH / MEDIUM / LOW).

### nb_03 — Customer Portfolio
Aggregates all customer account holdings across product types. Calculates balances in both original and base currency using exchange rates.

### nb_04 — Portfolio Exceptions
Applies 5 data quality rules (DQ001–DQ005) to portfolio data. Detects violations, assigns severity, calculates SLA due dates, and escalates high-priority exceptions.

### nb_05 — Portfolio Exception Report
Generates 4 executive KPIs:
- Critical Exception Count
- Exception Rate (%)
- Portfolio Health Status
- SLA Compliance (%)

### NB_CrossPlatform_Reconciliation
Validates Databricks output against SQL Server baseline using row counts, aggregate balances, and SHA256 exception hash comparison.

---

## ✅ Reconciliation Results

| Validation Check | Result | Detail |
|-----------------|--------|--------|
| Row Count Match | ✅ PASS | 19 accounts on both platforms |
| Balance Match | ✅ PASS | $3,261,330.00 verified |
| Customer Count | ✅ PASS | 12 customers on both platforms |
| Critical Exceptions | ✅ PASS | 3 on both platforms |
| Exception Count | ⚠️ IN PROGRESS | DQ001 fix scheduled |
| SLA Compliance | ✅ DOCUMENTED | Timing difference accepted |

---

## 🛠️ Technology Stack

| Layer | Technology |
|-------|------------|
| Cloud Platform | Microsoft Azure |
| Processing Engine | Azure Databricks |
| Language | PySpark, Python, SQL |
| Storage Format | Delta Lake |
| Legacy Platform | Microsoft SQL Server |
| Version Control | Git & GitHub |
| Presentation | PowerPoint |

---

## 🚀 Getting Started

### Prerequisites
- Azure Databricks workspace
- SQL Server (for legacy reference)
- Python 3.8+
- PySpark

### Running the Notebooks
Run notebooks in the following order to replicate the full ETL pipeline:

```
1. nb_01_CustomerMaster
2. nb_02_CustomerMasterExceptions
3. nb_03_CustomerPortfolio
4. nb_04_PortfolioExceptions
5. nb_05_PortfolioExceptionReport
```

### Running SQL Server Procedures
```sql
EXEC Warehouse.usp_LoadCustomerMaster @BusinessDate = '2026-01-31'
EXEC Warehouse.usp_LoadCustomerMasterExceptions @BusinessDate = '2026-01-31'
EXEC Warehouse.usp_LoadCustomerPortfolio @BusinessDate = '2026-01-31'
EXEC Warehouse.usp_LoadCustomerPortfolioExceptions @BusinessDate = '2026-01-31'
EXEC Warehouse.usp_LoadPortfolioExceptionReport @BusinessDate = '2026-01-31'
```

---

## 📊 Key Results

- **25 files** committed and version controlled
- **7 source systems** consolidated into 1 warehouse
- **5 stored procedures** modernized and migrated
- **5 Databricks notebooks** built and validated
- **$3.26M** portfolio balance verified across platforms
- **20 files** successfully pushed to GitHub

---

## 👤 Author

**baloy93**
Data Engineering | Azure Databricks | SQL Server Migration

---

## 📄 License

This project is for educational and professional assessment purposes.

---

*RetailBank EDW Modernization Programme | August 2026*
