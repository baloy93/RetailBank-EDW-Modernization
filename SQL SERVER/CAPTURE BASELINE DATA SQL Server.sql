USE RetailBank_EDW;
GO

/******************************************************************************
  RETAILBANK EDW - CAPTURE BASELINE DATA
  =======================================
  Date: 15 August 2026

  WHAT DOES THIS SCRIPT DO?
  -------------------------
  Creates baseline tables that contain snapshots of all ETL outputs.
  These tables are the "source of truth" for reconciliation.
******************************************************************************/

SET NOCOUNT ON;
GO

DECLARE @BusinessDate DATE = '2026-01-31';
DECLARE @SnapshotTime DATETIME = GETDATE();

PRINT '=================================================================';
PRINT 'CAPTURE SQL SERVER BASELINE DATA';
PRINT '=================================================================';
PRINT 'Snapshot Time: ' + CAST(@SnapshotTime AS VARCHAR(30));
PRINT '';

-- Drop existing baseline tables
IF OBJECT_ID('dbo.Baseline_CustomerMaster', 'U') IS NOT NULL
    DROP TABLE dbo.Baseline_CustomerMaster;

IF OBJECT_ID('dbo.Baseline_CustomerPortfolio', 'U') IS NOT NULL
    DROP TABLE dbo.Baseline_CustomerPortfolio;

IF OBJECT_ID('dbo.Baseline_CustomerPortfolioExceptions', 'U') IS NOT NULL
    DROP TABLE dbo.Baseline_CustomerPortfolioExceptions;

IF OBJECT_ID('dbo.Baseline_PortfolioExceptionReport', 'U') IS NOT NULL
    DROP TABLE dbo.Baseline_PortfolioExceptionReport;

PRINT 'Existing baseline tables dropped.';
PRINT '';

-- Capture CustomerMaster
SELECT
      CustomerId
    , FirstName
    , LastName
    , CustomerCategory
    , BranchCode
    , CustomerStatus
    , CreatedDate
    , LastUpdatedDate
    , @SnapshotTime AS BaselineCaptureDate
INTO dbo.Baseline_CustomerMaster
FROM Warehouse.CustomerMaster
WHERE CustomerId IN (
    SELECT DISTINCT CustomerNumber
    FROM Source.CoreBankingAccounts
    WHERE RecordDate = @BusinessDate
    UNION
    SELECT DISTINCT ClientId
    FROM Source.LoanAccounts
    WHERE SnapshotDate = @BusinessDate
    UNION
    SELECT DISTINCT ClientNumber
    FROM Source.CardAccounts
    WHERE BusinessDate = @BusinessDate
    UNION
    SELECT DISTINCT InvestorId
    FROM Source.InvestmentAccounts
    WHERE ValuationDate = @BusinessDate
    UNION
    SELECT DISTINCT ClientCode
    FROM Source.MortgageAccounts
    WHERE EffectiveDate = @BusinessDate
    UNION
    SELECT DISTINCT CustomerNumber
    FROM Source.MobileWallet
    WHERE LoadDate = @BusinessDate
    UNION
    SELECT DISTINCT CustomerId
    FROM Source.ForexAccounts
    WHERE TradeDate = @BusinessDate
);

PRINT 'CustomerMaster baseline created.';

-- Capture CustomerPortfolio
SELECT
      BusinessDate
    , SourceSystemCode
    , SourceAccountNumber
    , CustomerId
    , CustomerName
    , CustomerCategory
    , BranchCode
    , ProductCode
    , ProductDescription
    , ProductCategory
    , RegulatoryCategory
    , CurrencyCode
    , ExchangeRate
    , AccountBalance
    , BaseCurrencyBalance
    , AccountStatus
    , EligibleForReporting
    , PortfolioValueBand
    , HighValueCustomer
    , ProductCount
    , CreatedDate
    , LastUpdatedDate
    , @SnapshotTime AS BaselineCaptureDate
INTO dbo.Baseline_CustomerPortfolio
FROM Warehouse.CustomerPortfolio
WHERE BusinessDate = @BusinessDate;

PRINT 'CustomerPortfolio baseline created.';

-- Capture CustomerPortfolioExceptions
SELECT
      BusinessDate
    , SourceSystemCode
    , SourceAccountNumber
    , CustomerId
    , RuleCode
    , ExceptionCategory
    , ExceptionDescription
    , ExceptionValue
    , SeverityCode
    , PriorityLevel
    , SLAHours
    , EscalationRequired
    , EscalationQueue
    , BusinessArea
    , BusinessOwner
    , ExceptionHash
    , LoggedDate
    , ResolutionDueDate
    , CreatedDate
    , LastUpdatedDate
    , @SnapshotTime AS BaselineCaptureDate
INTO dbo.Baseline_CustomerPortfolioExceptions
FROM Warehouse.CustomerPortfolioExceptions
WHERE BusinessDate = @BusinessDate;

PRINT 'CustomerPortfolioExceptions baseline created.';

-- Capture PortfolioExceptionReport
SELECT
      BusinessDate
    , KPIName
    , KPIValue
    , KPIStatus
    , CreatedDate
    , @SnapshotTime AS BaselineCaptureDate
INTO dbo.Baseline_PortfolioExceptionReport
FROM Reporting.PortfolioExceptionReport
WHERE BusinessDate = @BusinessDate;

PRINT 'PortfolioExceptionReport baseline created.';
PRINT '';

-- Summary
PRINT '=================================================================';
PRINT 'BASELINE CAPTURE SUMMARY';
PRINT '=================================================================';

DECLARE @Count INT;

SELECT @Count = COUNT(*) FROM dbo.Baseline_CustomerMaster;
PRINT 'dbo.Baseline_CustomerMaster: ' + CAST(@Count AS VARCHAR(20));

SELECT @Count = COUNT(*) FROM dbo.Baseline_CustomerPortfolio;
PRINT 'dbo.Baseline_CustomerPortfolio: ' + CAST(@Count AS VARCHAR(20));

SELECT @Count = COUNT(*) FROM dbo.Baseline_CustomerPortfolioExceptions;
PRINT 'dbo.Baseline_CustomerPortfolioExceptions: ' + CAST(@Count AS VARCHAR(20));

SELECT @Count = COUNT(*) FROM dbo.Baseline_PortfolioExceptionReport;
PRINT 'dbo.Baseline_PortfolioExceptionReport: ' + CAST(@Count AS VARCHAR(20));

PRINT '';
PRINT '=================================================================';
PRINT 'BASELINE CAPTURE COMPLETE.';
PRINT '=================================================================';
GO