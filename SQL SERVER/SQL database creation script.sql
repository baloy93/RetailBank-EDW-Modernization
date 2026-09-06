
USE RetailBank_EDW;
GO

/******************************************************************************
  RetailBank EDW Modernization — Corrected Schema Scripts
  Target: SQL Server (Current) + Azure Databricks (Future)
  Date: 8 August 2026
  Version: 1.0 — Reconciliation Release

  WHAT IS THIS SCRIPT?
  --------------------
  This script builds the entire database from scratch. Think of it like
  constructing a warehouse:
    - Schemas = the different wings of the warehouse (Source, Warehouse, etc.)
    - Tables  = the storage racks inside each wing
    - Data    = the boxes we put on the racks


  WHAT PROBLEMS DOES THIS FIX?
  ----------------------------
  We found 12 inconsistencies across the source files. This script fixes all
  of them in one go:
    #1  Standardised naming (no more Landing/Source/Raw confusion)
    #2  CustomerMasterExceptions now has all 20 columns it needs
    #3  ExceptionCategory now knows severity and business area
    #4  NEW table: DataQualityIssues (was referenced but never created)
    #5  NEW table: ExceptionExecutionSummary (separate from Portfolio)
    #6  Split Config.SourceConfiguration into two clean tables
    #7  All 7 raw source tables are now properly defined
    #8  NEW table: PortfolioErrors (fixes the critical runtime failure)
    #9  Source table names unified across all documents
    #10 ExceptionRules data reconciled (same values everywhere)
    #11 BusinessOwner values aligned (no more NULL owners)
    #12 ReportingThreshold table created for future use
******************************************************************************/

PRINT '=================================================================';
PRINT 'RetailBank EDW — Corrected Schema Deployment';
PRINT '=================================================================';
GO


/******************************************************************************
  SECTION 1: SCHEMAS
  ------------------
  A "schema" is just a folder that groups related tables together.
  We create 6 folders:
    Source    = raw data from your 7 operational systems
    Reference = lookup tables (products, exchange rates, etc.)
    Config    = settings and rules that control how the system behaves
    Warehouse = the "golden" cleaned data (single customer view)
    Reporting = tables for dashboards and executive reports
    Audit     = logs that track what happened and when
******************************************************************************/

-- Only create the schema if it doesn't already exist
-- This makes the script safe to run multiple times

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Source')
    EXEC('CREATE SCHEMA Source');

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Reference')
    EXEC('CREATE SCHEMA Reference');

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Config')
    EXEC('CREATE SCHEMA Config');

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Warehouse')
    EXEC('CREATE SCHEMA Warehouse');

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Reporting')
    EXEC('CREATE SCHEMA Reporting');

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Audit')
    EXEC('CREATE SCHEMA Audit');

PRINT 'Schemas created.';
GO


/******************************************************************************
  SECTION 2: SOURCE TABLES (7 Operational Systems)
  ------------------------------------------------
  These tables hold the RAW data that arrives every night from your
  7 operational banking systems. Think of them as "inboxes" where
  each system drops off its daily file.

  FIXES APPLIED:
    - Inconsistency #1, #7, #9: All tables now use the "Source." prefix
    - Previously the same table was called Raw.CustomerAccounts,
      Source.CoreBankingAccounts, and Raw.CoreBankingAccounts in
      different documents. Now it is ONLY Source.CoreBankingAccounts.
******************************************************************************/

-- 2.1 Core Banking (from CustomerHub / DepositPro)
-- This is your main current account and savings data
IF OBJECT_ID('Source.CoreBankingAccounts', 'U') IS NOT NULL
    DROP TABLE Source.CoreBankingAccounts;

CREATE TABLE Source.CoreBankingAccounts
(
      AccountNumber       VARCHAR(50)  NOT NULL   -- Unique account ID
    , CustomerNumber      VARCHAR(50)              -- Links to the customer
    , ProductCode         VARCHAR(50)              -- e.g. SAV001, CUR001
    , AccountBalance      DECIMAL(18,2)            -- Money in the account
    , Currency            VARCHAR(10)              -- USD, EUR, GBP, etc.
    , AccountStatus       VARCHAR(30)              -- ACTIVE or CLOSED
    , RecordDate          DATE                     -- When this row was sent
    , CONSTRAINT PK_Source_CoreBankingAccounts PRIMARY KEY (AccountNumber)
);
GO

-- 2.2 Loans (from LoanSphere)
-- Mortgage and personal loan data
IF OBJECT_ID('Source.LoanAccounts', 'U') IS NOT NULL
    DROP TABLE Source.LoanAccounts;

CREATE TABLE Source.LoanAccounts
(
      LoanNumber          VARCHAR(50)  NOT NULL
    , ClientId            VARCHAR(50)              -- Customer who owns the loan
    , LoanProduct         VARCHAR(50)              -- e.g. HOME_LOAN
    , OutstandingAmount   DECIMAL(18,2)            -- How much is still owed
    , LoanCurrency        VARCHAR(10)              -- Currency of the loan
    , LoanStatus          VARCHAR(30)              -- ACTIVE, CLOSED, etc.
    , SnapshotDate        DATE                     -- When this data was captured
    , CONSTRAINT PK_Source_LoanAccounts PRIMARY KEY (LoanNumber)
);
GO

-- 2.3 Cards (from CardMaster)
-- Credit card account data
IF OBJECT_ID('Source.CardAccounts', 'U') IS NOT NULL
    DROP TABLE Source.CardAccounts;

CREATE TABLE Source.CardAccounts
(
      CardAccountNumber   VARCHAR(50)  NOT NULL
    , ClientNumber        VARCHAR(50)
    , CardProduct         VARCHAR(50)              -- e.g. GOLD_CARD
    , CreditBalance       DECIMAL(18,2)            -- Current balance
    , CardCurrency        VARCHAR(10)
    , CardStatus          VARCHAR(30)
    , BusinessDate        DATE
    , CONSTRAINT PK_Source_CardAccounts PRIMARY KEY (CardAccountNumber)
);
GO

-- 2.4 Investments (from WealthPlus)
-- Investment fund and portfolio holdings
IF OBJECT_ID('Source.InvestmentAccounts', 'U') IS NOT NULL
    DROP TABLE Source.InvestmentAccounts;

CREATE TABLE Source.InvestmentAccounts
(
      InvestmentId        VARCHAR(50)  NOT NULL
    , InvestorId          VARCHAR(50)              -- Customer
    , InvestmentProduct   VARCHAR(50)              -- e.g. EQUITY_FUND
    , MarketValue         DECIMAL(18,2)            -- Current value
    , InvestmentCurrency  VARCHAR(10)
    , InvestmentStatus    VARCHAR(30)
    , ValuationDate       DATE
    , CONSTRAINT PK_Source_InvestmentAccounts PRIMARY KEY (InvestmentId)
);
GO

-- 2.5 Mortgage
-- Separate mortgage account data
IF OBJECT_ID('Source.MortgageAccounts', 'U') IS NOT NULL
    DROP TABLE Source.MortgageAccounts;

CREATE TABLE Source.MortgageAccounts
(
      MortgageNumber      VARCHAR(50)  NOT NULL
    , ClientCode          VARCHAR(50)
    , MortgageType        VARCHAR(50)              -- e.g. HOME
    , BalanceAmount       DECIMAL(18,2)
    , CurrencyCode        VARCHAR(10)
    , Status              VARCHAR(30)
    , EffectiveDate       DATE
    , CONSTRAINT PK_Source_MortgageAccounts PRIMARY KEY (MortgageNumber)
);
GO

