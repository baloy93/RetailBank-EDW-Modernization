USE RetailBank_EDW;
GO

/******************************************************************************
  RetailBank EDW - End-to-End Test Script
  Date: 11 August 2026

  WHAT DOES THIS SCRIPT DO?
  -------------------------
  Tests all 5 stored procedures in sequence, simulating a complete nightly
  ETL batch run.

  TEST SEQUENCE:
  -------------
  1. usp_LoadCustomerMaster
  2. usp_LoadCustomerMasterExceptions
  3. usp_LoadCustomerPortfolio
  4. usp_LoadCustomerPortfolioExceptions
  5. usp_LoadPortfolioExceptionReport
******************************************************************************/

SET NOCOUNT ON;
GO

DECLARE @TestDate DATE = '2026-01-31';

PRINT '=================================================================';
PRINT 'RetailBank EDW - End-to-End Test';
PRINT '=================================================================';
PRINT 'Start Time: ' + CAST(GETDATE() AS VARCHAR(30));
PRINT '';

/* ============================================================
   SECTION 1 - RUN PROCEDURES
   ============================================================ */

PRINT 'Running usp_LoadCustomerMaster...';
EXEC Warehouse.usp_LoadCustomerMaster
    @BusinessDate = @TestDate,
    @LoadType = 'FULL',
    @EnableLogging = 1,
    @EnableDataQuality = 1,
    @Debug = 0;
PRINT '';

PRINT 'Running usp_LoadCustomerMasterExceptions...';
EXEC Warehouse.usp_LoadCustomerMasterExceptions
    @BusinessDate = @TestDate,
    @EnableLogging = 1,
    @Debug = 0;
PRINT '';

PRINT 'Running usp_LoadCustomerPortfolio...';
EXEC Warehouse.usp_LoadCustomerPortfolio
    @BusinessDate = @TestDate,
    @EnableLogging = 1,
    @LoadType = 'FULL',
    @Debug = 0;
PRINT '';

PRINT 'Running usp_LoadCustomerPortfolioExceptions...';
EXEC Warehouse.usp_LoadCustomerPortfolioExceptions
    @BusinessDate = @TestDate,
    @EnableLogging = 1,
    @Debug = 0;
PRINT '';

PRINT 'Running usp_LoadPortfolioExceptionReport...';
EXEC Warehouse.usp_LoadPortfolioExceptionReport
    @BusinessDate = @TestDate,
    @EnableLogging = 1,
    @Debug = 0;
PRINT '';

/* ============================================================
   SECTION 2 - DISPLAY RESULTS
   ============================================================ */

PRINT '=================================================================';
PRINT 'Table Counts:';
PRINT '=================================================================';

DECLARE @RowCount INT;

SELECT @RowCount = COUNT(*) FROM Warehouse.CustomerMaster;
PRINT 'Warehouse.CustomerMaster: ' + CAST(@RowCount AS VARCHAR(20));

SELECT @RowCount = COUNT(*) FROM Warehouse.CustomerMasterExceptions;
PRINT 'Warehouse.CustomerMasterExceptions: ' + CAST(@RowCount AS VARCHAR(20));

SELECT @RowCount = COUNT(*) FROM Warehouse.CustomerPortfolio;
PRINT 'Warehouse.CustomerPortfolio: ' + CAST(@RowCount AS VARCHAR(20));

SELECT @RowCount = COUNT(*) FROM Warehouse.CustomerPortfolioExceptions;
PRINT 'Warehouse.CustomerPortfolioExceptions: ' + CAST(@RowCount AS VARCHAR(20));

SELECT @RowCount = COUNT(*) FROM Warehouse.PortfolioErrors;
PRINT 'Warehouse.PortfolioErrors: ' + CAST(@RowCount AS VARCHAR(20));

SELECT @RowCount = COUNT(*) FROM Reporting.PortfolioExceptionReport;
PRINT 'Reporting.PortfolioExceptionReport: ' + CAST(@RowCount AS VARCHAR(20));

PRINT '';
PRINT '=================================================================';
PRINT 'Audit Log:';
PRINT '=================================================================';

SELECT
      ProcedureName
    , BusinessDate
    , Status
    , RowsRead
    , RowsInserted
    , RowsUpdated
    , RowsRejected
    , DurationSeconds
    , Message
FROM Audit.ETLExecutionLog
WHERE BusinessDate = @TestDate
ORDER BY StartTime DESC;

PRINT '';
PRINT '=================================================================';
PRINT 'End Time: ' + CAST(GETDATE() AS VARCHAR(30));
PRINT '=================================================================';
GO