/*
	History Log

	2.05.00 Implemented #15.
	2.18.00 Implemented #23.
	2.19.00 Implemented #3.
*/

USE [SQLSIM]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER FUNCTION [dbo].[svfCalculateOperationCost] 
(
	@IndexOperation  VARCHAR(255),
	@DatabaseID      INT,
	@TableID         INT,
	@IndexID         INT,
	@PartitionNumber INT,
	@PageCount		 INT = 0,
	@DefaultOpTime	 INT = 0
)
RETURNS INT
AS
BEGIN

	/*
		This function can be called for index scan or mainteance
		operation to understand the time requirement to complete the
		task. 
		
		If it is for FragScan, unless I have prior history, it will estimate the cost 
		to the default operation cost because we do not know the actual page count information.

		It is possible to estimated page count using Allocation Unit (data_pages), however,
		that catalog must be accessed in the context of the data.  Function calls do not
		support dynamic T-SQL code.

	*/

	DECLARE @HistCount   INT
	DECLARE @StdDivTime  FLOAT
	DECLARE @AvgTime     FLOAT

	SET @AvgTime = 0

	-- Step #1: Do we have history for current object?
	SELECT @HistCount = COUNT(*) 
		FROM dbo.MaintenanceHistory MH
		JOIN dbo.MasterIndexCatalog MIC
		ON MH.MasterIndexCatalogID = MIC.ID
		WHERE MH.OperationType LIKE @IndexOperation + '%'
		AND MIC.DatabaseID = @DatabaseID
		AND MIC.TableID = @TableID
		AND MIC.IndexID = @IndexID
		AND MIC.PartitionNumber = @PartitionNumber

	IF (@HistCount > 0)
	BEGIN

		-- Step #1: Calculate standard diviation to help us eliminate outliers.
		SELECT @StdDivTime = ISNULL(STDEV(DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime)),0)
			FROM dbo.MaintenanceHistory MH
			JOIN dbo.MasterIndexCatalog MIC
			ON MH.MasterIndexCatalogID = MIC.ID
			WHERE MH.OperationType LIKE @IndexOperation + '%'
			AND MIC.DatabaseID = @DatabaseID
			AND MIC.TableID = @TableID
			AND MIC.IndexID = @IndexID
			AND MIC.PartitionNumber = @PartitionNumber

		-- Step #2: Calculate the average time.
		SELECT @AvgTime = ISNULL(AVG(DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime)),0)
			FROM dbo.MaintenanceHistory MH
			JOIN dbo.MasterIndexCatalog MIC
			ON MH.MasterIndexCatalogID = MIC.ID
			WHERE MH.OperationType LIKE @IndexOperation + '%'
			AND MIC.DatabaseID = @DatabaseID
			AND MIC.TableID = @TableID
			AND MIC.IndexID = @IndexID
			AND MIC.PartitionNumber = @PartitionNumber

		-- Step #3: Calculate the average time removing excluding outliers.
		SELECT @AvgTime = ISNULL(AVG(DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime)),0)
			FROM dbo.MaintenanceHistory MH
			JOIN dbo.MasterIndexCatalog MIC
			ON MH.MasterIndexCatalogID = MIC.ID
			WHERE MH.OperationType LIKE @IndexOperation + '%'
			AND MIC.DatabaseID = @DatabaseID
			AND MIC.TableID = @TableID
			AND MIC.IndexID = @IndexID
			AND MIC.PartitionNumber = @PartitionNumber
			AND DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime) >= (@AvgTime - @StdDivTime)
			AND DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime) <= (@AvgTime + @StdDivTime)
	END
	ELSE IF ((@IndexOperation <> 'FragScan') AND (@HistCount = 0))
	BEGIN

		-- If it is a FragScan and we don't have history, we right now do not know page count to get 
		-- estimated cost. Therefore, default to Default Operation Cost, which is based on maintenance window
		-- time.

		-- Step #1: Calculate standard diviation to help us eliminate outliers.
		SELECT @StdDivTime = ISNULL(STDEV(DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime)),0)
			FROM dbo.MaintenanceHistory MH
			JOIN dbo.MasterIndexCatalog MIC
			ON MH.MasterIndexCatalogID = MIC.ID
			WHERE MH.OperationType LIKE @IndexOperation + '%'
			AND MH.Page_Count >= @PageCount - (@PageCount * .10)
			AND MH.Page_Count <= @PageCount + (@PageCount * .10)

		-- Step #2: Calculate the average time.
		SELECT @AvgTime = ISNULL(AVG(DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime)),0)
			FROM dbo.MaintenanceHistory MH
			JOIN dbo.MasterIndexCatalog MIC
			ON MH.MasterIndexCatalogID = MIC.ID
			WHERE MH.OperationType LIKE @IndexOperation + '%'
			AND MH.Page_Count >= @PageCount - (@PageCount * .10)
			AND MH.Page_Count <= @PageCount + (@PageCount * .10)

		-- Step #3: Calculate the average time removing excluding outliers.
		SELECT @AvgTime = ISNULL(AVG(DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime)),0)
			FROM dbo.MaintenanceHistory MH
			JOIN dbo.MasterIndexCatalog MIC
			ON MH.MasterIndexCatalogID = MIC.ID
			WHERE MH.OperationType LIKE @IndexOperation + '%'
			AND MH.Page_Count >= @PageCount - (@PageCount * .10)
			AND MH.Page_Count <= @PageCount + (@PageCount * .10)
			AND DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime) >= (@AvgTime - @StdDivTime)
			AND DATEDIFF(MILLISECOND,MH.OperationStartTime,MH.OperationEndTime) <= (@AvgTime + @StdDivTime)
	END

	if (@AvgTime = 0)
		SET @AvgTime = @DefaultOpTime

	-- Return the result of the function
	RETURN CAST(@AvgTime AS INT)