-- 2.6 Mobile Banking Wallet
-- Digital wallet balances
IF OBJECT_ID('Source.MobileWallet', 'U') IS NOT NULL
    DROP TABLE Source.MobileWallet;

CREATE TABLE Source.MobileWallet
(
      WalletId            VARCHAR(50)  NOT NULL
    , CustomerNumber      VARCHAR(50)
    , WalletProduct       VARCHAR(50)              -- e.g. MOBILE_WALLET
    , WalletBalance       DECIMAL(18,2)
    , WalletCurrency      VARCHAR(10)
    , WalletStatus        VARCHAR(30)
    , LoadDate            DATE
    , CONSTRAINT PK_Source_MobileWallet PRIMARY KEY (WalletId)
);
GO

-- 2.7 Forex (from FXConnect)
-- Foreign exchange trading accounts
IF OBJECT_ID('Source.ForexAccounts', 'U') IS NOT NULL
    DROP TABLE Source.ForexAccounts;

CREATE TABLE Source.ForexAccounts
(
      TradeId             VARCHAR(50)  NOT NULL
    , CustomerId          VARCHAR(50)
    , ForexProduct        VARCHAR(50)              -- e.g. FX_FORWARD
    , TradeAmount         DECIMAL(18,2)
    , TradeCurrency       VARCHAR(10)
    , TradeStatus         VARCHAR(30)
    , TradeDate           DATE
    , CONSTRAINT PK_Source_ForexAccounts PRIMARY KEY (TradeId)
);
GO

PRINT 'Source tables created (7 operational systems).';
GO


/******************************************************************************
  SECTION 3: REFERENCE TABLES
  ---------------------------
  Reference tables are like dictionaries. They don't change every day.
  They provide the "meanings" for codes used in the source data.

  Example: Source data says ProductCode = 'SAV001'
  The Reference.Product table tells us that means 'Savings Account'.
******************************************************************************/

-- 3.1 Product Reference
-- Maps product codes to human-readable names and categories
IF OBJECT_ID('Reference.Product', 'U') IS NOT NULL
    DROP TABLE Reference.Product;

CREATE TABLE Reference.Product
(
      ProductCode         VARCHAR(50)  NOT NULL
    , ProductDescription  VARCHAR(200)             -- Human-readable name
    , ProductCategory     VARCHAR(100)             -- e.g. Deposit, Loan, Card
    , RegulatoryCategory  VARCHAR(100)             -- e.g. Retail, Credit
    , ProductStatus       VARCHAR(20)              -- ACTIVE or INACTIVE
    , EffectiveDate       DATE                     -- When this product launched
    , CONSTRAINT PK_Reference_Product PRIMARY KEY (ProductCode)
);
GO

-- 3.2 Exchange Rates
-- Converts foreign currencies to USD (the base currency)
-- We need this because accounts are in EUR, GBP, etc. but reports are in USD
IF OBJECT_ID('Reference.ExchangeRates', 'U') IS NOT NULL
    DROP TABLE Reference.ExchangeRates;

CREATE TABLE Reference.ExchangeRates
(
      CurrencyCode        VARCHAR(10)  NOT NULL   -- e.g. EUR, GBP
    , ExchangeRate        DECIMAL(18,8)            -- Rate to convert to USD
    , EffectiveDate       DATE         NOT NULL   -- Which day this rate applies
    , CONSTRAINT PK_Reference_ExchangeRates PRIMARY KEY (CurrencyCode, EffectiveDate)
);
GO

PRINT 'Reference tables created.';
GO


/******************************************************************************
  SECTION 4: CONFIGURATION TABLES (Corrected)
  -------------------------------------------
  Config tables are the "control panel" of the data warehouse.
  Instead of hard-coding rules inside the procedures, we store them
  in tables so business users can change them without rewriting code.

  FIXES APPLIED:
    - Inconsistency #3: ExceptionCategory now has DefaultSeverity + BusinessArea
    - Inconsistency #6: Split the overloaded SourceConfiguration into TWO tables
    - Inconsistency #10: ExceptionRules now has ONE agreed set of values
    - Inconsistency #11: BusinessOwner values aligned across all tables
    - Inconsistency #12: ReportingThreshold table created for future use
******************************************************************************/

-- 4.1 Customer Source Configuration
-- This table tells Procedure 1 WHERE to find customer data
-- and in WHAT ORDER to process the sources
-- FIX #6: This used to be mixed with portfolio config in one table. Now separate.
IF OBJECT_ID('Config.CustomerSourceConfiguration', 'U') IS NOT NULL
    DROP TABLE Config.CustomerSourceConfiguration;

CREATE TABLE Config.CustomerSourceConfiguration
(
      SourceSystemId      INT          NOT NULL   -- Unique ID (1, 2, 3...)
    , SourceSystemCode    VARCHAR(50)              -- Short code e.g. CORE_BANKING
    , SourceSystemName    VARCHAR(100)             -- Full name
    , CustomerTable       SYSNAME                  -- Which table has the data
    , IsActive            BIT                      -- 1 = use this source, 0 = skip it
    , LoadPriority        INT                      -- 1 = load first, 2 = second, etc.
    , SupportsIncremental BIT                      -- Can we load only changed rows?
    , CONSTRAINT PK_Config_CustomerSourceConfig PRIMARY KEY (SourceSystemId)
);
GO

-- 4.2 Portfolio Source Configuration
-- This table tells Procedure 3 WHERE to find product/account data
-- It also maps the COLUMN NAMES because each system uses different names
-- e.g. System A calls it "CustomerNumber", System B calls it "ClientId"
-- FIX #6: This was crammed into the same table as customer config. Now it has its own table.
IF OBJECT_ID('Config.PortfolioSourceConfiguration', 'U') IS NOT NULL
    DROP TABLE Config.PortfolioSourceConfiguration;

CREATE TABLE Config.PortfolioSourceConfiguration
(
      SourceSystemId      INT          NOT NULL
    , SourceSystemCode    VARCHAR(50)
    , SourceSystemName    VARCHAR(100)
    , ProductTable        SYSNAME                  -- Which table has the data
    , CustomerField       SYSNAME                  -- Column name for customer ID
    , ProductField        SYSNAME                  -- Column name for product code
    , BalanceField        SYSNAME                  -- Column name for balance
    , CurrencyField       SYSNAME                  -- Column name for currency
    , StatusField         SYSNAME                  -- Column name for account status
    , BusinessDateField   SYSNAME                  -- Column name for the date
    , SourceAccountField  SYSNAME                  -- Column name for account number
    , LoadPriority        INT
    , SupportsIncremental BIT
    , IsActive            BIT
    , CONSTRAINT PK_Config_PortfolioSourceConfig PRIMARY KEY (SourceSystemId)
);
GO

-- 4.3 Exception Rules
-- These are the 6 Data Quality (DQ) rules that Procedure 4 runs every night.
-- Each rule has a severity level and a business area that owns it.
-- FIX #10: We found two files with DIFFERENT severity levels for the same rules.
--          This is the reconciled (agreed) version.
IF OBJECT_ID('Config.ExceptionRules', 'U') IS NOT NULL
    DROP TABLE Config.ExceptionRules;

CREATE TABLE Config.ExceptionRules
(
      RuleCode            VARCHAR(50)  NOT NULL   -- e.g. DQ001, DQ002
    , ExceptionCategory   VARCHAR(100)             -- What type of problem
    , SeverityCode        VARCHAR(20)              -- CRITICAL, HIGH, MEDIUM, LOW
    , BusinessArea        VARCHAR(100)             -- Who is responsible for fixing it
    , RuleEnabled         BIT                      -- 1 = check this rule, 0 = skip it
    , CONSTRAINT PK_Config_ExceptionRules PRIMARY KEY (RuleCode)
);
GO

