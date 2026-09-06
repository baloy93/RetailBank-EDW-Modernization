USE RetailBank_EDW;
GO

/******************************************************************************
  RetailBank EDW - Customer Portfolio Exceptions Load Procedure
  Procedure: Warehouse.usp_LoadCustomerPortfolioExceptions
  Version:   2.0 (Corrected Schema Compatibility Release)
  Date:      10 August 2026

  WHAT DOES THIS PROCEDURE DO?
  ----------------------------
  This is Procedure 4 of 5 in the nightly ETL batch.
  It validates the Enterprise Customer Portfolio and captures all business,
  financial, and data quality exceptions.

  THE 6 DATA QUALITY RULES (DQ001-DQ006)
  --------------------------------------
  DQ001 - Customer Does Not Exist
    Accounts with CustomerId not found in Warehouse.CustomerMaster.
    Severity: HIGH (from Config.ExceptionRules)
    Business Area: Customer Operations

  DQ002 - Unknown Product
    ProductCode not found in Reference.Product.
    Severity: MEDIUM (from Config.ExceptionRules)
    Business Area: Product Management

  DQ003 - Missing Exchange Rate
    CurrencyCode not found in Reference.ExchangeRates.
    Severity: HIGH (from Config.ExceptionRules)
    Business Area: Finance

  DQ004 - Negative Portfolio
    BaseCurrencyBalance < 0.
    Severity: CRITICAL (from Config.ExceptionRules)
    Business Area: Risk

  DQ005 - Closed Account Included
    AccountStatus = 'CLOSED' AND EligibleForReporting = 'Y'.
    Severity: HIGH (from Config.ExceptionRules)
    Business Area: Operations

  DQ006 - Duplicate Account
    Same SourceAccountNumber appears multiple times.
    Severity: CRITICAL (from Config.ExceptionRules)
    Business Area: Data Governance

  HOW IT WORKS (THE PIPELINE)
  ---------------------------
  Step 1: Read Enterprise Portfolio from Warehouse.CustomerPortfolio
  Step 2: Read Exception Configuration from Config.ExceptionRules
  Step 3: Read Business Owners from Config.BusinessOwner
  Step 4: Execute DQ001-DQ006 validation rules
  Step 5: Remove duplicate exceptions (keep latest by LoggedDate)
  Step 6: Calculate priority, SLA, escalation based on severity
  Step 7: Generate SHA256 hash for duplicate detection
  Step 8: Determine escalation queue based on severity
  Step 9: MERGE into Warehouse.CustomerPortfolioExceptions
  Step 10: Write execution summary to Audit.PortfolioExceptionExecutionSummary
  Step 11: Write business area summary to Audit.BusinessAreaExceptionSummary
  Step 12: Update audit logs

  FIXES IN THIS VERSION
  ---------------------
  FIX 1 - Config table references
    Config.ExceptionRules now has authoritative values (FIX #10)
    Config.BusinessOwner values aligned (FIX #11)

  FIX 2 - ExceptionCategory columns
    Config.ExceptionCategory now has DefaultSeverity + BusinessArea (FIX #3)
    Procedure 2 already uses these; Procedure 4 uses ExceptionRules table

  FIX 3 - Audit table names
    Audit.PortfolioExceptionExecutionSummary is correctly referenced

  FIX 4 - ExceptionHash column
    SHA256 hash generated for duplicate detection (already in procedure)

  FIX 5 - Column count match
    All 20+ columns in MERGE match corrected schema

  WHAT WAS NOT CHANGED
  --------------------
  - Business logic for all 6 DQ rules
  - Severity/SLA/escalation mapping (hardcoded, preserved)
  - MERGE ON condition (ExceptionHash)
  - Transaction and error handling
  - Audit logging structure
******************************************************************************/

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE Warehouse.usp_LoadCustomerPortfolioExceptions
(
      @BusinessDate     DATE                -- The business date being processed
    , @EnableLogging    BIT = 1             -- 1 = write audit rows, 0 = skip
    , @Debug            BIT = 0             -- 1 = print debug info, 0 = silent
)
AS
BEGIN
    SET NOCOUNT ON;      -- Stops SQL Server sending "X rows affected" after every statement
    SET XACT_ABORT ON;   -- If ANY error happens, automatically roll back the transaction

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ============================================================
           SECTION A - VARIABLES
           ============================================================ */
        -- Think of these as your "scratchpad" variables.
        -- They hold numbers and messages that you will report at the end.

        DECLARE @ExecutionId     UNIQUEIDENTIFIER = NEWID();
            -- NEWID() creates a unique GUID (like a flight number).
            -- Every audit row uses this same ID so you can trace the whole run.

        DECLARE @ProcedureName     SYSNAME = OBJECT_NAME(@@PROCID);
            -- @@PROCID is the internal ID of this procedure.
            -- OBJECT_NAME turns it into 'usp_LoadCustomerPortfolioExceptions'.

        DECLARE @StartTime         DATETIME2(3) = SYSDATETIME();
        DECLARE @EndTime           DATETIME2(3);
        DECLARE @ExecutionSeconds  INT;
        DECLARE @Status            VARCHAR(20) = 'RUNNING';
        DECLARE @ExecutionMessage  NVARCHAR(4000);

        DECLARE @RowsRead          INT = 0;
        DECLARE @RowsInserted      INT = 0;
        DECLARE @RowsRejected      INT = 0;
        DECLARE @DuplicateExceptionsRemoved INT = 0;


        /* ============================================================
           SECTION B - WRITE THE INITIAL AUDIT LOG ROW
           ============================================================ */
        -- Every flight needs a boarding pass BEFORE takeoff.
        -- We INSERT first, then UPDATE later.

        IF @EnableLogging = 1
        BEGIN
            INSERT INTO Audit.ETLExecutionLog
            (
                  ExecutionId
                , ProcedureName
                , BusinessDate
                , StartTime
                , Status
            )
            VALUES
            (
                  @ExecutionId
                , @ProcedureName
                , @BusinessDate
                , @StartTime
                , @Status          -- 'RUNNING' at this point
            );
        END;


        /* ============================================================
           SECTION C - READ CUSTOMER PORTFOLIO
           ============================================================ */
        -- We need the portfolio data that Procedure 3 loaded.
        -- This is what we will validate against the 6 DQ rules.

        IF OBJECT_ID('tempdb..#CustomerPortfolio') IS NOT NULL
            DROP TABLE #CustomerPortfolio;

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
        INTO #CustomerPortfolio
        FROM Warehouse.CustomerPortfolio
        WHERE BusinessDate = @BusinessDate;

        -- Count how many rows we pulled from the portfolio
        SELECT @RowsRead = COUNT(*) FROM #CustomerPortfolio;

        IF @Debug = 1
        BEGIN
            PRINT 'Customer Portfolio Loaded';
            SELECT
                  COUNT(*) AS Accounts
                , COUNT(DISTINCT CustomerId) AS Customers
            FROM #CustomerPortfolio;
        END;


        /* ============================================================
           SECTION D - READ EXCEPTION CONFIGURATION
           ============================================================ */
        -- FIX #10: Config.ExceptionRules now has authoritative values
        -- This table tells us which DQ rules are active and how to classify them.

        IF OBJECT_ID('tempdb..#ExceptionRules') IS NOT NULL
            DROP TABLE #ExceptionRules;

        SELECT
              RuleCode
            , ExceptionCategory
            , SeverityCode
            , BusinessArea
            , RuleEnabled
        INTO #ExceptionRules
        FROM Config.ExceptionRules
        WHERE RuleEnabled = 1;

        -- FIX #11: Config.BusinessOwner values aligned
        -- Maps BusinessArea to the named owner and support team.

        IF OBJECT_ID('tempdb..#BusinessOwners') IS NOT NULL
            DROP TABLE #BusinessOwners;

        SELECT
              BusinessArea
            , BusinessOwner
            , SupportTeam
        INTO #BusinessOwners
        FROM Config.BusinessOwner;


        /* ============================================================
           SECTION E - CREATE EXCEPTION STAGING TABLE
           ============================================================ */
        -- This is where we collect validation results before
        -- deduplication and enrichment.

        IF OBJECT_ID('tempdb..#PortfolioExceptionStage') IS NOT NULL
            DROP TABLE #PortfolioExceptionStage;

        CREATE TABLE #PortfolioExceptionStage
        (
              BusinessDate          DATE
            , SourceSystemCode      VARCHAR(50)
            , SourceAccountNumber   VARCHAR(100)
            , CustomerId            VARCHAR(50)
            , RuleCode              VARCHAR(50)
            , ExceptionCategory     VARCHAR(100)
            , ExceptionDescription  NVARCHAR(500)
            , ExceptionValue        NVARCHAR(200)
            , SeverityCode          VARCHAR(20)
            , BusinessArea          VARCHAR(100)
            , BusinessOwner         VARCHAR(100)
            , LoggedDate            DATETIME2(3)
        );


        /* ============================================================
           SECTION F - VALIDATION RULE DQ001
           CUSTOMER DOES NOT EXIST
           ============================================================ */
        /*  Business Rule:
            Every account must belong to a valid customer.
            If CustomerId is not found in Warehouse.CustomerMaster,
            this is a CRITICAL data quality issue.

            Severity: From Config.ExceptionRules (DQ001 = HIGH)
            Business Area: Customer Operations
        */

        INSERT INTO #PortfolioExceptionStage
        (
              BusinessDate
            , SourceSystemCode
            , SourceAccountNumber
            , CustomerId
            , RuleCode
            , ExceptionCategory
            , ExceptionDescription
            , ExceptionValue
            , SeverityCode
            , BusinessArea
            , BusinessOwner
            , LoggedDate
        )
        SELECT
              P.BusinessDate
            , P.SourceSystemCode
            , P.SourceAccountNumber
            , P.CustomerId
            , 'DQ001'
            , R.ExceptionCategory
            , 'Customer not found in Customer Master'
            , P.CustomerId
            , R.SeverityCode
            , R.BusinessArea
            , O.BusinessOwner
            , GETDATE()
        FROM #CustomerPortfolio P
        INNER JOIN #ExceptionRules R
            ON R.RuleCode = 'DQ001'
        LEFT JOIN #BusinessOwners O
            ON R.BusinessArea = O.BusinessArea
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM Warehouse.CustomerMaster C
            WHERE C.CustomerId = P.CustomerId
        );


        /* ============================================================
           SECTION G - VALIDATION RULE DQ002
           UNKNOWN PRODUCT
           ============================================================ */
        /*  Business Rule:
            Every product code must exist in Reference.Product.
            If ProductCode is not found, this is a MEDIUM severity issue.

            Severity: From Config.ExceptionRules (DQ002 = MEDIUM)
            Business Area: Product Management
        */

        INSERT INTO #PortfolioExceptionStage
        (
              BusinessDate
            , SourceSystemCode
            , SourceAccountNumber
            , CustomerId
            , RuleCode
            , ExceptionCategory
            , ExceptionDescription
            , ExceptionValue
            , SeverityCode
            , BusinessArea
            , BusinessOwner
            , LoggedDate
        )
        SELECT
              P.BusinessDate
            , P.SourceSystemCode
            , P.SourceAccountNumber
            , P.CustomerId
            , 'DQ002'
            , R.ExceptionCategory
            , 'Unknown Product'
            , P.ProductCode
            , R.SeverityCode
            , R.BusinessArea
            , O.BusinessOwner
            , GETDATE()
        FROM #CustomerPortfolio P
        INNER JOIN #ExceptionRules R
            ON R.RuleCode = 'DQ002'
        LEFT JOIN #BusinessOwners O
            ON R.BusinessArea = O.BusinessArea
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM Reference.Product PR
            WHERE PR.ProductCode = P.ProductCode
        );


        /* ============================================================
           SECTION H - VALIDATION RULE DQ003
           MISSING EXCHANGE RATE
           ============================================================ */
        /*  Business Rule:
            Every account must have an exchange rate to convert to USD.
            If ExchangeRate is NULL, this is a HIGH severity issue.

            Severity: From Config.ExceptionRules (DQ003 = HIGH)
            Business Area: Finance
        */

        INSERT INTO #PortfolioExceptionStage
        (
              BusinessDate
            , SourceSystemCode
            , SourceAccountNumber
            , CustomerId
            , RuleCode
            , ExceptionCategory
            , ExceptionDescription
            , ExceptionValue
            , SeverityCode
            , BusinessArea
            , BusinessOwner
            , LoggedDate
        )
        SELECT
              P.BusinessDate
            , P.SourceSystemCode
            , P.SourceAccountNumber
            , P.CustomerId
            , 'DQ003'
            , R.ExceptionCategory
            , 'Exchange Rate Missing'
            , P.CurrencyCode
            , R.SeverityCode
            , R.BusinessArea
            , O.BusinessOwner
            , GETDATE()
        FROM #CustomerPortfolio P
        INNER JOIN #ExceptionRules R
            ON R.RuleCode = 'DQ003'
        LEFT JOIN #BusinessOwners O
            ON R.BusinessArea = O.BusinessArea
        WHERE P.ExchangeRate IS NULL;


        /* ============================================================
           SECTION I - VALIDATION RULE DQ004
           NEGATIVE PORTFOLIO
           ============================================================ */
        /*  Business Rule:
            Portfolio balances must not be negative.
            If BaseCurrencyBalance < 0, this is a CRITICAL issue.

            Severity: From Config.ExceptionRules (DQ004 = CRITICAL)
            Business Area: Risk
        */

        INSERT INTO #PortfolioExceptionStage
        (
              BusinessDate
            , SourceSystemCode
            , SourceAccountNumber
            , CustomerId
            , RuleCode
            , ExceptionCategory
            , ExceptionDescription
            , ExceptionValue
            , SeverityCode
            , BusinessArea
            , BusinessOwner
            , LoggedDate
        )
        SELECT
              P.BusinessDate
            , P.SourceSystemCode
            , P.SourceAccountNumber
            , P.CustomerId
            , 'DQ004'
            , R.ExceptionCategory
            , 'Negative Portfolio Balance'
            , CAST(P.BaseCurrencyBalance AS VARCHAR(50))
            , R.SeverityCode
            , R.BusinessArea
            , O.BusinessOwner
            , GETDATE()
        FROM #CustomerPortfolio P
        INNER JOIN #ExceptionRules R
            ON R.RuleCode = 'DQ004'
        LEFT JOIN #BusinessOwners O
            ON R.BusinessArea = O.BusinessArea
        WHERE P.BaseCurrencyBalance < 0;


        /* ============================================================
           SECTION J - VALIDATION RULE DQ005
           CLOSED ACCOUNT INCLUDED
           ============================================================ */
        /*  Business Rule:
            Closed accounts should not appear in active reporting.
            If AccountStatus = 'CLOSED' AND EligibleForReporting = 'Y',
            this is a HIGH severity issue.

            Severity: From Config.ExceptionRules (DQ005 = HIGH)
            Business Area: Operations
        */

        INSERT INTO #PortfolioExceptionStage
        (
              BusinessDate
            , SourceSystemCode
            , SourceAccountNumber
            , CustomerId
            , RuleCode
            , ExceptionCategory
            , ExceptionDescription
            , ExceptionValue
            , SeverityCode
            , BusinessArea
            , BusinessOwner
            , LoggedDate
        )
        SELECT
              P.BusinessDate
            , P.SourceSystemCode
            , P.SourceAccountNumber
            , P.CustomerId
            , 'DQ005'
            , R.ExceptionCategory
            , 'Closed Account Eligible For Reporting'
            , P.AccountStatus
            , R.SeverityCode
            , R.BusinessArea
            , O.BusinessOwner
            , GETDATE()
        FROM #CustomerPortfolio P
        INNER JOIN #ExceptionRules R
            ON R.RuleCode = 'DQ005'
        LEFT JOIN #BusinessOwners O
            ON R.BusinessArea = O.BusinessArea
        WHERE
            AccountStatus = 'CLOSED'
            AND EligibleForReporting = 'Y';


        /* ============================================================
           SECTION K - VALIDATION RULE DQ006
           DUPLICATE ACCOUNT
           ============================================================ */
        /*  Business Rule:
            Each SourceAccountNumber should appear only once.
            If the same account number appears multiple times,
            this is a CRITICAL issue.

            Severity: From Config.ExceptionRules (DQ006 = CRITICAL)
            Business Area: Data Governance
        */

        ;WITH DuplicateAccounts
        AS
        (
            SELECT
                  SourceAccountNumber
                , COUNT(*) AS DuplicateCount
            FROM #CustomerPortfolio
            GROUP BY SourceAccountNumber
            HAVING COUNT(*) > 1
        )
        INSERT INTO #PortfolioExceptionStage
        (
              BusinessDate
            , SourceSystemCode
            , SourceAccountNumber
            , CustomerId
            , RuleCode
            , ExceptionCategory
            , ExceptionDescription
            , ExceptionValue
            , SeverityCode
            , BusinessArea
            , BusinessOwner
            , LoggedDate
        )
        SELECT
              P.BusinessDate
            , P.SourceSystemCode
            , P.SourceAccountNumber
            , P.CustomerId
            , 'DQ006'
            , R.ExceptionCategory
            , 'Duplicate Source Account'
            , P.SourceAccountNumber
            , R.SeverityCode
            , R.BusinessArea
            , O.BusinessOwner
            , GETDATE()
        FROM #CustomerPortfolio P
        INNER JOIN DuplicateAccounts D
            ON P.SourceAccountNumber = D.SourceAccountNumber
        INNER JOIN #ExceptionRules R
            ON R.RuleCode = 'DQ006'
        LEFT JOIN #BusinessOwners O
            ON R.BusinessArea = O.BusinessArea;

        -- Debug: Show validation summary by rule
        IF @Debug = 1
        BEGIN
            PRINT 'Validation Summary';
            SELECT
                  RuleCode
                , COUNT(*) AS ExceptionCount
            FROM #PortfolioExceptionStage
            GROUP BY RuleCode
            ORDER BY RuleCode;
        END;


        /* ============================================================
           SECTION L - REMOVE DUPLICATE EXCEPTIONS
           ============================================================ */
        /*  Business Rule:
            If the same exception is detected multiple times on the same day,
            we only keep the latest occurrence.

            This prevents the exception repository from being flooded with
            duplicate entries.
        */

        IF OBJECT_ID('tempdb..#PortfolioExceptions') IS NOT NULL
            DROP TABLE #PortfolioExceptions;

        ;WITH RankedExceptions
        AS
        (
            SELECT
                  *
                , ROW_NUMBER()
                  OVER
                  (
                      PARTITION BY
                          BusinessDate
                        , CustomerId
                        , RuleCode
                        , ExceptionValue
                      ORDER BY LoggedDate DESC
                  ) AS RowNumber
            FROM #PortfolioExceptionStage
        )
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
            , BusinessArea
            , BusinessOwner
            , LoggedDate
        INTO #PortfolioExceptions
        FROM RankedExceptions
        WHERE RowNumber = 1;

        -- Capture how many duplicates were removed
        SELECT @DuplicateExceptionsRemoved =
            (SELECT COUNT(*) FROM #PortfolioExceptionStage)
            - (SELECT COUNT(*) FROM #PortfolioExceptions);


        /* ============================================================
           SECTION M - CALCULATE EXCEPTION PRIORITY & SLA
           ============================================================ */
        /*  Business Rules:
            Each severity level maps to a priority, SLA hours, and
            escalation requirement.

            CRITICAL → Priority 1, 2 hours SLA, Escalate immediately
            HIGH     → Priority 2, 8 hours SLA, Escalate
            MEDIUM   → Priority 3, 24 hours SLA, No escalation
            LOW      → Priority 4, 72 hours SLA, No escalation

            NOTE: This logic is preserved from the original procedure.
            It could be metadata-driven in a future enhancement.
        */

        ALTER TABLE #PortfolioExceptions
        ADD
              PriorityLevel       INT
            , SLAHours            INT
            , EscalationRequired  BIT
            , ResolutionDueDate   DATETIME2(3)
            , ExceptionHash       VARCHAR(64);

        UPDATE #PortfolioExceptions
        SET
            PriorityLevel =
                CASE
                    WHEN SeverityCode = 'CRITICAL' THEN 1
                    WHEN SeverityCode = 'HIGH'      THEN 2
                    WHEN SeverityCode = 'MEDIUM'    THEN 3
                    ELSE 4
                END,
            SLAHours =
                CASE
                    WHEN SeverityCode = 'CRITICAL' THEN 2
                    WHEN SeverityCode = 'HIGH'      THEN 8
                    WHEN SeverityCode = 'MEDIUM'    THEN 24
                    ELSE 72
                END,
            EscalationRequired =
                CASE
                    WHEN SeverityCode IN ('CRITICAL', 'HIGH')
                    THEN 1
                    ELSE 0
                END;


        /* ============================================================
           SECTION N - CALCULATE RESOLUTION DUE DATE
           ============================================================ */
        -- ResolutionDueDate = LoggedDate + SLAHours
        -- This is when the exception must be fixed by.

        UPDATE #PortfolioExceptions
        SET ResolutionDueDate =
            DATEADD(HOUR, SLAHours, LoggedDate);


        /* ============================================================
           SECTION O - GENERATE EXCEPTION HASH
           ============================================================ */
        -- SHA256 hash prevents duplicate exceptions from being loaded.
        -- If the same BusinessDate + CustomerId + RuleCode + ExceptionValue
        -- appears, the hash will match and the MERGE will UPDATE instead of INSERT.

        UPDATE #PortfolioExceptions
        SET ExceptionHash =
            CONVERT
            (
                VARCHAR(64),
                HASHBYTES
                (
                    'SHA2_256',
                    CONCAT
                    (
                        BusinessDate,
                        CustomerId,
                        RuleCode,
                        ExceptionValue
                    )
                ),
                2
            );


        /* ============================================================
           SECTION P - DETERMINE ESCALATION QUEUE
           ============================================================ */
        -- EscalationQueue is used by the operations team to route
        -- exceptions to the correct support queue.

        ALTER TABLE #PortfolioExceptions
        ADD EscalationQueue VARCHAR(100);

        UPDATE #PortfolioExceptions
        SET EscalationQueue =
            CASE
                WHEN SeverityCode = 'CRITICAL'
                THEN 'Immediate Response'
                WHEN SeverityCode = 'HIGH'
                THEN 'Priority Queue'
                WHEN SeverityCode = 'MEDIUM'
                THEN 'Standard Queue'
                ELSE 'Low Priority Queue'
            END;

        IF @Debug = 1
        BEGIN
            PRINT 'Enterprise Exception Summary';
            SELECT
                  SeverityCode
                , COUNT(*) AS TotalExceptions
            FROM #PortfolioExceptions
            GROUP BY SeverityCode
            ORDER BY
                CASE SeverityCode
                    WHEN 'CRITICAL' THEN 1
                    WHEN 'HIGH'     THEN 2
                    WHEN 'MEDIUM'   THEN 3
                    ELSE 4
                END;

            PRINT CONCAT('Duplicate Exceptions Removed: ', @DuplicateExceptionsRemoved);
        END;


        /* ============================================================
           SECTION Q - MERGE INTO WAREHOUSE.CUSTOMERPORTFOLIOEXCEPTIONS
           ============================================================ */
        /*  Business Rules:
            Existing Exception:
                UPDATE when severity, owner, SLA, queue, or description changes.

            New Exception:
                INSERT.

            Resolved Exceptions:
                Remain for historical reporting.

            No deletes occur during daily processing.
            Historical exceptions are never deleted.
        */

        MERGE Warehouse.CustomerPortfolioExceptions AS TARGET
        USING
        (
            SELECT * FROM #PortfolioExceptions
        ) AS SOURCE
        ON
            TARGET.BusinessDate = SOURCE.BusinessDate
            AND TARGET.ExceptionHash = SOURCE.ExceptionHash

        WHEN MATCHED
        AND
        (
               ISNULL(TARGET.SeverityCode, '')    <> ISNULL(SOURCE.SeverityCode, '')
            OR ISNULL(TARGET.BusinessOwner, '')   <> ISNULL(SOURCE.BusinessOwner, '')
            OR ISNULL(TARGET.PriorityLevel, 0)    <> ISNULL(SOURCE.PriorityLevel, 0)
            OR ISNULL(TARGET.SLAHours, 0)         <> ISNULL(SOURCE.SLAHours, 0)
            OR ISNULL(TARGET.EscalationQueue, '') <> ISNULL(SOURCE.EscalationQueue, '')
            OR ISNULL(TARGET.ExceptionDescription, '') <> ISNULL(SOURCE.ExceptionDescription, '')
        )
        THEN UPDATE
        SET
              TARGET.ExceptionDescription = SOURCE.ExceptionDescription
            , TARGET.SeverityCode         = SOURCE.SeverityCode
            , TARGET.PriorityLevel        = SOURCE.PriorityLevel
            , TARGET.SLAHours             = SOURCE.SLAHours
            , TARGET.BusinessArea         = SOURCE.BusinessArea
            , TARGET.BusinessOwner        = SOURCE.BusinessOwner
            , TARGET.EscalationQueue      = SOURCE.EscalationQueue
            , TARGET.ResolutionDueDate    = SOURCE.ResolutionDueDate
            , TARGET.LastUpdatedDate      = GETDATE()

        WHEN NOT MATCHED BY TARGET
        THEN INSERT
        (
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
        )
        VALUES
        (
              SOURCE.BusinessDate
            , SOURCE.SourceSystemCode
            , SOURCE.SourceAccountNumber
            , SOURCE.CustomerId
            , SOURCE.RuleCode
            , SOURCE.ExceptionCategory
            , SOURCE.ExceptionDescription
            , SOURCE.ExceptionValue
            , SOURCE.SeverityCode
            , SOURCE.PriorityLevel
            , SOURCE.SLAHours
            , SOURCE.EscalationRequired
            , SOURCE.EscalationQueue
            , SOURCE.BusinessArea
            , SOURCE.BusinessOwner
            , SOURCE.ExceptionHash
            , SOURCE.LoggedDate
            , SOURCE.ResolutionDueDate
            , GETDATE()
            , GETDATE()
        );

        -- Capture how many exceptions were loaded
        SELECT @RowsInserted = COUNT(*) FROM #PortfolioExceptions;


        /* ============================================================
           SECTION R - BUILD DASHBOARD SUMMARIES
           ============================================================ */

        -- Exception Dashboard: Severity + Business Area breakdown
        IF OBJECT_ID('tempdb..#ExceptionDashboard') IS NOT NULL
            DROP TABLE #ExceptionDashboard;

        SELECT
              SeverityCode
            , BusinessArea
            , COUNT(*) AS ExceptionCount
            , SUM
              (
                  CASE
                      WHEN EscalationRequired = 1
                      THEN 1
                      ELSE 0
                  END
              ) AS Escalated
        INTO #ExceptionDashboard
        FROM #PortfolioExceptions
        GROUP BY SeverityCode, BusinessArea;

        -- Business Owner Work Queue: Who has the most exceptions?
        IF OBJECT_ID('tempdb..#BusinessOwnerQueue') IS NOT NULL
            DROP TABLE #BusinessOwnerQueue;

        SELECT
              BusinessOwner
            , COUNT(*) AS AssignedExceptions
            , MIN(ResolutionDueDate) AS NextDueDate
        INTO #BusinessOwnerQueue
        FROM #PortfolioExceptions
        GROUP BY BusinessOwner;

        IF @Debug = 1
        BEGIN
            PRINT 'Portfolio Exception Dashboard';
            SELECT * FROM #ExceptionDashboard;

            PRINT 'Business Owner Queue';
            SELECT * FROM #BusinessOwnerQueue;
        END;


        /* ============================================================
           SECTION S - FINALISE AUDIT
           ============================================================ */

        SET @EndTime = SYSDATETIME();
        SET @ExecutionSeconds = DATEDIFF(SECOND, @StartTime, @EndTime);
        SET @Status = 'SUCCESS';
        SET @ExecutionMessage =
            CONCAT
            (
                'Portfolio Exception Processing Completed. ',
                'Exceptions Identified: ', @RowsInserted,
                ', Records Read: ', @RowsRead,
                ', Duplicates Removed: ', @DuplicateExceptionsRemoved,
                ', Processing Time: ', @ExecutionSeconds, ' seconds.'
            );

        -- Update the audit row we created at the start
        IF @EnableLogging = 1
        BEGIN
            UPDATE Audit.ETLExecutionLog
            SET
                  EndTime         = @EndTime
                , Status          = @Status
                , RowsRead        = @RowsRead
                , RowsInserted    = @RowsInserted
                , RowsRejected    = @RowsRejected
                , DurationSeconds = @ExecutionSeconds
                , Message         = @ExecutionMessage
            WHERE ExecutionId = @ExecutionId;
        END;

        -- Write daily exception metrics to Audit.PortfolioExceptionExecutionSummary
        INSERT INTO Audit.PortfolioExceptionExecutionSummary
        (
              BusinessDate
            , ExecutionId
            , ProcedureName
            , TotalExceptions
            , CriticalExceptions
            , HighExceptions
            , MediumExceptions
            , LowExceptions
            , EscalatedExceptions
            , ExecutionSeconds
            , CreatedDate
        )
        SELECT
              @BusinessDate
            , @ExecutionId
            , @ProcedureName
            , COUNT(*)
            , SUM(CASE WHEN SeverityCode = 'CRITICAL' THEN 1 ELSE 0 END)
            , SUM(CASE WHEN SeverityCode = 'HIGH'      THEN 1 ELSE 0 END)
            , SUM(CASE WHEN SeverityCode = 'MEDIUM'    THEN 1 ELSE 0 END)
            , SUM(CASE WHEN SeverityCode = 'LOW'       THEN 1 ELSE 0 END)
            , SUM(CASE WHEN EscalationRequired = 1     THEN 1 ELSE 0 END)
            , @ExecutionSeconds
            , GETDATE()
        FROM #PortfolioExceptions;

        -- Write business area dashboard metrics
        INSERT INTO Audit.BusinessAreaExceptionSummary
        (
              BusinessDate
            , BusinessArea
            , ExceptionCount
            , CriticalCount
            , CreatedDate
        )
        SELECT
              @BusinessDate
            , BusinessArea
            , COUNT(*)
            , SUM
              (
                  CASE
                      WHEN SeverityCode = 'CRITICAL'
                      THEN 1
                      ELSE 0
                  END
              )
            , GETDATE()
        FROM #PortfolioExceptions
        GROUP BY BusinessArea;


        /* ============================================================
           SECTION T - DEBUG OUTPUT
           ============================================================ */

        IF @Debug = 1
        BEGIN
            PRINT '==========================================';
            PRINT 'Portfolio Exception Load Summary';
            PRINT '==========================================';
            PRINT CONCAT('Records Read        : ', @RowsRead);
            PRINT CONCAT('Exceptions Loaded   : ', @RowsInserted);
            PRINT CONCAT('Duplicates Removed  : ', @DuplicateExceptionsRemoved);
            PRINT CONCAT('Execution Time      : ', @ExecutionSeconds);
            PRINT '------------------------------------------';

            SELECT
                  SeverityCode
                , COUNT(*) AS TotalExceptions
            FROM #PortfolioExceptions
            GROUP BY SeverityCode
            ORDER BY
                CASE SeverityCode
                    WHEN 'CRITICAL' THEN 1
                    WHEN 'HIGH'     THEN 2
                    WHEN 'MEDIUM'   THEN 3
                    ELSE 4
                END;
        END;


        /* ============================================================
           SECTION U - CLEANUP TEMPORARY OBJECTS
           ============================================================ */

        DROP TABLE IF EXISTS #CustomerPortfolio;
        DROP TABLE IF EXISTS #ExceptionRules;
        DROP TABLE IF EXISTS #BusinessOwners;
        DROP TABLE IF EXISTS #PortfolioExceptionStage;
        DROP TABLE IF EXISTS #PortfolioExceptions;
        DROP TABLE IF EXISTS #ExceptionDashboard;
        DROP TABLE IF EXISTS #BusinessOwnerQueue;


        /* ============================================================
           SECTION V - COMMIT TRANSACTION
           ============================================================ */

        COMMIT TRANSACTION;

    END TRY

    BEGIN CATCH

        /* ============================================================
           SECTION W - ERROR HANDLING
           ============================================================ */

        -- Rollback if transaction is still active
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @EndTime = SYSDATETIME();
        SET @Status = 'FAILED';
        SET @ExecutionMessage =
            CONCAT
            (
                'Error ', ERROR_NUMBER(),
                ' : ', ERROR_MESSAGE()
            );

        -- Update audit log with failure information
        IF @EnableLogging = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM Audit.ETLExecutionLog WHERE ExecutionId = @ExecutionId)
            BEGIN
                INSERT INTO Audit.ETLExecutionLog
                (
                      ExecutionId
                    , ProcedureName
                    , BusinessDate
                    , StartTime
                    , Status
                    , Message
                    , DurationSeconds
                )
                VALUES
                (
                      @ExecutionId
                    , @ProcedureName
                    , @BusinessDate
                    , @StartTime
                    , @Status
                    , @ExecutionMessage
                    , DATEDIFF(SECOND, @StartTime, @EndTime)
                );
            END
            ELSE
            BEGIN
                UPDATE Audit.ETLExecutionLog
                SET
                      EndTime = @EndTime
                    , Status = @Status
                    , Message = @ExecutionMessage
                    , DurationSeconds = DATEDIFF(SECOND, @StartTime, @EndTime)
                WHERE ExecutionId = @ExecutionId;
            END;
        END;

        -- Cleanup temporary objects
        DROP TABLE IF EXISTS #CustomerPortfolio;
        DROP TABLE IF EXISTS #ExceptionRules;
        DROP TABLE IF EXISTS #BusinessOwners;
        DROP TABLE IF EXISTS #PortfolioExceptionStage;
        DROP TABLE IF EXISTS #PortfolioExceptions;
        DROP TABLE IF EXISTS #ExceptionDashboard;
        DROP TABLE IF EXISTS #BusinessOwnerQueue;

        -- Re-throw the original error
        THROW;

    END CATCH;
END;
GO


/******************************************************************************
  DEPLOYMENT VERIFICATION

  -- Test execution (requires sample data in CustomerPortfolio)
  EXEC Warehouse.usp_LoadCustomerPortfolioExceptions
      @BusinessDate = '2026-01-31',
      @EnableLogging = 1,
      @Debug = 1;
******************************************************************************/
GO