END
GO

CREATE OR ALTER FUNCTION [dbo].[tvfGetThresholds] 
(	
	@PageCount BIGINT
)
RETURNS TABLE 
AS
RETURN 
(
	-- 65,536,000 Page Count = 500 GB
	SELECT (CASE WHEN .1 - ((@PageCount/65536000.)*.1) < 0 THEN
	          0.01
		   ELSE
			  .1 - ((@PageCount/65536000.)*.1)
		   END) * 100 AS ReorgThreshold,
           (CASE WHEN .3 - ((@PageCount/65536000.)*.3) < .1 THEN
	          0.1
		   ELSE
			  .3 - ((@PageCount/65536000.)*.3)
		   END) * 100 AS RebuildThreshold
)
GO

CREATE OR ALTER   FUNCTION [dbo].[svfCalculateFillfactor] 
(	@LastEvaluatedDate DATE,
	@PageCount BIGINT )
RETURNS INT
AS
BEGIN

	DECLARE @AdjusmentFactor FLOAT
	DECLARE @PageCountBaseValue FLOAT =  134217728 -- 1TB
	DECLARE @PagePercentValue FLOAT
	DECLARE @DaysSinceLastEval INT
	DECLARE @FillFactorAdjustment INT

	SET @PagePercentValue = CAST(@PageCount AS FLOAT) / @PageCountBaseValue
	SET @DaysSinceLastEval = DATEDIFF(DAY,@LastEvaluatedDate,GETDATE())
	SET @AdjusmentFactor = (2 - (@PagePercentValue*2))
	SET @FillFactorAdjustment = CAST(((8-@DaysSinceLastEval)*@AdjusmentFactor) AS INT) + 1

	IF @AdjusmentFactor < 0
		SET @AdjusmentFactor = 0.01

	IF @FillFactorAdjustment > 15
		SET @FillFactorAdjustment = 15
	ELSE IF @FillFactorAdjustment < 1
		SET @FillFactorAdjustment = 0

	RETURN @FillFactorAdjustment

END
GO