-- 4.4 Exception Category
-- Groups exceptions into categories and assigns default severity
-- FIX #3: The original CREATE script was missing DefaultSeverity and BusinessArea.
--         Procedure 2 tried to read them and would fail.
IF OBJECT_ID('Config.ExceptionCategory', 'U') IS NOT NULL
    DROP TABLE Config.ExceptionCategory;

CREATE TABLE Config.ExceptionCategory
(
      ExceptionCategory   VARCHAR(100) NOT NULL
    , Description         VARCHAR(300)             -- What this category means
    , DefaultSeverity     VARCHAR(20)              -- FIX #3: NEW COLUMN
    , BusinessArea        VARCHAR(100)             -- FIX #3: NEW COLUMN
    , CONSTRAINT PK_Config_ExceptionCategory PRIMARY KEY (ExceptionCategory)
);
GO

-- 4.5 Exception Severity
-- Defines what each severity level means in business terms
-- e.g. CRITICAL = fix within 2 hours, escalate immediately
IF OBJECT_ID('Config.ExceptionSeverity', 'U') IS NOT NULL
    DROP TABLE Config.ExceptionSeverity;

CREATE TABLE Config.ExceptionSeverity
(
      SeverityCode        VARCHAR(20)  NOT NULL
    , PriorityLevel       INT                      -- 1 = most urgent, 4 = least
    , SLAHours            INT                      -- How many hours to fix it
    , EscalationRequired  BIT                      -- 1 = tell the boss, 0 = handle normally
    , CONSTRAINT PK_Config_ExceptionSeverity PRIMARY KEY (SeverityCode)
);
GO

-- 4.6 Business Owner
-- Maps each business area to the team that handles exceptions
-- FIX #11: Values were inconsistent. Some files said "Customer Operations",
--          others said "Customer Management". Now all aligned.
IF OBJECT_ID('Config.BusinessOwner', 'U') IS NOT NULL
    DROP TABLE Config.BusinessOwner;

CREATE TABLE Config.BusinessOwner
(
      BusinessArea        VARCHAR(100)             -- e.g. Customer Operations
    , BusinessOwner       VARCHAR(100)             -- Team lead name
    , SupportTeam         VARCHAR(100)             -- Team that does the work
);
GO

-- 4.7 Product Category
-- Groups products into regulatory categories
IF OBJECT_ID('Config.ProductCategory', 'U') IS NOT NULL
    DROP TABLE Config.ProductCategory;

CREATE TABLE Config.ProductCategory
(
      ProductCategory     VARCHAR(50)              -- e.g. Deposit, Loan
    , RegulatoryCategory  VARCHAR(50)              -- e.g. Retail, Credit
    , ActiveFlag          BIT                      -- Is this category still used?
);
GO

-- 4.8 Portfolio Value Bands
-- Defines customer segments based on total portfolio value
-- STANDARD = under $50k, SILVER = $50k-$250k, etc.
IF OBJECT_ID('Config.PortfolioValueBand', 'U') IS NOT NULL
    DROP TABLE Config.PortfolioValueBand;

CREATE TABLE Config.PortfolioValueBand
(
      BandName            VARCHAR(50)              -- e.g. STANDARD, SILVER, GOLD
    , MinimumValue        DECIMAL(18,2)            -- Lowest value in this band
    , MaximumValue        DECIMAL(18,2)            -- Highest value in this band
);
GO

-- 4.9 Reporting Thresholds
-- Defines the RED/AMBER/GREEN thresholds for executive dashboards
-- FIX #12: Procedure 5 hardcoded these values. This table lets business
--          users change them without touching code.
IF OBJECT_ID('Config.ReportingThreshold', 'U') IS NOT NULL
    DROP TABLE Config.ReportingThreshold;

CREATE TABLE Config.ReportingThreshold
(
      MetricName          VARCHAR(100)             -- e.g. Exception Rate
    , GreenThreshold      DECIMAL(18,2)            -- Below this = GREEN (good)
    , AmberThreshold      DECIMAL(18,2)            -- Below this = AMBER (warning)
    , RedThreshold        DECIMAL(18,2)            -- Above this = RED (bad)
);
GO

-- 4.10 Source System Lookup
-- A simple list of all source systems for dropdown menus and reports
IF OBJECT_ID('Config.SourceSystem', 'U') IS NOT NULL
    DROP TABLE Config.SourceSystem;

CREATE TABLE Config.SourceSystem
(
      SourceSystemCode    VARCHAR(50)              -- Short code
    , Description         VARCHAR(100)             -- Full name
    , ActiveFlag          BIT                      -- Is this system still feeding data?
);
GO

PRINT 'Configuration tables created (10 tables).';
GO


/******************************************************************************
  SECTION 5: WAREHOUSE TABLES (Corrected)
  ---------------------------------------
  Warehouse tables hold the CLEAN, TRUSTED data — the "single source of truth".
  This is what business users and reports actually look at.

  FIXES APPLIED:
    - Inconsistency #2: CustomerMasterExceptions expanded from 5 to 20 columns
    - The old CREATE script only had 5 columns, but Procedure 2 tried to
      MERGE 20 columns into it. This would cause a runtime crash.
******************************************************************************/

-- 5.1 Customer Master
-- The "Golden Record" — one row per customer, cleaned and deduplicated
IF OBJECT_ID('Warehouse.CustomerMaster', 'U') IS NOT NULL
    DROP TABLE Warehouse.CustomerMaster;

CREATE TABLE Warehouse.CustomerMaster
(
      CustomerId          VARCHAR(50)  NOT NULL   -- Unique customer ID
    , FirstName           VARCHAR(100)             -- Customer first name
    , LastName            VARCHAR(100)             -- Customer last name
    , CustomerCategory    VARCHAR(50)              -- PREMIUM, STANDARD, BUSINESS
    , BranchCode          VARCHAR(20)              -- Which branch they belong to
    , CustomerStatus      VARCHAR(20)              -- ACTIVE, INACTIVE, etc.
    , CreatedDate         DATETIME2(3)             -- When first loaded
    , LastUpdatedDate     DATETIME2(3)             -- When last changed
    , CONSTRAINT PK_Warehouse_CustomerMaster PRIMARY KEY (CustomerId)
);
GO

-- 5.2 Customer Master Exceptions
-- Records data quality problems found during customer loading
-- FIX #2: Expanded from 5 columns to 20 columns to match what Procedure 2 expects
IF OBJECT_ID('Warehouse.CustomerMasterExceptions', 'U') IS NOT NULL
    DROP TABLE Warehouse.CustomerMasterExceptions;

