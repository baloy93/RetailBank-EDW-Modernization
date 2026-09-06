USE RetailBank_EDW;
GO

-- Drop the old version if it exists
IF OBJECT_ID('Warehouse.usp_LoadPortfolioExceptionReport', 'P') IS NOT NULL
    DROP PROCEDURE Warehouse.usp_LoadPortfolioExceptionReport;
GO

/******************************************************************************
  RetailBank EDW - Portfolio Exception Report Procedure
  Procedure: Warehouse.usp_LoadPortfolioExceptionReport
  Version:   2.1 (Fixed ExceptionHash column reference)
  Date:      11 August 2026

  WHAT DOES THIS PROCEDURE DO?
  ----------------------------
  This is Procedure 5 of 5 in the nightly ETL batch.
  It builds the daily operational Portfolio Exception Report used by
  Business, Operations, Risk, Finance and Data Governance teams.

  THE 4 KPI CATEGORIES
  --------------------
  1. PORTFOLIO HEALTH
     Overall health score based on exception rate.
     EXCELLENT: < 1% exception rate
     GOOD:      1% - 3% exception rate
     FAIR:      3% - 5% exception rate
     POOR:      > 5% exception rate

  2. CRITICAL EXCEPTIONS
     Count of severity = 'CRITICAL' exceptions.
     GREEN:   < 10
     AMBER:   10 - 50
     RED:     > 50

  3. EXCEPTION RATE
     Percentage of accounts with at least one exception.
     GREEN:   < 2%
     AMBER:   2% - 5%
     RED:     > 5%

  4. SLA COMPLIANCE
     Percentage of exceptions resolved within SLA.
     GREEN:   > 95% compliance (SLA failure < 5%)
     AMBER:   85% - 95% compliance (SLA failure 5% - 15%)
     RED:     < 85% compliance (SLA failure > 15%)

  FIXES IN THIS VERSION
  ---------------------
  FIX 1 - Added ExceptionHash to #PortfolioExceptions temp table
    The procedure was trying to reference ExceptionHash but it wasn't
    being selected from Warehouse.CustomerPortfolioExceptions.

  WHAT WAS NOT CHANGED
  --------------------
  - All KPI calculation logic
  - All threshold values (GREEN/AMBER/RED)
  - TRUNCATE daily (preserved from original)
  - Transaction and error handling
  - Audit logging structure
******************************************************************************/