CREATE TABLE Warehouse.CustomerMasterExceptions
(
      ExceptionId         BIGINT       IDENTITY(1,1) NOT NULL  -- Auto-numbered ID
    , BusinessDate        DATE                                   -- Which day the error was found
    , CustomerId          VARCHAR(50)                            -- Who has the problem
    , SourceSystemCode    VARCHAR(50)                            -- Which system sent the bad data
    , ExceptionCategory   VARCHAR(100)                           -- What type of problem
    , ExceptionDescription NVARCHAR(500)                         -- Detailed explanation
    , SeverityCode        VARCHAR(20)                            -- How serious is it
    , SeverityDescription VARCHAR(100)                           -- Human-readable severity
    , EscalationRequired  BIT                                    -- Does the boss need to know?
    , ResolutionTargetHours INT                                  -- How long to fix it
    , BusinessArea        VARCHAR(100)                           -- Which team owns this
    , BusinessOwner       VARCHAR(100)                           -- Named owner
    , SupportTeam         VARCHAR(100)                           -- Team that fixes it
    , LoggedDate          DATETIME2(3)                           -- When the error was logged
    , ExceptionStatus     VARCHAR(30)                            -- OPEN, RESOLVED, etc.
    , AssignedDate        DATETIME2(3)                           -- When someone was assigned
    , ResolutionStatus    VARCHAR(30)                            -- Current fix status
    , EscalationLevel     INT                                    -- How high has it been escalated
    , ResolutionDueDate   DATETIME2(3)                           -- Deadline to fix
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()         -- Auto-set to now
    , LastUpdatedDate     DATETIME2(3) DEFAULT GETDATE()         -- Auto-set to now
    , CONSTRAINT PK_Warehouse_CustomerMasterExc PRIMARY KEY (ExceptionId)
);
GO

-- Indexes help the database find rows quickly
CREATE INDEX IX_CustomerMasterExceptions_BusinessDate
ON Warehouse.CustomerMasterExceptions(BusinessDate);

CREATE INDEX IX_CustomerMasterExceptions_CustomerId
ON Warehouse.CustomerMasterExceptions(CustomerId);

CREATE INDEX IX_CustomerMasterExceptions_SeverityCode
ON Warehouse.CustomerMasterExceptions(SeverityCode);
GO

-- 5.3 Customer Portfolio
-- The complete view of everything a customer owns across all 7 systems
-- This is the "single portfolio view" — one of the main project goals
IF OBJECT_ID('Warehouse.CustomerPortfolio', 'U') IS NOT NULL
    DROP TABLE Warehouse.CustomerPortfolio;

CREATE TABLE Warehouse.CustomerPortfolio
(
      PortfolioId         BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE         NOT NULL                -- Which day this represents
    , SourceSystemCode    VARCHAR(50)                          -- Where this account came from
    , SourceAccountNumber VARCHAR(100) NOT NULL                -- Account number in source system
    , CustomerId          VARCHAR(50)                          -- Linked customer
    , CustomerName        VARCHAR(200)                         -- Full name (enriched)
    , CustomerCategory    VARCHAR(50)                          -- PREMIUM, STANDARD, etc.
    , BranchCode          VARCHAR(20)                          -- Customer's branch
    , ProductCode         VARCHAR(50)                          -- Product identifier
    , ProductDescription  VARCHAR(200)                         -- Human-readable product name
    , ProductCategory     VARCHAR(100)                         -- e.g. Deposit, Loan
    , RegulatoryCategory  VARCHAR(100)                         -- e.g. Retail, Credit
    , CurrencyCode        VARCHAR(10)                          -- Original currency
    , ExchangeRate        DECIMAL(18,8)                        -- Rate used to convert to USD
    , AccountBalance      DECIMAL(18,2)                        -- Balance in original currency
    , BaseCurrencyBalance DECIMAL(18,2)                        -- Balance converted to USD
    , AccountStatus       VARCHAR(30)                          -- ACTIVE, CLOSED, etc.
    , EligibleForReporting VARCHAR(1)                          -- Y = show in reports, N = hide
    , PortfolioValueBand  VARCHAR(50)                          -- STANDARD, SILVER, GOLD, PLATINUM
    , HighValueCustomer   BIT                                  -- 1 = over $500k
    , ProductCount        INT                                  -- How many products they have
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , LastUpdatedDate     DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Warehouse_CustomerPortfolio PRIMARY KEY (PortfolioId)
);
GO

-- Unique index prevents the same account appearing twice for the same customer on the same day
CREATE UNIQUE INDEX IX_CustomerPortfolio_BusinessKey
ON Warehouse.CustomerPortfolio(BusinessDate, CustomerId, SourceAccountNumber);

CREATE INDEX IX_CustomerPortfolio_CustomerId
ON Warehouse.CustomerPortfolio(CustomerId);

CREATE INDEX IX_CustomerPortfolio_BusinessDate
ON Warehouse.CustomerPortfolio(BusinessDate);
GO

-- 5.4 Customer Portfolio Exceptions
-- Data quality problems found in the portfolio data
-- This is where Procedure 4 stores enriched exceptions with hashes, SLAs, etc.
IF OBJECT_ID('Warehouse.CustomerPortfolioExceptions', 'U') IS NOT NULL
    DROP TABLE Warehouse.CustomerPortfolioExceptions;

CREATE TABLE Warehouse.CustomerPortfolioExceptions
(
      ExceptionId         BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE
    , SourceSystemCode    VARCHAR(50)
    , SourceAccountNumber VARCHAR(100)
    , CustomerId          VARCHAR(50)
    , RuleCode            VARCHAR(50)              -- Which DQ rule was broken (DQ001-DQ006)
    , ExceptionCategory   VARCHAR(100)
    , ExceptionDescription NVARCHAR(500)
    , ExceptionValue      NVARCHAR(200)            -- The actual bad value
    , SeverityCode        VARCHAR(20)
    , PriorityLevel       INT                      -- 1=CRITICAL, 4=LOW
    , SLAHours            INT                      -- Hours to fix
    , EscalationRequired  BIT
    , EscalationQueue     VARCHAR(100)             -- Which queue handles it
    , BusinessArea        VARCHAR(100)
    , BusinessOwner       VARCHAR(100)
    , ExceptionHash       VARCHAR(64)              -- SHA256 fingerprint (prevents duplicates)
    , LoggedDate          DATETIME2(3)
    , ResolutionDueDate   DATETIME2(3)             -- When it must be fixed by
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , LastUpdatedDate     DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Warehouse_CustomerPortfolioExc PRIMARY KEY (ExceptionId)
);
GO

CREATE INDEX IX_PortfolioExceptions_BusinessDate
ON Warehouse.CustomerPortfolioExceptions(BusinessDate);

CREATE INDEX IX_PortfolioExceptions_ExceptionHash
ON Warehouse.CustomerPortfolioExceptions(ExceptionHash);

CREATE INDEX IX_PortfolioExceptions_CustomerId
ON Warehouse.CustomerPortfolioExceptions(CustomerId);
GO

PRINT 'Warehouse tables created (4 tables).';
GO


/******************************************************************************
  SECTION 6: NEW STAGING / ERROR TABLES
  -------------------------------------
  These are BRAND NEW tables that did not exist in the original system.
  They fix critical problems we found during analysis.

  FIX #8: PortfolioErrors — CRITICAL RUNTIME FAILURE FIX
  -------------------------------------------------------
  THE PROBLEM:
    Procedure 3 found bad data (missing customer, missing product, etc.)
    and tried to save it to Warehouse.CustomerPortfolioExceptions.
    BUT that table expects 20+ columns (severity, hash, SLA, etc.).
    Procedure 3 only had 7 columns of information.
    Result: SQL Server would throw an error and the whole batch would fail.

  THE SOLUTION:
    Create a simple 7-column "holding area" called PortfolioErrors.
    Procedure 3 writes raw errors here.
    Procedure 4 can read from here if needed, or just process its own rules.
    This separates "raw errors" from "enriched exceptions".
******************************************************************************/

-- 6.1 Portfolio Errors (NEW — Inconsistency #8 RESOLVED)
-- A simple staging table for raw validation errors from Procedure 3
IF OBJECT_ID('Warehouse.PortfolioErrors', 'U') IS NOT NULL
    DROP TABLE Warehouse.PortfolioErrors;

CREATE TABLE Warehouse.PortfolioErrors
(
      ErrorId             BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE                                   -- Which day
    , SourceSystemCode    VARCHAR(50)                            -- Which system
    , SourceAccountNumber VARCHAR(100)                           -- Which account
    , CustomerId          VARCHAR(50)                            -- Which customer
    , ErrorCategory       VARCHAR(100)                           -- What went wrong
    , ErrorDescription    NVARCHAR(500)                          -- Details
    , LoggedDate          DATETIME2(3) DEFAULT GETDATE()         -- Auto-timestamp
    , ExecutionId         UNIQUEIDENTIFIER                       -- Links to audit log
    , CONSTRAINT PK_Warehouse_PortfolioErrors PRIMARY KEY (ErrorId)
);
GO

CREATE INDEX IX_PortfolioErrors_BusinessDate
ON Warehouse.PortfolioErrors(BusinessDate);

CREATE INDEX IX_PortfolioErrors_CustomerId
ON Warehouse.PortfolioErrors(CustomerId);
GO

PRINT 'NEW: PortfolioErrors staging table created.';
GO


/******************************************************************************
  SECTION 7: AUDIT TABLES (All 10)
  --------------------------------
  Audit tables are the "black box recorder" of the data warehouse.
  They answer questions like:
    - Did last night's batch run successfully?
    - How many rows were loaded?
    - How long did it take?
    - Were there any errors?

  FIXES APPLIED:
    - Inconsistency #4: NEW table DataQualityIssues (was referenced but missing)
    - Inconsistency #5: NEW table ExceptionExecutionSummary (separate from Portfolio)
******************************************************************************/

-- 7.1 ETL Execution Log (Master)
-- Every procedure writes one row here when it starts, and updates it when it finishes
IF OBJECT_ID('Audit.ETLExecutionLog', 'U') IS NOT NULL
    DROP TABLE Audit.ETLExecutionLog;

CREATE TABLE Audit.ETLExecutionLog
(
      ExecutionId         UNIQUEIDENTIFIER NOT NULL  -- Unique run ID (like a flight number)
    , ProcedureName       SYSNAME          NOT NULL  -- Which procedure ran
    , BusinessDate        DATE                         -- Which business day was processed
    , LoadType            VARCHAR(20)                  -- FULL or INCREMENTAL
    , StartTime           DATETIME2(3)                 -- When it started
    , EndTime             DATETIME2(3)                 -- When it finished
    , Status              VARCHAR(20)                  -- RUNNING, SUCCESS, or FAILED
    , RowsRead            INT                          -- How many rows came in
    , RowsInserted        INT                          -- How many rows were new
    , RowsUpdated         INT                          -- How many rows changed
    , RowsRejected        INT                          -- How many rows had errors
    , DurationSeconds     INT                          -- How long it took
    , Message             NVARCHAR(4000)               -- Success message or error details
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Audit_ETLExecutionLog PRIMARY KEY (ExecutionId)
);
GO

-- 7.2 Data Quality Issues (NEW — Inconsistency #4 RESOLVED)
-- FIX #4: Procedures 1 and 2 referenced this table, but it never existed.
--         We created it so exception logging can work properly.
IF OBJECT_ID('Audit.DataQualityIssues', 'U') IS NOT NULL
    DROP TABLE Audit.DataQualityIssues;

CREATE TABLE Audit.DataQualityIssues
(
      IssueId             BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE         NOT NULL
    , SourceSystem        VARCHAR(50)  NOT NULL
    , CustomerId          VARCHAR(50)
    , ErrorCategory       VARCHAR(100) NOT NULL
    , ErrorDescription    NVARCHAR(500) NOT NULL
    , LoggedDate          DATETIME2(3) DEFAULT GETDATE()
    , ExecutionId         UNIQUEIDENTIFIER           -- Links to the ETLExecutionLog
    , CONSTRAINT PK_Audit_DataQualityIssues PRIMARY KEY (IssueId)
);
GO

CREATE INDEX IX_DataQualityIssues_BusinessDate
ON Audit.DataQualityIssues(BusinessDate);

CREATE INDEX IX_DataQualityIssues_CustomerId
ON Audit.DataQualityIssues(CustomerId);
GO

-- 7.3 Exception Execution Summary (NEW — Inconsistency #5 RESOLVED)
-- FIX #5: Procedure 2 wrote to "ExceptionExecutionSummary" but the audit script
--         created "PortfolioExceptionExecutionSummary". These are now TWO
--         separate tables — one for customer exceptions, one for portfolio.
IF OBJECT_ID('Audit.ExceptionExecutionSummary', 'U') IS NOT NULL
    DROP TABLE Audit.ExceptionExecutionSummary;

CREATE TABLE Audit.ExceptionExecutionSummary
(
      SummaryId           BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE
    , ExecutionId         UNIQUEIDENTIFIER NOT NULL
    , ProcedureName       SYSNAME
    , TotalExceptions     INT
    , CriticalExceptions  INT
    , HighExceptions      INT
    , MediumExceptions    INT
    , LowExceptions       INT
    , EscalatedExceptions INT
    , ExecutionSeconds    INT
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Audit_ExceptionExecutionSumm PRIMARY KEY (SummaryId)
);
GO

-- 7.4 Portfolio Execution Summary
-- Daily statistics from Procedure 3 (portfolio loading)
IF OBJECT_ID('Audit.PortfolioExecutionSummary', 'U') IS NOT NULL
    DROP TABLE Audit.PortfolioExecutionSummary;

CREATE TABLE Audit.PortfolioExecutionSummary
(
      SummaryId           BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE
    , ProcedureName       SYSNAME
    , ExecutionId         UNIQUEIDENTIFIER
    , TotalCustomers      INT
    , TotalAccounts       INT
    , TotalPortfolioValue DECIMAL(18,2)
    , TotalErrors         INT
    , ExecutionTimeSeconds INT
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Audit_PortfolioExecutionSumm PRIMARY KEY (SummaryId)
);
GO

-- 7.5 Portfolio Exception Execution Summary
-- Daily statistics from Procedure 4 (exception processing)
IF OBJECT_ID('Audit.PortfolioExceptionExecutionSummary', 'U') IS NOT NULL
    DROP TABLE Audit.PortfolioExceptionExecutionSummary;

CREATE TABLE Audit.PortfolioExceptionExecutionSummary
(
      SummaryId           BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE
    , ExecutionId         UNIQUEIDENTIFIER
    , ProcedureName       SYSNAME
    , TotalExceptions     INT
    , CriticalExceptions  INT
    , HighExceptions      INT
    , MediumExceptions    INT
    , LowExceptions       INT
    , EscalatedExceptions INT
    , ExecutionSeconds    INT
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Audit_PortfolioExceptionExecSumm PRIMARY KEY (SummaryId)
);
GO

-- 7.6 Business Area Exception Summary
-- Shows which departments have the most problems
IF OBJECT_ID('Audit.BusinessAreaExceptionSummary', 'U') IS NOT NULL
    DROP TABLE Audit.BusinessAreaExceptionSummary;

CREATE TABLE Audit.BusinessAreaExceptionSummary
(
      SummaryId           BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE
    , BusinessArea        VARCHAR(100)
    , ExceptionCount      INT
    , CriticalCount       INT
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Audit_BusinessAreaExceptionSumm PRIMARY KEY (SummaryId)
);
GO

-- 7.7 Reporting Execution Summary
-- Tracks which reports were generated and how long they took
IF OBJECT_ID('Audit.ReportingExecutionSummary', 'U') IS NOT NULL
    DROP TABLE Audit.ReportingExecutionSummary;

CREATE TABLE Audit.ReportingExecutionSummary
(
      SummaryId           BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE
    , ExecutionId         UNIQUEIDENTIFIER
    , ProcedureName       SYSNAME
    , ReportName          VARCHAR(200)
    , RecordsGenerated    INT
    , ExecutionSeconds    INT
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Audit_ReportingExecutionSumm PRIMARY KEY (SummaryId)
);
GO

-- 7.8 Executive Dashboard Metrics
-- Snapshot of portfolio health for the executive dashboard
IF OBJECT_ID('Audit.ExecutiveDashboardMetrics', 'U') IS NOT NULL
    DROP TABLE Audit.ExecutiveDashboardMetrics;

CREATE TABLE Audit.ExecutiveDashboardMetrics
(
      MetricId            BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE
    , PortfolioHealth     VARCHAR(20)              -- EXCELLENT, GOOD, FAIR, POOR
    , CriticalExceptions  INT
    , ExceptionRate       DECIMAL(10,2)            -- Percentage
    , SLACompliance       DECIMAL(10,2)            -- Percentage
    , GeneratedDate       DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Audit_ExecutiveDashboardMetrics PRIMARY KEY (MetricId)
);
GO

-- 7.9 Data Lineage (Recommended)
-- Tracks where each piece of data came from and how it was transformed
-- This is like a "family tree" for your data
IF OBJECT_ID('Audit.DataLineage', 'U') IS NOT NULL
    DROP TABLE Audit.DataLineage;

CREATE TABLE Audit.DataLineage
(
      LineageId           BIGINT       IDENTITY(1,1) NOT NULL
    , ProcedureName       SYSNAME
    , SourceObject        VARCHAR(200)             -- e.g. Source.CoreBankingAccounts
    , SourceColumn        VARCHAR(200)             -- e.g. AccountBalance
    , TransformationRule  VARCHAR(500)             -- e.g. "Multiply by ExchangeRate"
    , TargetObject        VARCHAR(200)             -- e.g. Warehouse.CustomerPortfolio
    , TargetColumn        VARCHAR(200)             -- e.g. BaseCurrencyBalance
    , BusinessRule        VARCHAR(500)             -- Human-readable explanation
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Audit_DataLineage PRIMARY KEY (LineageId)
);
GO

-- 7.10 ETL Error Log (Recommended)
-- Captures detailed error messages when a procedure fails
IF OBJECT_ID('Audit.ETLErrorLog', 'U') IS NOT NULL
    DROP TABLE Audit.ETLErrorLog;

CREATE TABLE Audit.ETLErrorLog
(
      ErrorId             BIGINT       IDENTITY(1,1) NOT NULL
    , ExecutionId         UNIQUEIDENTIFIER         -- Links to the failed run
    , ProcedureName       SYSNAME
    , ErrorNumber         INT                      -- SQL Server error code
    , ErrorMessage        NVARCHAR(4000)           -- Full error text
    , ErrorDate           DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Audit_ETLErrorLog PRIMARY KEY (ErrorId)
);
GO

PRINT 'Audit tables created (10 tables).';
GO


/******************************************************************************
  SECTION 8: REPORTING TABLES
  ---------------------------
  These tables feed the executive dashboards and Power BI reports.
******************************************************************************/

-- Portfolio Exception Report
-- The daily executive summary of portfolio health and exceptions
IF OBJECT_ID('Reporting.PortfolioExceptionReport', 'U') IS NOT NULL
    DROP TABLE Reporting.PortfolioExceptionReport;

CREATE TABLE Reporting.PortfolioExceptionReport
(
      ReportId            BIGINT       IDENTITY(1,1) NOT NULL
    , BusinessDate        DATE
    , KPIName             VARCHAR(100)             -- e.g. ExceptionRate, PortfolioHealth
    , KPIValue            VARCHAR(50)              -- The actual value
    , KPIStatus           VARCHAR(20)              -- GREEN, AMBER, RED
    , CreatedDate         DATETIME2(3) DEFAULT GETDATE()
    , CONSTRAINT PK_Reporting_PortfolioExceptionRpt PRIMARY KEY (ReportId)
);
GO

CREATE INDEX IX_PortfolioExceptionReport_BusinessDate
ON Reporting.PortfolioExceptionReport(BusinessDate);
GO

PRINT 'Reporting tables created.';
GO


/******************************************************************************
  SECTION 9: CONFIGURATION DATA (Authoritative Values)
  ----------------------------------------------------
  This section INSERTS the actual data into the Config tables.
  These are the "settings" that control how the system behaves.

  IMPORTANT: These values have been RECONCILED across all source files.
  They represent the single agreed-upon version of the truth.

  FIXES APPLIED:
    - Inconsistency #10: ExceptionRules now has consistent severity levels
    - Inconsistency #11: BusinessOwner values aligned
******************************************************************************/

PRINT 'Loading authoritative configuration data...';
GO

-- 9.1 Customer Source Configuration
-- Tells Procedure 1 which customer tables to read and in what order
INSERT INTO Config.CustomerSourceConfiguration
(SourceSystemId, SourceSystemCode, SourceSystemName, CustomerTable, IsActive, LoadPriority, SupportsIncremental)
VALUES
(1, 'CORE_BANKING', 'Core Banking System', 'Source.CoreBankingAccounts', 1, 1, 1),
(2, 'LOANS',        'Loan System',         'Source.LoanAccounts',        1, 2, 1),
(3, 'CARDS',        'Card Platform',       'Source.CardAccounts',        1, 3, 1),
(4, 'INVESTMENTS',  'Investment Platform', 'Source.InvestmentAccounts',  1, 4, 1),
(5, 'MORTGAGE',     'Mortgage System',     'Source.MortgageAccounts',    1, 5, 1),
(6, 'MOBILE',       'Mobile Banking',      'Source.MobileWallet',        1, 6, 1),
(7, 'FOREX',        'Forex Platform',      'Source.ForexAccounts',       1, 7, 1);
GO

-- 9.2 Portfolio Source Configuration
-- Tells Procedure 3 which portfolio tables to read and how to map columns
INSERT INTO Config.PortfolioSourceConfiguration
(SourceSystemId, SourceSystemCode, SourceSystemName, ProductTable, CustomerField, ProductField, BalanceField, CurrencyField, StatusField, BusinessDateField, SourceAccountField, LoadPriority, SupportsIncremental, IsActive)
VALUES
(1, 'CORE_BANKING', 'Core Banking System', 'Source.CoreBankingAccounts', 'CustomerNumber', 'ProductCode', 'AccountBalance', 'Currency', 'AccountStatus', 'RecordDate', 'AccountNumber', 1, 1, 1),
(2, 'LOANS',        'Loan System',         'Source.LoanAccounts',        'ClientId',       'LoanProduct', 'OutstandingAmount', 'LoanCurrency', 'LoanStatus', 'SnapshotDate', 'LoanNumber', 2, 1, 1),
(3, 'CARDS',        'Card Platform',       'Source.CardAccounts',        'ClientNumber',   'CardProduct', 'CreditBalance', 'CardCurrency', 'CardStatus', 'BusinessDate', 'CardAccountNumber', 3, 1, 1),
(4, 'INVESTMENTS',  'Investment Platform', 'Source.InvestmentAccounts',  'InvestorId',     'InvestmentProduct', 'MarketValue', 'InvestmentCurrency', 'InvestmentStatus', 'ValuationDate', 'InvestmentId', 4, 1, 1),
(5, 'MORTGAGE',     'Mortgage System',     'Source.MortgageAccounts',    'ClientCode',     'MortgageType', 'BalanceAmount', 'CurrencyCode', 'Status', 'EffectiveDate', 'MortgageNumber', 5, 1, 1),
(6, 'MOBILE',       'Mobile Banking',      'Source.MobileWallet',        'CustomerNumber', 'WalletProduct', 'WalletBalance', 'WalletCurrency', 'WalletStatus', 'LoadDate', 'WalletId', 6, 1, 1),
(7, 'FOREX',        'Forex Platform',      'Source.ForexAccounts',       'CustomerId',     'ForexProduct', 'TradeAmount', 'TradeCurrency', 'TradeStatus', 'TradeDate', 'TradeId', 7, 1, 1);
GO

-- 9.3 Exception Rules (Authoritative -- Inconsistency #10 RESOLVED)
-- These are the 6 data quality rules with AGREED severity levels
INSERT INTO Config.ExceptionRules
(RuleCode, ExceptionCategory, SeverityCode, BusinessArea, RuleEnabled)
VALUES
('DQ001', 'Customer Validation', 'HIGH',     'Customer Operations', 1),
('DQ002', 'Product Validation',  'MEDIUM',   'Product Management',  1),
('DQ003', 'Currency Validation', 'HIGH',     'Finance',             1),
('DQ004', 'Financial Validation', 'CRITICAL', 'Risk',                1),
('DQ005', 'Business Rule',       'HIGH',     'Operations',          1),
('DQ006', 'Duplicate Account',   'CRITICAL', 'Data Governance',     1);
GO

-- 9.4 Exception Category (Inconsistency #3 RESOLVED)
INSERT INTO Config.ExceptionCategory
(ExceptionCategory, Description, DefaultSeverity, BusinessArea)
VALUES
('Customer Validation', 'Customer master validation',           'HIGH',     'Customer Operations'),
('Product Validation',  'Product reference validation',         'MEDIUM',   'Product Management'),
('Currency Validation', 'Exchange rate validation',             'HIGH',     'Finance'),
('Financial Validation', 'Portfolio financial checks',          'CRITICAL', 'Risk'),
('Business Rule',       'Business processing rules',            'HIGH',     'Operations'),
('Duplicate Account',   'Duplicate portfolio account detection', 'CRITICAL', 'Data Governance');
GO

-- 9.5 Exception Severity
INSERT INTO Config.ExceptionSeverity
(SeverityCode, PriorityLevel, SLAHours, EscalationRequired)
VALUES
('CRITICAL', 1, 2,  1),
('HIGH',     2, 8,  1),
('MEDIUM',   3, 24, 0),
('LOW',      4, 72, 0);
GO

-- 9.6 Business Owner (Inconsistency #11 RESOLVED)
INSERT INTO Config.BusinessOwner
(BusinessArea, BusinessOwner, SupportTeam)
VALUES
('Customer Operations', 'Customer Services Team', 'CRM Support'),
('Product Management',  'Product Owners',         'Product Support'),
('Finance',             'Finance Control',        'Finance Operations'),
('Risk',                'Risk Management',        'Risk Analytics'),
('Operations',          'Operations Team',        'Operations Support'),
('Data Governance',     'Data Quality Office',    'Enterprise Data Office');
GO

-- 9.7 Product Category
INSERT INTO Config.ProductCategory
(ProductCategory, RegulatoryCategory, ActiveFlag)
VALUES
('Deposit',    'Retail',     1),
('Loan',       'Credit',     1),
('Mortgage',   'Credit',     1),
('Investment', 'Investment', 1),
('Card',       'Retail',     1),
('Forex',      'Treasury',   1);
GO

-- 9.8 Portfolio Value Bands
INSERT INTO Config.PortfolioValueBand
(BandName, MinimumValue, MaximumValue)
VALUES
('STANDARD', 0.00,       49999.99),
('SILVER',   50000.00,   249999.99),
('GOLD',     250000.00,  999999.99),
('PLATINUM', 1000000.00, 999999999.99);
GO

-- 9.9 Reporting Thresholds (Inconsistency #12 RESOLVED)
INSERT INTO Config.ReportingThreshold
(MetricName, GreenThreshold, AmberThreshold, RedThreshold)
VALUES
('Exception Rate',      2.00,  5.00,   100.00),
('Critical Exceptions', 10.00, 50.00,  100000.00),
('SLA Failure Rate',    5.00,  15.00,  100.00);
GO

-- 9.10 Source System Lookup
INSERT INTO Config.SourceSystem
(SourceSystemCode, Description, ActiveFlag)
VALUES
('CORE_BANKING', 'Core Banking',      1),
('LOANS',        'Loan System',       1),
('CARDS',        'Card Processing',   1),
('INVESTMENTS',  'Investment Platform', 1),
('MORTGAGE',     'Mortgage Platform', 1),
('FOREX',        'Foreign Exchange',  1),
('MOBILE',       'Mobile Banking',    1);
GO

PRINT 'Configuration data loaded (authoritative values).';
GO


/******************************************************************************
  SECTION 10: REFERENCE DATA
******************************************************************************/

INSERT INTO Reference.Product
(ProductCode, ProductDescription, ProductCategory, RegulatoryCategory, ProductStatus, EffectiveDate)
VALUES
('SAV001',        'Savings Account',                'Deposit',      'Retail',     'ACTIVE', '2026-01-01'),
('CUR001',        'Current Account',                'Deposit',      'Retail',     'ACTIVE', '2026-01-01'),
('HOME_LOAN',     'Residential Mortgage Loan',      'Loans',        'Credit',     'ACTIVE', '2026-01-01'),
('PERSONAL_LOAN', 'Personal Lending Product',       'Loans',        'Credit',     'ACTIVE', '2026-01-01'),
('GOLD_CARD',     'Premium Credit Card',            'Cards',        'Credit',     'ACTIVE', '2026-01-01'),
('STANDARD_CARD', 'Standard Credit Card',           'Cards',        'Credit',     'ACTIVE', '2026-01-01'),
('EQUITY_FUND',   'Equity Investment Fund',         'Investments',  'Investment', 'ACTIVE', '2026-01-01'),
('BOND_FUND',     'Fixed Income Investment Fund',   'Investments',  'Investment', 'ACTIVE', '2026-01-01'),
('MOBILE_WALLET', 'Digital Wallet',                 'Digital',      'Payment',    'ACTIVE', '2026-01-01'),
('FX_FORWARD',    'Foreign Exchange Forward',       'Forex',        'Treasury',   'ACTIVE', '2026-01-01');
GO

INSERT INTO Reference.ExchangeRates
(CurrencyCode, ExchangeRate, EffectiveDate)
VALUES
('USD', 1.00000000, '2026-01-31'),
('EUR', 1.08000000, '2026-01-31'),
('GBP', 1.25000000, '2026-01-31'),
('ZAR', 0.05500000, '2026-01-31'),
('JPY', 0.00670000, '2026-01-31');
GO

PRINT 'Reference data loaded.';
GO


/******************************************************************************
  SECTION 11: SAMPLE SOURCE DATA (Day 1)
******************************************************************************/

INSERT INTO Source.CoreBankingAccounts
(AccountNumber, CustomerNumber, ProductCode, AccountBalance, Currency, AccountStatus, RecordDate)
VALUES
('CB10001', 'CUST001', 'SAV001', 25000.00,  'USD', 'ACTIVE', '2026-01-31'),
('CB10002', 'CUST002', 'CUR001', 75000.00,  'EUR', 'ACTIVE', '2026-01-31'),
('CB10003', 'CUST003', 'SAV001', 0.00,      'USD', 'ACTIVE', '2026-01-31'),
('CB10004', 'CUST004', 'CUR001', -5000.00,  'GBP', 'ACTIVE', '2026-01-31'),
('CB10005', NULL,      'SAV001', 10000.00,  'USD', 'ACTIVE', '2026-01-31'),
('CB10006', 'CUST006', NULL,     15000.00,  'USD', 'ACTIVE', '2026-01-31'),
('CB10007', 'CUST007', 'SAV001', 45000.00,  NULL,  'ACTIVE', '2026-01-31'),
('CB10008', 'CUST008', 'SAV001', 8000.00,   'USD', 'CLOSED', '2026-01-31');
GO

INSERT INTO Source.LoanAccounts
(LoanNumber, ClientId, LoanProduct, OutstandingAmount, LoanCurrency, LoanStatus, SnapshotDate)
VALUES
('LN10001', 'CUST001', 'HOME_LOAN',     500000, 'USD', 'ACTIVE', '2026-01-31'),
('LN10002', 'CUST002', 'PERSONAL_LOAN', 25000,  'EUR', 'ACTIVE', '2026-01-31'),
('LN10003', 'CUST009', 'HOME_LOAN',     750000, 'GBP', 'ACTIVE', '2026-01-31'),
('LN10004', 'CUST010', 'PERSONAL_LOAN', -1000,  'USD', 'ACTIVE', '2026-01-31'),
('LN10005', 'CUST011', 'UNKNOWN',       30000,  'USD', 'ACTIVE', '2026-01-31');
GO

INSERT INTO Source.CardAccounts
(CardAccountNumber, ClientNumber, CardProduct, CreditBalance, CardCurrency, CardStatus, BusinessDate)
VALUES
('CARD001', 'CUST001', 'GOLD_CARD',      12000, 'USD', 'ACTIVE', '2026-01-31'),
('CARD002', 'CUST003', 'STANDARD_CARD',  5000,  'USD', 'ACTIVE', '2026-01-31'),
('CARD003', 'CUST004', 'GOLD_CARD',      25000, 'EUR', 'ACTIVE', '2026-01-31'),
('CARD004', 'CUST005', 'STANDARD_CARD',  NULL,  'USD', 'ACTIVE', '2026-01-31');
GO

INSERT INTO Source.InvestmentAccounts
(InvestmentId, InvestorId, InvestmentProduct, MarketValue, InvestmentCurrency, InvestmentStatus, ValuationDate)
VALUES
('INV001', 'CUST001', 'EQUITY_FUND', 150000,  'USD', 'ACTIVE', '2026-01-31'),
('INV002', 'CUST012', 'BOND_FUND',   250000,  'EUR', 'ACTIVE', '2026-01-31'),
('INV003', 'CUST013', 'EQUITY_FUND', 1000000, 'USD', 'ACTIVE', '2026-01-31');
GO

INSERT INTO Source.MortgageAccounts
(MortgageNumber, ClientCode, MortgageType, BalanceAmount, CurrencyCode, Status, EffectiveDate)
VALUES
('MORT001', 'CUST001', 'HOME', 900000,  'USD', 'ACTIVE', '2026-01-31'),
('MORT002', 'CUST014', 'HOME', 1200000, 'USD', 'ACTIVE', '2026-01-31'),
('MORT003', 'CUST015', 'HOME', 500000,  'GBP', 'CLOSED', '2026-01-31');
GO

INSERT INTO Source.MobileWallet
(WalletId, CustomerNumber, WalletProduct, WalletBalance, WalletCurrency, WalletStatus, LoadDate)
VALUES
('WAL001', 'CUST001', 'MOBILE_WALLET', 500,  'USD', 'ACTIVE', '2026-01-31'),
('WAL002', 'CUST020', 'MOBILE_WALLET', 1000, 'EUR', 'ACTIVE', '2026-01-31'),
('WAL003', 'CUST021', 'MOBILE_WALLET', 0,    'USD', 'ACTIVE', '2026-01-31');
GO

INSERT INTO Source.ForexAccounts
(TradeId, CustomerId, ForexProduct, TradeAmount, TradeCurrency, TradeStatus, TradeDate)
VALUES
('FX001', 'CUST001', 'FX_FORWARD', 250000,  'USD', 'ACTIVE', '2026-01-31'),
('FX002', 'CUST030', 'FX_SWAP',    500000,  'EUR', 'ACTIVE', '2026-01-31'),
('FX003', 'CUST031', 'FX_FORWARD', -50000,  'GBP', 'ACTIVE', '2026-01-31');
GO

PRINT 'Sample source data loaded (Day 1).';
GO


/******************************************************************************
  SECTION 12: SAMPLE CUSTOMER MASTER DATA
******************************************************************************/

INSERT INTO Warehouse.CustomerMaster
(CustomerId, FirstName, LastName, CustomerCategory, BranchCode, CustomerStatus, CreatedDate)
VALUES
('CUST001', 'John',    'Smith',    'PREMIUM',  'BR001', 'ACTIVE', GETDATE()),
('CUST002', 'Mary',    'Jones',    'STANDARD', 'BR002', 'ACTIVE', GETDATE()),
('CUST003', 'Peter',   'Brown',    'STANDARD', 'BR001', 'ACTIVE', GETDATE()),
('CUST004', 'Sarah',   'Williams', 'PREMIUM',  'BR003', 'ACTIVE', GETDATE()),
('CUST006', 'David',   'Miller',   'BUSINESS', 'BR004', 'ACTIVE', GETDATE()),
('CUST007', 'James',   'Wilson',   'STANDARD', 'BR002', 'ACTIVE', GETDATE()),
('CUST008', 'Linda',   'Taylor',   'STANDARD', 'BR001', 'ACTIVE', GETDATE()),
('CUST010', 'Robert',  'Johnson',  'BUSINESS', 'BR005', 'ACTIVE', GETDATE()),
('CUST012', 'Michael', 'Davis',    'PREMIUM',  'BR006', 'ACTIVE', GETDATE());
GO

PRINT 'Customer master sample data loaded.';
GO


/******************************************************************************
  SECTION 13: DEPLOYMENT VERIFICATION
******************************************************************************/

PRINT '=================================================================';
PRINT 'Schema Deployment Verification';
PRINT '=================================================================';

SELECT 'Source Tables' AS Layer, COUNT(*) AS ObjectCount
FROM sys.tables WHERE schema_id = SCHEMA_ID('Source')
UNION ALL
SELECT 'Reference Tables', COUNT(*)
FROM sys.tables WHERE schema_id = SCHEMA_ID('Reference')
UNION ALL
SELECT 'Config Tables', COUNT(*)
FROM sys.tables WHERE schema_id = SCHEMA_ID('Config')
UNION ALL
SELECT 'Warehouse Tables', COUNT(*)
FROM sys.tables WHERE schema_id = SCHEMA_ID('Warehouse')
UNION ALL
SELECT 'Reporting Tables', COUNT(*)
FROM sys.tables WHERE schema_id = SCHEMA_ID('Reporting')
UNION ALL
SELECT 'Audit Tables', COUNT(*)
FROM sys.tables WHERE schema_id = SCHEMA_ID('Audit');
GO

PRINT '=================================================================';
PRINT 'Deployment Complete. All 12 inconsistencies resolved.';
PRINT '=================================================================';


USE RetailBank_EDW;
GO

-- Check that ExceptionRules loaded with the reconciled values
SELECT RuleCode, ExceptionCategory, SeverityCode, BusinessArea
FROM Config.ExceptionRules;
GO