CREATE OR ALTER PROCEDURE Warehouse.usp_LoadPortfolioExceptionReport
(
      @BusinessDate     DATE                -- The business date being processed
    , @EnableLogging    BIT = 1             -- 1 = write audit rows, 0 = skip
    , @Debug            BIT = 0             -- 1 = print debug info, 0 = silent
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ============================================================
           SECTION A - VARIABLES
           ============================================================ */

        DECLARE @ExecutionId     UNIQUEIDENTIFIER = NEWID();
        DECLARE @ProcedureName   SYSNAME = OBJECT_NAME(@@PROCID);
        DECLARE @StartTime       DATETIME2(3) = SYSDATETIME();
        DECLARE @EndTime         DATETIME2(3);
        DECLARE @ExecutionSeconds INT;
        DECLARE @Status          VARCHAR(20) = 'RUNNING';
        DECLARE @ExecutionMessage NVARCHAR(4000);
        DECLARE @RowsInserted    INT = 0;

        DECLARE @TotalAccounts     INT;
        DECLARE @TotalCustomers    INT;
        DECLARE @TotalExceptions   INT;
        DECLARE @CriticalExceptions INT;
        DECLARE @HighExceptions    INT;
        DECLARE @MediumExceptions  INT;
        DECLARE @LowExceptions     INT;


        /* ============================================================
           SECTION B - WRITE THE INITIAL AUDIT LOG ROW
           ============================================================ */

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
                , @Status
            );
        END;


        /* ============================================================
           SECTION C - READ PORTFOLIO EXCEPTIONS
           FIX 1: Added ExceptionHash column
           ============================================================ */

        IF OBJECT_ID('tempdb..#PortfolioExceptions') IS NOT NULL
            DROP TABLE #PortfolioExceptions;

        SELECT
              BusinessDate
            , SourceSystemCode
            , SourceAccountNumber
            , CustomerId
            , RuleCode
            , ExceptionCategory
            , SeverityCode
            , BusinessArea
            , BusinessOwner
            , EscalationRequired
            , ResolutionDueDate
            , LoggedDate
            , ExceptionHash          -- FIX 1: Added this column
        INTO #PortfolioExceptions
        FROM Warehouse.CustomerPortfolioExceptions
        WHERE BusinessDate = @BusinessDate;


        /* ============================================================
           SECTION D - READ ENTERPRISE PORTFOLIO
           ============================================================ */

        IF OBJECT_ID('tempdb..#EnterprisePortfolio') IS NOT NULL
            DROP TABLE #EnterprisePortfolio;

        SELECT
              BusinessDate
            , CustomerId
            , BranchCode
            , ProductCategory
            , CustomerCategory
            , SourceSystemCode
            , SourceAccountNumber
        INTO #EnterprisePortfolio
        FROM Warehouse.CustomerPortfolio
        WHERE BusinessDate = @BusinessDate;


        /* ============================================================
           SECTION E - CALCULATE EXECUTIVE KPIs
           ============================================================ */

        SELECT
              @TotalAccounts = COUNT(*)
            , @TotalCustomers = COUNT(DISTINCT CustomerId)
        FROM #EnterprisePortfolio;

        SELECT
              @TotalExceptions = COUNT(*)
            , @CriticalExceptions = SUM(CASE WHEN SeverityCode = 'CRITICAL' THEN 1 ELSE 0 END)
            , @HighExceptions      = SUM(CASE WHEN SeverityCode = 'HIGH'      THEN 1 ELSE 0 END)
            , @MediumExceptions    = SUM(CASE WHEN SeverityCode = 'MEDIUM'    THEN 1 ELSE 0 END)
            , @LowExceptions       = SUM(CASE WHEN SeverityCode = 'LOW'       THEN 1 ELSE 0 END)
        FROM #PortfolioExceptions;


        /* ============================================================
           SECTION F - EXECUTIVE KPI TABLE
           ============================================================ */

        IF OBJECT_ID('tempdb..#ExecutiveKPIs') IS NOT NULL
            DROP TABLE #ExecutiveKPIs;

        SELECT
              @BusinessDate AS BusinessDate
            , @TotalCustomers AS TotalCustomers
            , @TotalAccounts AS TotalAccounts
            , @TotalExceptions AS TotalExceptions
            , @CriticalExceptions AS CriticalExceptions
            , @HighExceptions AS HighExceptions
            , @MediumExceptions AS MediumExceptions
            , @LowExceptions AS LowExceptions
            , CAST
              (
                  (@TotalExceptions * 100.0)
                  / NULLIF(@TotalAccounts, 0)
                  AS DECIMAL(10,2)
              ) AS ExceptionRate
            , GETDATE() AS ReportCreatedDate
        INTO #ExecutiveKPIs;


        /* ============================================================
           SECTION G - CALCULATE PORTFOLIO HEALTH
           ============================================================ */

        ALTER TABLE #ExecutiveKPIs
        ADD
              PortfolioHealth VARCHAR(20)
            , ExecutiveStatus VARCHAR(50);

        UPDATE #ExecutiveKPIs
        SET
            PortfolioHealth =
                CASE
                    WHEN ExceptionRate < 1  THEN 'EXCELLENT'
                    WHEN ExceptionRate < 3  THEN 'GOOD'
                    WHEN ExceptionRate < 5  THEN 'FAIR'
                    ELSE 'POOR'
                END,
            ExecutiveStatus =
                CASE
                    WHEN CriticalExceptions > 50 THEN 'Immediate Attention'
                    WHEN HighExceptions > 200     THEN 'Management Review'
                    ELSE 'Normal Operations'
                END;

        IF @Debug = 1
        BEGIN
            PRINT 'Executive Dashboard';
            SELECT * FROM #ExecutiveKPIs;
        END;


        /* ============================================================
           SECTION H - SOURCE SYSTEM QUALITY METRICS
           ============================================================ */

        IF OBJECT_ID('tempdb..#SourceSystemKPIs') IS NOT NULL
            DROP TABLE #SourceSystemKPIs;

        SELECT
              P.SourceSystemCode
            , COUNT(*) AS TotalAccounts
            , COUNT(E.ExceptionHash) AS TotalExceptions
            , SUM
              (
                  CASE
                      WHEN E.SeverityCode = 'CRITICAL'
                      THEN 1
                      ELSE 0
                  END
              ) AS CriticalExceptions
            , SUM
              (
                  CASE
                      WHEN E.SeverityCode = 'HIGH'
                      THEN 1
                      ELSE 0
                  END
              ) AS HighExceptions
            , CAST
              (
                  COUNT(E.ExceptionHash) * 100.0
                  / NULLIF(COUNT(*), 0)
                  AS DECIMAL(10,2)
              ) AS ExceptionRate
        INTO #SourceSystemKPIs
        FROM #EnterprisePortfolio P
        LEFT JOIN #PortfolioExceptions E
            ON  P.BusinessDate = E.BusinessDate
            AND P.SourceAccountNumber = E.SourceAccountNumber
        GROUP BY P.SourceSystemCode;


        /* ============================================================
           SECTION I - BUSINESS AREA KPIs
           ============================================================ */

        IF OBJECT_ID('tempdb..#BusinessAreaKPIs') IS NOT NULL
            DROP TABLE #BusinessAreaKPIs;

        SELECT
              BusinessArea
            , COUNT(*) AS TotalExceptions
            , SUM
              (
                  CASE
                      WHEN SeverityCode = 'CRITICAL'
                      THEN 1
                      ELSE 0
                  END
              ) AS CriticalExceptions
            , SUM
              (
                  CASE
                      WHEN EscalationRequired = 1
                      THEN 1
                      ELSE 0
                  END
              ) AS EscalatedExceptions
        INTO #BusinessAreaKPIs
        FROM #PortfolioExceptions
        GROUP BY BusinessArea;


        /* ============================================================
           SECTION J - BUSINESS OWNER WORK QUEUE
           ============================================================ */

        IF OBJECT_ID('tempdb..#BusinessOwnerKPIs') IS NOT NULL
            DROP TABLE #BusinessOwnerKPIs;

        SELECT
              BusinessOwner
            , COUNT(*) AS AssignedExceptions
            , SUM
              (
                  CASE
                      WHEN SeverityCode = 'CRITICAL'
                      THEN 1
                      ELSE 0
                  END
              ) AS CriticalExceptions
            , MIN(ResolutionDueDate) AS EarliestDueDate
            , MAX(ResolutionDueDate) AS LatestDueDate
        INTO #BusinessOwnerKPIs
        FROM #PortfolioExceptions
        GROUP BY BusinessOwner;


        /* ============================================================
           SECTION K - BRANCH QUALITY METRICS
           ============================================================ */

        IF OBJECT_ID('tempdb..#BranchKPIs') IS NOT NULL
            DROP TABLE #BranchKPIs;

        SELECT
              P.BranchCode
            , COUNT(*) AS Accounts
            , COUNT(E.ExceptionHash) AS Exceptions
            , CAST
              (
                  COUNT(E.ExceptionHash) * 100.0
                  / NULLIF(COUNT(*), 0)
                  AS DECIMAL(10,2)
              ) AS BranchExceptionRate
        INTO #BranchKPIs
        FROM #EnterprisePortfolio P
        LEFT JOIN #PortfolioExceptions E
            ON  P.BusinessDate = E.BusinessDate
            AND P.SourceAccountNumber = E.SourceAccountNumber
        GROUP BY P.BranchCode;

        IF @Debug = 1
        BEGIN
            PRINT 'Source System KPIs';
            SELECT * FROM #SourceSystemKPIs ORDER BY ExceptionRate DESC;

            PRINT 'Business Area KPIs';
            SELECT * FROM #BusinessAreaKPIs ORDER BY TotalExceptions DESC;

            PRINT 'Business Owner KPIs';
            SELECT * FROM #BusinessOwnerKPIs ORDER BY AssignedExceptions DESC;

            PRINT 'Branch KPIs';
            SELECT * FROM #BranchKPIs ORDER BY BranchExceptionRate DESC;
        END;


        /* ============================================================
           SECTION L - SLA PERFORMANCE
           ============================================================ */

        IF OBJECT_ID('tempdb..#SLAKPIs') IS NOT NULL
            DROP TABLE #SLAKPIs;

        SELECT
              SeverityCode
            , COUNT(*) AS TotalExceptions
            , SUM
              (
                  CASE
                      WHEN ResolutionDueDate < GETDATE()
                      THEN 1
                      ELSE 0
                  END
              ) AS OverdueExceptions
            , SUM
              (
                  CASE
                      WHEN EscalationRequired = 1
                      THEN 1
                      ELSE 0
                  END
              ) AS EscalatedExceptions
            , CAST
              (
                  SUM
                  (
                      CASE
                          WHEN ResolutionDueDate < GETDATE()
                          THEN 1
                          ELSE 0
                      END
                  ) * 100.0
                  / NULLIF(COUNT(*), 0)
                  AS DECIMAL(10,2)
              ) AS SLAFailureRate
        INTO #SLAKPIs
        FROM #PortfolioExceptions
        GROUP BY SeverityCode;


        /* ============================================================
           SECTION M - 30-DAY TREND ANALYSIS
           ============================================================ */

        IF OBJECT_ID('tempdb..#TrendAnalysis') IS NOT NULL
            DROP TABLE #TrendAnalysis;

        SELECT
              BusinessDate
            , COUNT(*) AS TotalExceptions
            , SUM
              (
                  CASE
                      WHEN SeverityCode = 'CRITICAL'
                      THEN 1
                      ELSE 0
                  END
              ) AS CriticalExceptions
            , COUNT(DISTINCT BusinessOwner) AS ActiveBusinessOwners
        INTO #TrendAnalysis
        FROM Warehouse.CustomerPortfolioExceptions
        WHERE BusinessDate >= DATEADD(DAY, -30, @BusinessDate)
        GROUP BY BusinessDate;


        /* ============================================================
           SECTION N - EXECUTIVE SCORECARD
           ============================================================ */

        IF OBJECT_ID('tempdb..#ExecutiveScorecard') IS NOT NULL
            DROP TABLE #ExecutiveScorecard;

        ;WITH ScorecardData AS
        (
            SELECT
                'Portfolio Health' AS KPIName,
                PortfolioHealth AS KPIValue,
                CASE
                    WHEN PortfolioHealth IN ('EXCELLENT', 'GOOD')
                    THEN 'GREEN'
                    WHEN PortfolioHealth = 'FAIR'
                    THEN 'AMBER'
                    ELSE 'RED'
                END AS KPIStatus
            FROM #ExecutiveKPIs

            UNION ALL

            SELECT
                'Critical Exceptions',
                CAST(CriticalExceptions AS VARCHAR(20)),
                CASE
                    WHEN CriticalExceptions < 10
                    THEN 'GREEN'
                    WHEN CriticalExceptions < 50
                    THEN 'AMBER'
                    ELSE 'RED'
                END
            FROM #ExecutiveKPIs

            UNION ALL

            SELECT
                'Exception Rate',
                CAST(ExceptionRate AS VARCHAR(20)),
                CASE
                    WHEN ExceptionRate < 2
                    THEN 'GREEN'
                    WHEN ExceptionRate < 5
                    THEN 'AMBER'
                    ELSE 'RED'
                END
            FROM #ExecutiveKPIs

            UNION ALL

            SELECT
                'SLA Compliance',
                CAST(
                    100 -
                    (
                        SELECT AVG(SLAFailureRate)
                        FROM #SLAKPIs
                    )
                    AS VARCHAR(20)
                ),
                CASE
                    WHEN
                    (
                        SELECT AVG(SLAFailureRate)
                        FROM #SLAKPIs
                    ) < 5
                    THEN 'GREEN'
                    WHEN
                    (
                        SELECT AVG(SLAFailureRate)
                        FROM #SLAKPIs
                    ) < 15
                    THEN 'AMBER'
                    ELSE 'RED'
                END
        )
        SELECT
              KPIName
            , KPIValue
            , KPIStatus
        INTO #ExecutiveScorecard
        FROM ScorecardData;


        /* ============================================================
           SECTION O - LOAD REPORTING.PORTFOLIOEXCEPTIONREPORT
           ============================================================ */

        TRUNCATE TABLE Reporting.PortfolioExceptionReport;

        INSERT INTO Reporting.PortfolioExceptionReport
        (
              BusinessDate
            , KPIName
            , KPIValue
            , KPIStatus
            , CreatedDate
        )
        SELECT
              @BusinessDate
            , KPIName
            , KPIValue
            , KPIStatus
            , GETDATE()
        FROM #ExecutiveScorecard;

        SELECT @RowsInserted = COUNT(*) FROM Reporting.PortfolioExceptionReport
        WHERE BusinessDate = @BusinessDate;

        IF @Debug = 1
        BEGIN
            PRINT 'Executive Scorecard';
            SELECT * FROM #ExecutiveScorecard;

            PRINT 'SLA Performance';
            SELECT * FROM #SLAKPIs;

            PRINT '30-Day Trend';
            SELECT * FROM #TrendAnalysis ORDER BY BusinessDate;
        END;


        /* ============================================================
           SECTION P - FINALISE AUDIT
           ============================================================ */

        SET @EndTime = SYSDATETIME();
        SET @ExecutionSeconds = DATEDIFF(SECOND, @StartTime, @EndTime);
        SET @Status = 'SUCCESS';
        SET @ExecutionMessage =
            CONCAT
            (
                'Portfolio Exception Report generated successfully. ',
                'Report Records: ', @RowsInserted,
                ', Execution Time: ', @ExecutionSeconds, ' seconds.'
            );

        IF @EnableLogging = 1
        BEGIN
            UPDATE Audit.ETLExecutionLog
            SET
                  EndTime         = @EndTime
                , Status          = @Status
                , RowsInserted    = @RowsInserted
                , DurationSeconds = @ExecutionSeconds
                , Message         = @ExecutionMessage
            WHERE ExecutionId = @ExecutionId;
        END;

        INSERT INTO Audit.ReportingExecutionSummary
        (
              BusinessDate
            , ExecutionId
            , ProcedureName
            , ReportName
            , RecordsGenerated
            , ExecutionSeconds
            , CreatedDate
        )
        VALUES
        (
              @BusinessDate
            , @ExecutionId
            , @ProcedureName
            , 'Portfolio Exception Dashboard'
            , @RowsInserted
            , @ExecutionSeconds
            , GETDATE()
        );

        INSERT INTO Audit.ExecutiveDashboardMetrics
        (
              BusinessDate
            , PortfolioHealth
            , CriticalExceptions
            , ExceptionRate
            , SLACompliance
            , GeneratedDate
        )
        SELECT
              @BusinessDate
            , PortfolioHealth
            , CriticalExceptions
            , ExceptionRate
            , 100 -
              (
                  SELECT AVG(SLAFailureRate)
                  FROM #SLAKPIs
              ) AS SLACompliance
            , GETDATE()
        FROM #ExecutiveKPIs;


        /* ============================================================
           SECTION Q - DEBUG OUTPUT
           ============================================================ */

        IF @Debug = 1
        BEGIN
            PRINT '=========================================';
            PRINT 'Portfolio Exception Report Completed';
            PRINT '=========================================';
            PRINT CONCAT('Execution Time      : ', @ExecutionSeconds, ' seconds');
            PRINT CONCAT('Business Date       : ', @BusinessDate);
            PRINT CONCAT('Report Records      : ', @RowsInserted);
            PRINT '-----------------------------------------';

            SELECT * FROM Reporting.PortfolioExceptionReport
            WHERE BusinessDate = @BusinessDate;
        END;


        /* ============================================================
           SECTION R - CLEANUP TEMPORARY OBJECTS
           ============================================================ */

        DROP TABLE IF EXISTS #PortfolioExceptions;
        DROP TABLE IF EXISTS #EnterprisePortfolio;
        DROP TABLE IF EXISTS #ExecutiveKPIs;
        DROP TABLE IF EXISTS #SourceSystemKPIs;
        DROP TABLE IF EXISTS #BusinessAreaKPIs;
        DROP TABLE IF EXISTS #BusinessOwnerKPIs;
        DROP TABLE IF EXISTS #BranchKPIs;
        DROP TABLE IF EXISTS #SLAKPIs;
        DROP TABLE IF EXISTS #TrendAnalysis;
        DROP TABLE IF EXISTS #ExecutiveScorecard;


        /* ============================================================
           SECTION S - COMMIT TRANSACTION
           ============================================================ */

        COMMIT TRANSACTION;

    END TRY

    BEGIN CATCH

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
                      EndTime         = @EndTime
                    , Status          = @Status
                    , Message         = @ExecutionMessage
                    , DurationSeconds = DATEDIFF(SECOND, @StartTime, @EndTime)
                WHERE ExecutionId = @ExecutionId;
            END;
        END;

        DROP TABLE IF EXISTS #PortfolioExceptions;
        DROP TABLE IF EXISTS #EnterprisePortfolio;
        DROP TABLE IF EXISTS #ExecutiveKPIs;
        DROP TABLE IF EXISTS #SourceSystemKPIs;
        DROP TABLE IF EXISTS #BusinessAreaKPIs;
        DROP TABLE IF EXISTS #BusinessOwnerKPIs;
        DROP TABLE IF EXISTS #BranchKPIs;
        DROP TABLE IF EXISTS #SLAKPIs;
        DROP TABLE IF EXISTS #TrendAnalysis;
        DROP TABLE IF EXISTS #ExecutiveScorecard;

        THROW;

    END CATCH;
END;
GO

PRINT 'Procedure Warehouse.usp_LoadPortfolioExceptionReport created successfully.';
GO