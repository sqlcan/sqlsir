/*
	History Log

	2.04.00	Resolved Issue #11
	2.04.01 Mixed bug with LOB_DATA AND ROW_OVERFLOW_DATA.
	2.05.00 Implemented #15.
	2.06.00 Implemented #14.
	2.06.01 Post Release Minor Bug Fixes.
	2.07.00 Implemented #18.
    2.12.00 Fixed various issues with @PrintOnlyNoExecute parameter. (Fixed #5)
            - Added date time stamp if @Debug is supplied.
            - Suspended TLOG Space Check when running in Print Only.
            - Suspended DBCC Info Messages
            - Removed extra white space from TSQL command.
            - Skip Maintenance window check when running in Print Mode.	
	2.14.00	Fixed white space issue with TSQL Command.
			Ignoring maintenance window led to another bug where no indexes were evaluated.
			Fixed number of issues with MasterIndexCatalog update.
	2.15.00	Fixed format bug issues with PRINT.
			Fixed MWEndTime calculation.
			Added additional detail for information messsages.
			Fixed multiple spelling mistakes in output.
    2.16.00 Updated how reporting is completed for current activity.
			Introduced new view to summarize master catalog with last operation details.
	2.17.00 Updated logic for how mainteance windows are assigned (Issue #21).
	2.17.01 Can't change fill factor when maintaining individual partition (Issue #22).
	2.18.00 Rebuild and Reorg Threshold is Dynamically calculated based on index size (Issue #23).
	2.19.00 Updated how the Fill Factor Adjustment is calculated (Issue #3).
	2.23.00 Added support for Column Store Indexes (Issue #17).
	        Heavily refactored the code and added support for Index Type.
			Updated minor logic in the view.
*/

USE [SQLSIM]
GO

CREATE OR ALTER   PROCEDURE [dbo].[upUpdateMasterIndexCatalog]
@DefaultMaintenanceWindowName VARCHAR(255) = 'No Maintenance',
@DefaultMaintenanceWindowID INT = 1,
@DisableMaintenanceOnUserExclusions BIT = 0 
AS
BEGIN

	SET NOCOUNT ON

	DECLARE @DatabaseID		             int
	DECLARE @DatabaseName	             nvarchar(255)
	DECLARE @SQL			             varchar(8000)
	DECLARE @NoMaintenanceWindowID       int = 1       -- This is hardcorded and expected value.  Value is protected by triggers.
	DECLARE @HotTableMaintenanceWindowID int = 2       -- This is hardcorded and expected value.  Value is protected by triggers.

	IF (@DefaultMaintenanceWindowName <> 'No Maintenance')
		SELECT @DefaultMaintenanceWindowID = MaintenanceWindowID
		  FROM dbo.MaintenanceWindow
		 WHERE MaintenanceWindowName = @DefaultMaintenanceWindowName

	IF (@DefaultMaintenanceWindowID IS NULL)
		SET @DefaultMaintenanceWindowID = 1

	CREATE TABLE #DatabaseToManage
	(DatabaseID		int,
     DatabaseName	nvarchar(255));

	CREATE TABLE #DatabasesToSkip
	(DatabaseName  sysname,
	 UserExclusion bit);

	-- Copying the database skip table, as additional databases might be added to this table
	-- based on additional rules.  We do not want to overwrite user DatabasesToSkip table.
	INSERT INTO #DatabasesToSkip
	SELECT DatabaseName, 1
	  FROM dbo.DatabasesToSkip

	-- Rule #1: Skip all databases that are SECONDARY on current AG replica.
	INSERT INTO #DatabasesToSkip
	SELECT d.name, 0
	  FROM sys.databases d
      JOIN sys.dm_hadr_availability_replica_states rs ON d.replica_id = rs.replica_id
      JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
     WHERE rs.role_desc = 'SECONDARY'

	-- Rule #2: Skip all databases that are SECONDARY on current database mirroring topology.
	INSERT INTO #DatabasesToSkip
	SELECT db_name(database_id), 0 FRom sys.database_mirroring WHERE mirroring_role = 2

	-- Rule #3: Skip databases that are not writeable.
	INSERT INTO #DatabasesToSkip
	     SELECT name, 0
	       FROM sys.databases
	      WHERE database_id > 4
			AND (user_access <> 0     -- MULTI_USER
	        OR state <> 0			-- ONLINE
	        OR is_read_only <> 0    -- READ_WRITE
			OR is_in_standby <> 0)   -- Log Shipping Standby
	-- Only select user database databases that are online and writable.
	--
	-- Only database that are in DatabasesToManage -- Controlled by DBA Team --

	INSERT INTO #DatabaseToManage
		 SELECT database_id, name
	       FROM sys.databases
	      WHERE database_id > 4
			AND name NOT IN (SELECT DatabaseName FROM #DatabasesToSkip) 

	-- Table used to track current state of tlog space.  Once TLog has reached capacity setting.
    DELETE FROM dbo.DatabaseStatus
    INSERT INTO dbo.DatabaseStatus
	SELECT database_id, 0
	  FROM sys.databases
	 WHERE database_id > 4
	   AND name NOT IN (SELECT DatabaseName FROM #DatabasesToSkip WHERE UserExclusion = 0) 

	-- Step #1: Update Master Catalog Table for Index in the #DatabaseToManage list.
	DECLARE cuDatabaeScan
	 CURSOR LOCAL FORWARD_ONLY STATIC READ_ONLY
	    FOR SELECT DatabaseID, DatabaseName
	          FROM #DatabaseToManage
	
	OPEN cuDatabaeScan
	
		FETCH NEXT FROM cuDatabaeScan
		INTO @DatabaseID, @DatabaseName
	
		WHILE @@FETCH_STATUS = 0
		BEGIN
			
			-- Update Master Index Catalog with meta-data, new objects identified.
			SET @SQL = 'INSERT INTO dbo.MasterIndexCatalog (DatabaseID, DatabaseName, SchemaID, SchemaName, TableID, TableName, PartitionNumber, IndexID, IndexName, IndexType, IndexFillFactor, MaintenanceWindowID)
			            SELECT ' + CAST(@DatabaseID AS varchar) + ', ''' + @DatabaseName + ''', s.schema_id, s.name, t.object_id, t.name, p.partition_number, i.index_id, i.name, i.type, i.fill_factor, ' + CAST(@DefaultMaintenanceWindowID AS VARCHAR) + ' 
						  FROM [' + @DatabaseName + '].sys.schemas s
                          JOIN [' + @DatabaseName + '].sys.tables t ON s.schema_id = t.schema_id
                          JOIN [' + @DatabaseName + '].sys.indexes i on t.object_id = i.object_id
						  JOIN [' + @DatabaseName + '].sys.partitions p on t.object_id = p.object_id
						                                            AND i.index_id = p.index_id
                         WHERE i.is_hypothetical = 0
						   AND i.index_id >= 1
						   AND i.type IN (1,2,5,6) -- Only index excluded in HEAP, SPATIAL Indexes, Memory Indexes, XML Indexes
						   AND t.is_ms_shipped = 0
                           AND NOT EXISTS (SELECT *
                                             FROM dbo.MasterIndexCatalog MIC
                                            WHERE MIC.DatabaseID = ' + CAST(@DatabaseID AS varchar) + '
                                              AND MIC.SchemaID = s.schema_id
                                              AND MIC.TableID = t.object_id
                                              AND MIC.IndexID = i.index_id
											  AND MIC.PartitionNumber = p.partition_number)'
			
			EXEC(@SQL)
			
			-- Update Master Index Catalog with meta-data, remove objects that do not exist any more.
			SET @SQL = 'DELETE FROM MaintenanceHistory
			                  WHERE MasterIndexCatalogID
			                     IN ( SELECT ID
			                            FROM dbo.MasterIndexCatalog MIC
			                           WHERE NOT EXISTS (SELECT *
			                                               FROM [' + @DatabaseName + '].sys.schemas s
														   JOIN [' + @DatabaseName + '].sys.tables t     ON s.schema_id = t.schema_id
														   JOIN [' + @DatabaseName + '].sys.indexes i    on t.object_id = i.object_id
						                                   JOIN [' + @DatabaseName + '].sys.partitions p on t.object_id = p.object_id
						                                                                                 AND i.index_id = p.index_id
														  WHERE MIC.DatabaseID = ' + CAST(@DatabaseID AS varchar) + '
                                                            AND MIC.SchemaID = s.schema_id
                                                            AND MIC.TableID = t.object_id
                                                            AND MIC.IndexID = i.index_id
															AND MIC.PartitionNumber = p.partition_number)
							             AND MIC.DatabaseID = ' + CAST(@DatabaseID AS varchar) + ')'
                                              
			
			EXEC(@SQL)
			
			SET @SQL = 'DELETE FROM MasterIndexCatalog
			                  WHERE NOT EXISTS (SELECT *
			                                      FROM [' + @DatabaseName + '].sys.schemas s
							  				      JOIN [' + @DatabaseName + '].sys.tables t     ON s.schema_id = t.schema_id
												  JOIN [' + @DatabaseName + '].sys.indexes i    on t.object_id = i.object_id
						                          JOIN [' + @DatabaseName + '].sys.partitions p on t.object_id = p.object_id
						                                                                       AND i.index_id = p.index_id
											     WHERE DatabaseID = ' + CAST(@DatabaseID AS varchar) + '
                                                   AND SchemaID = s.schema_id
                                                   AND TableID = t.object_id
                                                   AND IndexID = i.index_id
												   AND PartitionNumber = p.partition_number)
	                            AND DatabaseID = ' + CAST(@DatabaseID AS varchar)
                                              
			
			EXEC(@SQL)
			
			FETCH NEXT FROM cuDatabaeScan
			INTO @DatabaseID, @DatabaseName
			
		END
		
	CLOSE cuDatabaeScan
	
	DEALLOCATE cuDatabaeScan
	
	-- Step #2: Update Maintenance Window ID to value supplied for all indexes.
	UPDATE dbo.MasterIndexCatalog
	   SET MaintenanceWindowID = @DefaultMaintenanceWindowID

	-- Step #3: Overwrite Mainteance Window for Small Index 1 Page - 1000 Pages
	;WITH LastHistoryRecord AS (
		SELECT MasterIndexCatalogID, MAX(HistoryID) AS LastID
		  FROM dbo.MaintenanceHistory
	  GROUP BY MasterIndexCatalogID
	)
	UPDATE dbo.MasterIndexCatalog
	   SET MaintenanceWindowID = @HotTableMaintenanceWindowID
	 WHERE ID IN (SELECT DISTINCT MH.MasterIndexCatalogID
	                FROM dbo.MaintenanceHistory MH
					JOIN LastHistoryRecord LHR
					  ON MH.MasterIndexCatalogID = LHR.MasterIndexCatalogID
					 AND MH.HistoryID = LHR.LastID
				   WHERE Page_Count <= 1000)

	-- Step #4: Disable Index Mainteance on all databases that are in DatabasesToSkip by identified by 
	--          discovery process (AG Secondary, DBM Parnter, Database Inaccessible (Read-Only, Offline, etc.))
	UPDATE dbo.MasterIndexCatalog
	   SET MaintenanceWindowID = @NoMaintenanceWindowID
	 WHERE DatabaseName IN (SELECT DatabaseName FROM #DatabasesToSkip WHERE UserExclusion = 0)

	-- Step #5: Remove mainteance on databases in databases to skip table, if user intends to stop mainteance
	--          on these databases.  If this parameter is not supplied, assumption is mainteance is to be
	--          continuned as per the previous maintenance window settings. 
	--
	--          This will allow user to define different maintenance window for different databases by 
	--          changing the values in DatabasesToSkip table.
	IF (@DisableMaintenanceOnUserExclusions  = 1)
		UPDATE dbo.MasterIndexCatalog
		   SET MaintenanceWindowID = @NoMaintenanceWindowID
		 WHERE DatabaseName IN (SELECT DatabaseName FROM #DatabasesToSkip WHERE UserExclusion = 1)

END
GO

CREATE OR ALTER PROCEDURE upUpdateIndexUsageStats
AS
BEGIN

    DECLARE @LastRestartDate DATETIME

    SELECT @LastRestartDate = create_date
      FROM sys.databases
     WHERE database_id = 2

    IF EXISTS (SELECT * FROM dbo.MetaData WHERE LastIndexUsageScanDate > @LastRestartDate)
    BEGIN
        -- Server has restarted since last data collection.
        UPDATE dbo.MasterIndexCatalog
           SET LastRangeScanCount = range_scan_count,
               LastSingletonLookupCount = singleton_lookup_count,
               RangeScanCount = RangeScanCount + range_scan_count,
               SingletonLookupCount = SingletonLookupCount + singleton_lookup_count
          FROM sys.dm_db_index_operational_stats(null,null,null,null) IOS
          JOIN dbo.MasterIndexCatalog MIC ON IOS.database_id = MIC.DatabaseID
                                         AND IOS.object_id = MIC.TableID
                                         AND IOS.index_id = MIC.IndexID
										 AND IOS.partition_number = MIC.PartitionNumber
    END
    ELSE
    BEGIN
        -- Server did not restart since last collection.
        UPDATE dbo.MasterIndexCatalog
           SET LastRangeScanCount = LastRangeScanCount + (range_scan_count - LastRangeScanCount),
               LastSingletonLookupCount = LastSingletonLookupCount + (singleton_lookup_count - LastSingletonLookupCount),
               RangeScanCount = RangeScanCount + (range_scan_count - LastRangeScanCount),
               SingletonLookupCount = SingletonLookupCount + (singleton_lookup_count - LastSingletonLookupCount)
          FROM sys.dm_db_index_operational_stats(null,null,null,null) IOS
          JOIN dbo.MasterIndexCatalog MIC ON IOS.database_id = MIC.DatabaseID
                                         AND IOS.object_id = MIC.TableID
                                         AND IOS.index_id = MIC.IndexID
										 AND IOS.partition_number = MIC.PartitionNumber

    END

    IF ((SELECT COUNT(*) FROM dbo.MetaData) = 1)
    BEGIN
        UPDATE dbo.MetaData
            SET LastIndexUsageScanDate = GetDate()
    END
    ELSE
    BEGIN
        INSERT INTO dbo.MetaData (LastIndexUsageScanDate) VALUES (GetDate())
    END

END
GO

CREATE OR ALTER PROCEDURE [dbo].[upMaintainIndexes]
@IgnoreRangeScans BIT = 0,
@PrintOnlyNoExecute INT = 0,
@MAXDOPSetting INT = 4,
@LastOpTimeGap INT = 5,
@MaxLogSpaceUsageBeforeStop FLOAT = 80,
@LogNOOPMsgs BIT = 1, -- Defaulting 1, because setting it to 0 makes it difficult to know
                      -- why the indexes are not maintained.
@DebugMode BIT = 0
AS
BEGIN

	SET NOCOUNT ON

    -- Start of Stored Procedure
	DECLARE @MaintenanceWindowName	    varchar(255)
	DECLARE @SQL					    nvarchar(4000)
	DECLARE @DatabaseID				    int
	DECLARE @DatabaseName			    nvarchar(255)
	DECLARE @SchemaName				    nvarchar(255)
	DECLARE @TableID				    bigint
	DECLARE @TableName				    nvarchar(255)
	DECLARE @IndexID				    int
	DECLARE @PartitionNumber			int
	DECLARE @IndexName				    nvarchar(255)
    DECLARE @IsRSI                      bit         -- RSI = Row Store Index
	DECLARE @IndexFillFactor		    tinyint 
	DECLARE @IndexOperation			    varchar(25)
	DECLARE @OfflineOpsAllowed		    bit
	DECLARE @OnlineOpsSupported		    bit
	DECLARE @RebuildOnline			    bit
	DECLARE @IsDisabled				    bit
	DECLARE @IndexPageLockAllowed	    bit
	DECLARE @ServerEdition			    int
    DECLARE @SQLMajorBuild			    int    
	DECLARE @MWStartTime			    datetime
	DECLARE @MWEndTime				    datetime
	DECLARE @OpStartTime			    datetime
	DECLARE @OpEndTime				    datetime
	DECLARE @LastManaged			    datetime
	DECLARE @LastScanned			    datetime
    DECLARE @LastEvaluated              datetime
    DECLARE @SkipCount                  int
    DECLARE @MaxSkipCount               int
	DECLARE @MAXDOP					    int
	DECLARE @DefaultOpTime			    int
	DECLARE @FiveMinuteCheck		    int
	DECLARE @FFA					    int --Fill Factor Adjustment
    DECLARE @LogSpacePercentage         float
    DECLARE @ReasonForNOOP				varchar(255)
	DECLARE @OpTime						int
	DECLARE @EstOpEndTime				datetime
	DECLARE @IdentityValue				INT
	DECLARE @RebuildThreshold			FLOAT = 10
	DECLARE @ReorgThreshold				FLOAT = 30
	DECLARE @MIN_FILL_FACTOR_SETTING	INT = 70	-- FIX VALUE -- CONSTANT --

	SET NOCOUNT ON

	IF (@PrintOnlyNoExecute = 0)
		PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' Starting Index Mainteance Script in [EXECUTE MODE]'
	ELSE IF (@PrintOnlyNoExecute = 1)
		PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' Starting Index Mainteance Script in [PRINT ONLY MODE]'

	SET @MAXDOP = @MAXDOPSetting	 -- Degree of Parallelism to use for Index Rebuilds

	SET @FiveMinuteCheck = @LastOpTimeGap*60*1000 -- When the script is with in 5 minutes of maintenance window; it will not try to run any more
											      --  operations.

    SELECT MaintenanceWindowID,
           MaintenanceWindowName,
           CASE WHEN GETDATE() > CAST(DATEADD(Day,1,CONVERT(CHAR(10),GETDATE(),111)) + ' 00:00:00.000' AS DateTime) THEN  -- If the current time is after midnight; then we need to decrement the 
              DATEADD(DAY,MaintenanceWindowDateModifer,CAST(CONVERT(CHAR(10),GETDATE(),111) + ' ' + CONVERT(CHAR(10),MaintenanceWindowStartTime,114) AS DATETIME))
           ELSE
              CAST(CONVERT(CHAR(10),GETDATE(),111) + ' ' + CONVERT(CHAR(10),MaintenanceWindowStartTime,114) AS DATETIME)
           END AS MaintenanceWindowStartTime,
           CASE WHEN MaintenanceWindowDateModifer = -1 THEN
              DATEADD(DAY,MaintenanceWindowDateModifer*-1,CAST(CONVERT(CHAR(10),GETDATE(),111) + ' ' + CONVERT(CHAR(10),MaintenanceWindowEndTime,114) AS DATETIME))
           ELSE
              CAST(CONVERT(CHAR(10),GETDATE(),111) + ' ' + CONVERT(CHAR(10),MaintenanceWindowEndTime,114) AS DATETIME)
           END AS MaintenanceWindowEndTime
      INTO #RelativeMaintenanceWindows
      FROM MaintenanceWindow
     WHERE MaintenanceWindowWeekdays LIKE '%' + DATENAME(DW,GETDATE()) + '%'
 
      SELECT TOP 1 @MaintenanceWindowName = MaintenanceWindowName,
             @MWStartTime = MaintenanceWindowStartTime,
             @MWEndTime = MaintenanceWindowEndTime
        FROM #RelativeMaintenanceWindows
       WHERE MaintenanceWindowStartTime <= GETDATE() AND MaintenanceWindowEndTime >= GETDATE()
    ORDER BY MaintenanceWindowStartTime ASC

	IF ((@MaintenanceWindowName IS NULL) AND (@PrintOnlyNoExecute = 0))
	BEGIN
		IF (@DebugMode = 1)
			PRINT 'No maintenance window found.  Stopping script on ' + CONVERT(VARCHAR(255),GETDATE(),121)
		RETURN	
	END

	IF ((@DebugMode = 1) AND (@PrintOnlyNoExecute = 0))
		PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + '... Running maintenance script for ' + @MaintenanceWindowName
	ELSE IF (@PrintOnlyNoExecute = 1)
	BEGIN
		IF (@DebugMode = 1)
			PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + '... Running maintenance script for All OBJECTS [Mainteance Window Ignored].'
		SET @MWStartTime = GETDATE()
		SET @MWEndTime = DATEADD(HOUR,4,@MWStartTime)
		SET @MaintenanceWindowName = 'PRINTONLY'
	END

    -- We need to calculate the Default Op Time, the default value in V1 was 1 HOUR (60*60*1000)
    -- However this doesn't work for small maintenance windows.  Small maintenance windows
    -- are ideal for small tables, therefore the default option on these should also be recalculated
    -- to match the small maintenance window.
    --
    -- Default Op will now assume that it will take approx 1/10 of time allocated to a maintenance
    -- window.

    SET @DefaultOpTime = DATEDIFF(MILLISECOND,@MWStartTime,@MWEndTime) / 10

    -- We are starting maintenance schedule all over therefore
    -- We'll assume the database is in health state, (i.e. transaction log is not at capacity).
    --
    -- However after the first index gets maintained we will re-check to make sure this is still valid state.
    UPDATE dbo.DatabaseStatus
       SET IsLogFileFull = 0

	SELECT @ServerEdition = CAST(SERVERPROPERTY('EngineEdition') AS int),                   -- 3 = Enterprise, Developer, Enterprise Eval
           @SQLMajorBuild = CAST(SERVERPROPERTY('MajoProductMajorVersionrBuild') AS int)

	DECLARE cuIndexList
	 CURSOR LOCAL FORWARD_ONLY STATIC READ_ONLY
	    FOR SELECT DatabaseID, DatabaseName, SchemaName, TableID, TableName, IndexID, PartitionNumber, IndexName, IndexFillFactor, OfflineOpsAllowed, LastManaged, LastScanned, LastEvaluated, SkipCount, MaxSkipCount
	          FROM dbo.MasterIndexCatalog MIC
	          JOIN dbo.MaintenanceWindow  MW   ON MIC.MaintenanceWindowID = MW.MaintenanceWindowID
	         WHERE ((MW.MaintenanceWindowName = @MaintenanceWindowName) OR ((@MaintenanceWindowName = 'PRINTONLY') AND (MW.MaintenanceWindowID > 1)))
               AND ((MIC.RangeScanCount > 0 AND @IgnoreRangeScans = 0) OR (@IgnoreRangeScans = 1))
          ORDER BY MIC.LastManaged ASC, MIC.SkipCount ASC, RangeScanCount DESC
	
	OPEN cuIndexList
	
		FETCH NEXT FROM cuIndexList
		INTO @DatabaseID, @DatabaseName, @SchemaName, @TableID, @TableName, @IndexID, @PartitionNumber, @IndexName, @IndexFillFactor, @OfflineOpsAllowed, @LastManaged, @LastScanned, @LastEvaluated, @SkipCount, @MaxSkipCount
		
		WHILE @@FETCH_STATUS = 0
		BEGIN  -- START -- CURSOR

			IF (@DebugMode = 1)
				PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... Assessing Index: ' + @DatabaseName + '.' + @SchemaName + '.' + @TableName + '(' + @IndexName + ' Partition: ' + CAST(@PartitionNumber AS VARCHAR) + ')'

            -- Only manage the current index if current database's tlog is not full, index skip count has been reached
            -- and there is still time in maintenance window.
            IF (((NOT EXISTS (SELECT * FROM dbo.DatabaseStatus WHERE DatabaseID = @DatabaseID AND IsLogFileFull = 1)) AND
                             (@SkipCount >= @MaxSkipCount)) AND
                             ((DATEADD(MILLISECOND,@FiveMinuteCheck,GETDATE())) < @MWEndTime))
            BEGIN -- START -- Maintain Indexes for Databases where TLog is not Full.

				IF (@DebugMode = 1)
					PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Evaluating Index'

			    SET @IndexOperation = 'NOOP'      --No Operation
				SET @ReasonForNOOP = 'No Reason.' --Default value.
			    SET @RebuildOnline = 1		      --If rebuild is going to execute it should be online.

				-- Update critical settings before maintaing to make sure the indexes are not disabled.
				--
			    SET @SQL = 'UPDATE dbo.MasterIndexCatalog
			                   SET IsDisabled = i.is_disabled,
			                       IndexPageLockAllowed = i.allow_page_locks
			                  FROM dbo.MasterIndexCatalog MIC
			                  JOIN [' + @DatabaseName + '].sys.indexes i
			                    ON MIC.DatabaseID = ' + CAST(@DatabaseID AS varchar) + '
			                   AND MIC.TableID = i.object_id 
			                   AND MIC.IndexID = i.index_id
							  JOIN [' + @DatabaseName + '].sys.partitions p
							    ON i.object_id = p.object_id
						       AND i.index_id = p.index_id
                             WHERE i.object_id = ' + CAST(@TableID AS varchar) + '
                               AND i.index_id = ' + CAST(@IndexID AS varchar)  + '
							   AND p.partition_number = ' + CAST(@PartitionNumber AS varchar)
                               
			    EXEC (@SQL)

			    SELECT @IsDisabled = IsDisabled,
                       @IndexPageLockAllowed = IndexPageLockAllowed,
                       @IsRSI = CASE WHEN (IndexType IN (5,6)) THEN 0 ELSE 1 END
			      FROM dbo.MasterIndexCatalog MIC
			     WHERE MIC.DatabaseID = @DatabaseID
			       AND MIC.TableID = @TableID
			       AND MIC.IndexID = @IndexID
				   AND MIC.PartitionNumber = @PartitionNumber

                -- Since it is not skipped; the skip counter is reinitialized to 0.
				-- Only adjust the skip counter if this is actual execution.
				IF (@PrintOnlyNoExecute = 0)
					UPDATE dbo.MasterIndexCatalog
					   SET SkipCount = 0,
						   LastEvaluated = GetDate()
					 WHERE DatabaseID = @DatabaseID
					   AND TableID = @TableID
					   AND IndexID = @IndexID 
					   AND PartitionNumber = @PartitionNumber
			 
			    IF (@IsDisabled = 0) -- 0 = Enabled, 1 = Disabled.
			    BEGIN -- START -- Decide on Index Operation
	
				    DECLARE @FragmentationLevel float
				    DECLARE @PageCount			bigint

                    SET @OpStartTime = GETDATE()

                    INSERT INTO dbo.MaintenanceHistory (MasterIndexCatalogID, Page_Count, Fragmentation, OperationType, OperationStartTime, OperationEndTime, ErrorDetails)
                    SELECT MIC.ID, 0, 0, 'FragScan', @OpStartTime, '1900-01-01 00:00:00', 'Index fragmentation started.'
                        FROM dbo.MasterIndexCatalog MIC
                    WHERE MIC.DatabaseID = @DatabaseID
                        AND MIC.TableID = @TableID
                        AND MIC.IndexID = @IndexID
                        AND MIC.PartitionNumber = @PartitionNumber
            
                    SET @IdentityValue = @@IDENTITY
                    
					IF (@IsRSI = 1)
					BEGIN -- START -- FRAGMENTATION SCAN

                        If (@DebugMode = 1)
                            PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... Checking fragmentation for Row Store Index.'

						SELECT @OpTime = dbo.svfCalculateOperationCost('FragScan',@DatabaseID,@TableID,@IndexID,@PartitionNumber,@PageCount,@DefaultOpTime)	
						SET @EstOpEndTime = DATEADD(MILLISECOND,@OpTime,GETDATE())

						IF ((@EstOpEndTime > @MWEndTime) AND (@PrintOnlyNoExecute = 0))
							INSERT INTO dbo.MaintenanceHistory (MasterIndexCatalogID, Page_Count, Fragmentation, OperationType, OperationStartTime, OperationEndTime, ErrorDetails)
							SELECT MIC.ID, 0, 0, 'WARNING', GETDATE(), GETDATE(), 'Trigging index fragmentation scan, operation will complete outside mainteance window constraint.'
							 FROM dbo.MasterIndexCatalog MIC
							WHERE MIC.DatabaseID = @DatabaseID
								AND MIC.TableID = @TableID
								AND MIC.IndexID = @IndexID
								AND MIC.PartitionNumber = @PartitionNumber

						SELECT @FragmentationLevel = avg_fragmentation_in_percent, @PageCount = page_count
						  FROM sys.dm_db_index_physical_stats(@DatabaseID,@TableID,@IndexID,@PartitionNumber,'LIMITED')
						 WHERE alloc_unit_type_desc = 'IN_ROW_DATA'

						SELECT @RebuildThreshold=RebuildThreshold, @ReorgThreshold=ReorgThreshold
						  FROM dbo.tvfGetThresholds(@PageCount)
					END
					ELSE
					BEGIN

                        If (@DebugMode = 1)
                            PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... Checking fragmentation for Column Store Index.'

						-- Fragmentation for column store indexes is decided by number of deleted rows.  Therefore
                        -- we will use the DMV to investigate the fragmentation.
                        --
                        -- https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-column-store-row-group-physical-stats-transact-sql?view=sql-server-ver15
                        --
						-- 0 - 20% NO ACTION, 20 - 25% Reorg, 25%+ Rebuild

						SET @RebuildThreshold = 25
						SET @ReorgThreshold = 20
						SET @PageCount = 0 -- Page Count for Column Indexes are not used to assess if it should be maintained.

						SET @SQL = 'SELECT @FragmentationOUT = SUM(deleted_rows*100.) / SUM(total_rows) 
						              FROM ' + @DatabaseName + '.sys.dm_db_column_store_row_group_physical_stats
						             WHERE object_id = @TableIDIN  AND index_id = @IndexIDIN'

						EXEC sp_executesql @SQL,N'@FragmentationOUT FLOAT OUTPUT, @TableIDIN INT, @IndexIDIN INT ',
						                   @FragmentationOUT=@FragmentationLevel OUTPUT,
										   @TableIDIN = @TableID,
										   @IndexIDIN = @IndexID
                        
					END -- END -- FRAGMENTATION SCAN

                    SET @OpEndTime = GETDATE()
            
                    UPDATE dbo.MaintenanceHistory 
                        SET OperationEndTime = @OpEndTime,
                            ErrorDetails = 'Index fragmentation scan completed.',
                            Fragmentation = @FragmentationLevel,
                            Page_Count = @PageCount
                        WHERE HistoryID = @IdentityValue

					IF (@PrintOnlyNoExecute = 0)
						UPDATE dbo.MasterIndexCatalog
						   SET LastScanned = @OpEndTime
						 WHERE DatabaseID = @DatabaseID
						   AND TableID = @TableID
						   AND IndexID = @IndexID 
						   AND PartitionNumber = @PartitionNumber
				

					IF (@DebugMode = 1)
					BEGIN
						IF (@IsRSI = 1)
							PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Index Size: ' + FORMAT(@PageCount, '###,###,###,###') + ' Page(s)'
						PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Index Fragmentation: ' + FORMAT(@FragmentationLevel, '##0.#0') + '%'
						PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Rebuild Threshold: ' + FORMAT(@RebuildThreshold, '###.#0') + '% Reorg Threshold: ' + FORMAT(@ReorgThreshold, '###.#0') + '%'
					END

                    IF (@IsRSI = 1)
                    BEGIN -- RSI -- Decide Index Operation

                        IF (@PageCount >= 64)
                        BEGIN
                            IF ((@FragmentationLevel >= @ReorgThreshold) AND (@FragmentationLevel < @RebuildThreshold))
                            BEGIN
                                IF (@IndexPageLockAllowed = 1)
                                    SET @IndexOperation = 'REORGANIZE'
                                ELSE
                                    SET @ReasonForNOOP = 'Index not maintained. (Reorg not possible, Allow Page Locks = Off; Rebuild Threshold not reached.'
                            END
                            ELSE IF (@FragmentationLevel >= @RebuildThreshold)
                            BEGIN
                                UPDATE MIC
                                   SET OnlineOpsSupported = 1
                                  FROM dbo.MasterIndexCatalog MIC
                                 WHERE MIC.DatabaseID = @DatabaseID
                                   AND MIC.TableID = @TableID
                                   AND MIC.IndexID = @IndexID
                                   AND MIC.PartitionNumber = @PartitionNumber

                                IF (@IndexID = 1)
                                BEGIN

                                    -- A cluster index can only be online if there are no lob column types
                                    -- in underline table definition.

                                    SET @SQL = 'DECLARE @RowsFound int
                                            
                                            SELECT @RowsFound = COUNT(*)
                                                FROM [' + @DatabaseName + '].sys.indexes i
                                                JOIN [' + @DatabaseName + '].sys.tables t
                                                ON i.object_id = t.object_id
                                                JOIN [' + @DatabaseName + '].sys.columns c
                                                ON t.object_id = c.object_id
                                                JOIN [' + @DatabaseName + '].sys.partitions p
                                                ON i.object_id = p.object_id
                                                AND i.index_id = p.index_id
                                                WHERE i.index_id = 1
                                                AND c.system_type_id IN (34,35,99,173)
                                                AND i.object_id = ' + CAST(@TableID AS varchar) + '

                                            IF (@RowsFound > 0)
                                            BEGIN
                                            
                                                -- When updating the Online Supported same rule will apply to all
                                                -- partitions.
                                                UPDATE dbo.MasterIndexCatalog
                                                SET OnlineOpsSupported = 0
                                                WHERE DatabaseID = ' + CAST(@DatabaseID AS varchar) + '
                                                AND TableID = ' + CAST(@TableID AS varchar) + '
                                                AND IndexID = 1
                                                    
                                            END'

                                    EXEC (@SQL)

                                END

                                SELECT @OnlineOpsSupported = OnlineOpsSupported
                                  FROM dbo.MasterIndexCatalog MIC
                                 WHERE MIC.DatabaseID = @DatabaseID
                                   AND MIC.TableID = @TableID
                                   AND MIC.IndexID = @IndexID
                                   AND MIC.PartitionNumber = @PartitionNumber

                                /* Condition Tree Logic - For Rebuild Decision
                                    Edition & 
                                    Online Supported     Offline Allowed     Page Lock   Action
                                    1                    x                   0           Rebuild Online (MAXDOP = 1)
                                    1                    x                   1           Rebuild Online (MAXDOP = Setting)
                                    1                    x                   0           Rebuild Online (MAXDOP = 1)
                                    1                    x                   1           Rebuild Online (MAXDOP = Setting)
                                    0                    0                   0           Error
                                    0                    0                   1           Reorgnize
                                    0                    1                   x           Rebuild Offline (MAXDOP = Setting) -- Assumed
                                    0                    1                   x           Rebuild Offline (MAXDOP = Setting) -- Assumed
                                */
                                SET @RebuildOnline = 0
                                SET @IndexOperation = 'REBUILD'
                                IF ((@ServerEdition = 3) AND (@OnlineOpsSupported = 1))
                                    SET @RebuildOnline = 1
                                ELSE
                                BEGIN
                                    IF ((@IndexPageLockAllowed = 1) AND (@OfflineOpsAllowed = 0))
                                        SET @IndexOperation = 'REORGANIZE'
                                    ELSE IF ((@IndexPageLockAllowed = 0) AND (@OfflineOpsAllowed = 0))
                                    BEGIN
                                        SET @IndexOperation = 'NOOP'
                                        SET @ReasonForNOOP = 'Index requires rebuild. However, Allow Offline Operation = Off & Edition <> Enterprise.'
                                    END
                                END
                            END
                            ELSE
                                SET @ReasonForNOOP = 'Low fragmentation (less then ' + FORMAT(@ReorgThreshold,'###.#0') + '%).'
                        END
                        ELSE
                            SET @ReasonForNOOP = 'Small table (less then 64KB).'
                    END
                    ELSE
                    BEGIN -- CSI -- Decide Index Operation
                        UPDATE MIC
                            SET OnlineOpsSupported = 0
                            FROM dbo.MasterIndexCatalog MIC
                            WHERE MIC.DatabaseID = @DatabaseID
                            AND MIC.TableID = @TableID
                            AND MIC.IndexID = @IndexID
                            AND MIC.PartitionNumber = @PartitionNumber
                        SET @OnlineOpsSupported = 0
                        IF ((@FragmentationLevel >= @ReorgThreshold) AND (@FragmentationLevel < @RebuildThreshold))                        
                            SET @IndexOperation = 'REORGANIZE'
                        ELSE IF (@FragmentationLevel >= @RebuildThreshold)
                        BEGIN
                            SET @ReasonForNOOP = 'Incomplete SOlution.'
                            IF ((@OfflineOpsAllowed = 1) AND (@SQLMajorBuild <= 14))
                            BEGIN
                                SET @IndexOperation = 'REBUILD'
                                SET @RebuildOnline = 0
                            END
                            ELSE IF ((@OfflineOpsAllowed = 0) AND (@SQLMajorBuild <= 14))
                                SET @ReasonForNOOP = 'Index requires rebuild.  However column-store indexes in SQL 2014 and older cannot be maintained online and Allow Offline Operation = Off'
                            ELSE
                                -- SQL Server 2019, recommended approach is to maintain the index using REORG vs REBUILD.
                                -- https://techcommunity.microsoft.com/t5/sql-server/columnstore-index-defragmentation-using-reorganize-command/ba-p/384653
                                SET @IndexOperation = 'REORGANIZE'
                        END
                    END								
			    END -- END -- Decide on Index Operation
				ELSE
				BEGIN -- START -- Index is disabled just record reason for NOOP
					SET @ReasonForNOOP = 'Index disabled.'
					IF (@DebugMode = 1)
						PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Index disabled.'
				END -- END -- Index is disabled just record reason for NOOP
				
			    IF (@IndexOperation <> 'NOOP')
			    BEGIN -- START -- Calculate and Execute Index Operation
				
				    -- Decisions around Index Operation has been made; therefore its time to do the actual work.
				    -- However before we can execute we must evaluate the maintenance window requirements.
				
				    DECLARE @IndexReorgTime		int
				    DECLARE @IndexRebuildTime	int
				 
					IF (@DebugMode = 1)
						PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Index Op Selected: ' + @IndexOperation

					DECLARE @PartitionCount INT

					SELECT @PartitionCount = COUNT(*) 
				      FROM dbo.MasterIndexCatalog MIC
					 WHERE MIC.DatabaseID = @DatabaseID
					   AND MIC.TableID = @TableID
					   AND MIC.IndexID = @IndexID

					-- Calculate the approx time for index operation.  This can be one of three values.
					--
					-- Chosing the largest of the three.
					-- Default Value : Mainteance Window Size / 10.
					-- Previous Operation History : Average
					-- Object of Similar Size (+/- 15%) : Average
					SELECT @OpTime = dbo.svfCalculateOperationCost(@IndexOperation,@DatabaseID,@TableID,@IndexID,@PartitionNumber,@PageCount,@DefaultOpTime)	
				    SET @EstOpEndTime = DATEADD(MILLISECOND,@OpTime,GETDATE())
				
					IF (@DebugMode = 1)
						PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Estimated Operation Completion DateTime ' + CONVERT(VARCHAR(255),@EstOpEndTime,121)

				    -- Confirm operation will complete before the Maintenance Window End Time.
				    IF (@EstOpEndTime < @MWEndTime)
				    BEGIN

						IF (@DebugMode = 1)
							PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... Possible to maintain index.'
				    
						-- Index is being maintained so we will decrement the MaxSkipCount by 1; minimum value is 0.
						-- Only adjust if it is actual execution.
						IF (@PrintOnlyNoExecute = 0)
							UPDATE dbo.MasterIndexCatalog
							   SET MaxSkipCount = CASE WHEN (@LastManaged = '1900-01-01 00:00:00.000') AND @MaxSkipCount > 0 THEN @MaxSkipCount - 1
													   WHEN (@LastManaged = '1900-01-01 00:00:00.000') AND @MaxSkipCount < 0 THEN 0
													   WHEN (@MaxSkipCount - DATEDIFF(DAY,@LastManaged,GETDATE()) < 1) THEN 0
													   ELSE @MaxSkipCount - DATEDIFF(DAY,@LastManaged,GETDATE()) END
							 WHERE DatabaseID = @DatabaseID
							   AND TableID = @TableID
							   AND IndexID = @IndexID 
							   AND PartitionNumber = @PartitionNumber
					
					    SET @SQL = 'USE [' + @DatabaseName + ']; '
						SET @SQL = @SQL + 'ALTER INDEX [' + @IndexName + '] '
						SET @SQL = @SQL + 'ON [' + @SchemaName + '].[' + @TableName + '] '
					    
                        IF (@IsRSI = 1)
                        BEGIN
                            IF (@IndexOperation = 'REORGANIZE')
                            BEGIN
                                SET @SQL = @SQL + 
                                        ' REORGANIZE'
                                IF (@PartitionCount > 1)
                                    SET @SQL = @SQL + ' PARTITION=' + CAST(@PartitionNumber AS VARCHAR)
                            END
                            ELSE
                            BEGIN

                                IF (@PrintOnlyNoExecute = 0)
                                BEGIN

                                    IF (@DebugMode = 1)
                                        PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Adjusting Fill Factor.  Before adjustment: ' + CAST(@IndexFillFactor AS VARCHAR)

                                    IF (@IndexFillFactor = 0)
                                    BEGIN
                                        SET @IndexFillFactor = 99
                                        SET @FFA = 0
                                    END
                                    ELSE
                                    BEGIN
                                        SET @FFA = dbo.svfCalculateFillfactor(@LastManaged,@PageCount)									
                                    END
                                    
                                    PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... Adjustment Recommended: ' + CAST(@FFA AS VARCHAR)
                                    SET @IndexFillFactor = @IndexFillFactor - @FFA
                                    
                                    IF (@IndexFillFactor < @MIN_FILL_FACTOR_SETTING)
                                    BEGIN
                                        SET @IndexFillFactor = @MIN_FILL_FACTOR_SETTING
                                        INSERT INTO dbo.MaintenanceHistory (MasterIndexCatalogID, Page_Count, Fragmentation, OperationType, OperationStartTime, OperationEndTime, ErrorDetails)
                                        SELECT MIC.ID, @PageCount, @FragmentationLevel, 'WARNING', GETDATE(), GETDATE(),
                                                'Index fill factor is dropping below 70%.  Please evaluate if the index is using a wide key, which might be causing excessive fragmentation.'
                                            FROM dbo.MasterIndexCatalog MIC
                                            WHERE MIC.DatabaseID = @DatabaseID
                                            AND MIC.TableID = @TableID
                                            AND MIC.IndexID = @IndexID 
                                            AND MIC.PartitionNumber = @PartitionNumber
                                    END
                                    
                                    IF (@DebugMode = 1)
                                        PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Adjusting Fill Factor.  After adjustment: ' + CAST(@IndexFillFactor AS VARCHAR)

                                    UPDATE dbo.MasterIndexCatalog
                                    SET IndexFillFactor = @IndexFillFactor
                                    WHERE DatabaseID = @DatabaseID
                                    AND TableID = @TableID
                                    AND IndexID = @IndexID 
                                    AND PartitionNumber = @PartitionNumber
                                END

                                SET @SQL = @SQL + 
                                        ' REBUILD '

                                IF (@PartitionCount > 1)
                                    SET @SQL = @SQL + ' PARTITION=' + CAST(@PartitionNumber AS VARCHAR) + ' WITH (SORT_IN_TEMPDB = ON,'
                                ELSE
                                    SET @SQL = @SQL + ' WITH (FILLFACTOR = ' + CAST(@IndexFillFactor AS VARCHAR) + ', SORT_IN_TEMPDB = ON,'


                                IF (@RebuildOnline = 1)
                                BEGIN
                                    SET @SQL = @SQL + 
                                        ' MAXDOP = ' + CASE WHEN @IndexPageLockAllowed = 0 THEN '1' ELSE CAST(@MAXDOP AS VARCHAR) END + ', ' +
                                        ' ONLINE = ON'
                                END
                                ELSE
                                BEGIN
                                    SET @SQL = @SQL + 
                                        ' MAXDOP = ' + CAST(@MAXDOP AS VARCHAR)
                                END

                                SET @SQL = @SQL + ');'
                        
                            END
                        END
                        ELSE
                        BEGIN
                            IF (@IndexOperation = 'REORGANIZE')
                            BEGIN
                                SET @SQL = @SQL + 
                                        ' REORGANIZE '
                                IF (@PartitionCount > 1)
                                    SET @SQL = @SQL + ' PARTITION=' + CAST(@PartitionNumber AS VARCHAR)
                                SET @SQL += ' WITH (COMPRESS_ALL_ROW_GROUPS=ON);'
                            END
                            ELSE 
                            BEGIN
                                SET @SQL += ' REBUILD'
                                IF (@PartitionCount > 1)
                                    SET @SQL = @SQL + ' PARTITION=' + CAST(@PartitionNumber AS VARCHAR)
                                SET @SQL += ' WITH (MAXDOP = ' + CAST(@MAXDOP AS VARCHAR) + ');'
                            END
                        END
					
					    SET @OpStartTime = GETDATE()

						-- Only Log if actual execution.
						IF (@PrintOnlyNoExecute = 0)
						BEGIN
							INSERT INTO dbo.MaintenanceHistory (MasterIndexCatalogID, Page_Count, Fragmentation, OperationType, OperationStartTime, OperationEndTime, ErrorDetails)
							SELECT MIC.ID,
								   @PageCount,
								   @FragmentationLevel,
								   CASE WHEN @RebuildOnline = 1 THEN
									  @IndexOperation + ' (ONLINE)'
								   ELSE
									  @IndexOperation + ' (OFFLINE)'
								   END, @OpStartTime, '1900-01-01 00:00:00','Executing (' + @SQL + ').'
							  FROM dbo.MasterIndexCatalog MIC
							 WHERE MIC.DatabaseID = @DatabaseID
							   AND MIC.TableID = @TableID
							   AND MIC.IndexID = @IndexID 
							   AND MIC.PartitionNumber = @PartitionNumber

							SET @IdentityValue = @@IDENTITY
						END
							   
						IF ((@PrintOnlyNoExecute = 1) AND (@DebugMode = 0))
							Print @SQL
						ELSE IF ((@PrintOnlyNoExecute = 1) AND (@DebugMode = 1))
							PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... ' + @SQL
						ELSE
						BEGIN
							IF (@DebugMode = 1)
								PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... Starting index mainteance operation. ' + CONVERT(VARCHAR(255),GETDATE(),121)
							EXEC (@SQL)
							IF (@DebugMode = 1)
								PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... Finished index mainteance operation. ' + CONVERT(VARCHAR(255),GETDATE(),121)
						END
					
					    SET @OpEndTime = GETDATE()
					
						-- Only update if actual execution.
						IF (@PrintOnlyNoExecute = 0)
							UPDATE dbo.MasterIndexCatalog
							   SET LastManaged = @OpEndTime
							 WHERE DatabaseID = @DatabaseID
							   AND TableID = @TableID
							   AND IndexID = @IndexID 
							   AND PartitionNumber = @PartitionNumber
				
						-- Only Log if actual execution.
						IF (@PrintOnlyNoExecute = 0)
							UPDATE dbo.MaintenanceHistory
							   SET OperationEndTime = @OpEndTime,
								   ErrorDetails = 'Completed. Command executed (' + @SQL + ')'
							 WHERE HistoryID = @IdentityValue

                        -- Check to make sure the transaction log file on the current database is not full.
                        -- If the transaction log file is full, we cannot maintain any more indexes for current database.

						IF (@PrintOnlyNoExecute = 0)
						BEGIN
							IF (@DebugMode =1)
								PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... Checking for TLog space'

							DECLARE @TLogAutoGrowthSet BIT = 0
							DECLARE @MaxSet BIT = 0
							DECLARE @DiskSpacePercentage FLOAT = 0
							SET @LogSpacePercentage = 0

							SELECT @TLogAutoGrowthSet = MAX(CASE WHEN growth = 0 THEN 0 ELSE 1 END),
								   @MaxSet = MAX(CASE WHEN max_size = 268435456 THEN 0 ELSE 1 END)
							  FROM sys.master_files WHERE database_id = @DatabaseID AND type_desc = 'LOG'

							SELECT @DiskSpacePercentage = ((sum(total_bytes/1024./1024) - sum(available_bytes/1024./1024)) * 100)/sum(total_bytes/1024./1024)
							  FROM sys.master_files mf
							 CROSS APPLY sys.dm_os_volume_stats(mf.database_id,mf.file_id)
							 WHERE mf.type_desc = 'LOG'
							   AND mf.database_id = @DatabaseID

							IF EXISTS (SELECT * FROM tempdb.sys.all_objects WHERE name LIKE '#TLogSpace%')
								DELETE FROM #TLogSpace
							ELSE
								CREATE TABLE #TLogSpace (DBName sysname, LogSize float, LogSpaceUsed float, LogStatus smallint)

							INSERT INTO #TLogSpace
							EXEC ('DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS')

							SELECT @LogSpacePercentage = LogSpaceUsed
							  FROM #TLogSpace
							 WHERE DBName = db_name(@DatabaseID)						
						
							IF (((@TLogAutoGrowthSet = 0) AND (@LogSpacePercentage > @MaxLogSpaceUsageBeforeStop)) OR
								((@TLogAutoGrowthSet = 1) AND (@MaxSet = 1) AND (@LogSpacePercentage > @MaxLogSpaceUsageBeforeStop)) OR
								((@TLogAutoGrowthSet = 1) AND (@MaxSet = 0) AND (@TLogAutoGrowthSet > @MaxLogSpaceUsageBeforeStop)))
							BEGIN
								IF (@DebugMode =1)
									PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... Log usage reached maximum.  No more indexes for database [' + @DatabaseName + '].'

								INSERT INTO dbo.MaintenanceHistory (MasterIndexCatalogID, Page_Count, Fragmentation, OperationType, OperationStartTime, OperationEndTime, ErrorDetails)
								SELECT MIC.ID, @PageCount, @FragmentationLevel, 'WARNING', GETDATE(), GETDATE(),
									   'Database reached Max Log Space Usage limit, therefore no further indexes will be maintained in this maintenance window current database.'
								  FROM dbo.MasterIndexCatalog MIC
								 WHERE MIC.DatabaseID = @DatabaseID
								   AND MIC.TableID = @TableID
								   AND MIC.IndexID = @IndexID 
								   AND MIC.PartitionNumber = @PartitionNumber

								UPDATE dbo.DatabaseStatus
								   SET IsLogFileFull = 1
								 WHERE DatabaseID = @DatabaseID
							END
						END

				    END
				    ELSE
				    BEGIN -- BEING -- Index Skipped due to Maintenance Window constraint
				
					    IF (@LastManaged < DATEADD(DAY,-14,GETDATE()))
					    BEGIN

                            -- If we have not been able to maintain this index due to estimated mainteance cost
							-- based on statistics analysis above, we should flag this for the dba team.
							--
							-- This means this index is too large to maintain for current mainteance windows defined.
							-- Team should look at creating a larger window for this index.
										
						    INSERT INTO dbo.MaintenanceHistory (MasterIndexCatalogID, Page_Count, Fragmentation, OperationType, OperationStartTime, OperationEndTime, ErrorDetails)
						    SELECT MIC.ID, @PageCount, @FragmentationLevel, 'WARNING', GETDATE(), GETDATE(),
						           'Index has not been managed in last 14 day due to maintenance window constraint.'
                              FROM dbo.MasterIndexCatalog MIC
					         WHERE MIC.DatabaseID = @DatabaseID
					           AND MIC.TableID = @TableID
					           AND MIC.IndexID = @IndexID 
								       
					    END

						-- Index was skipped due to maintenance window constraints.
                        -- i.e. if this index was to be maintained based on previous history it would go past the
                        -- maintenance window threshold.  Therefore it was skipped.  However if it is maintained
                        -- at start of maintenance window it should get maintained next cycle.
						--
						-- Only adjust SKIP/MAXSKIP Counts if it is real maintenance.

						IF (@PrintOnlyNoExecute = 0)
							UPDATE dbo.MasterIndexCatalog
							   SET SkipCount = @MaxSkipCount
							 WHERE DatabaseID = @DatabaseID
							   AND TableID = @TableID
							   AND IndexID = @IndexID 
							   AND PartitionNumber = @PartitionNumber
					
					    SET @EstOpEndTime = DATEADD(MILLISECOND,@FiveMinuteCheck,GETDATE())
					
					    -- We have reached the end of mainteance window therefore
					    -- we do not want to maintain any additional indexes.
					    IF (@EstOpEndTime > @MWEndTime)
						    RETURN
					
				    END -- END -- Index Skipped due to Maintenance Window constraint
			    END -- END -- Calculate and Execute Index Operation
			    ELSE
			    BEGIN -- START -- No Operation for current Index.
			    
					-- If index is not disabled we need to do some calculation regarding FFA, because if NOOP was chosen
					-- for an active index, it means it is not fragmented therefore we can adjust the Fill Factor setting 
					-- to better tune it for next time it becomes fragmented.
					--
					-- However if index is disabled we do not need to do anything just record it in history table the state
					-- and reason for NOOP.  Only adjust Fill Factor setting if it is actual run.
					
					IF ((@IsDisabled = 0) AND (@PrintOnlyNoExecute = 0))
					BEGIN -- START -- No Operation for current index and it is not disabled
					
						IF (@DebugMode = 1)
							PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Adjusting Fill Factor.  Before adjustment: ' + CAST(@IndexFillFactor AS VARCHAR)

                        IF (@IsRSI = 1)
                        BEGIN
                            IF (@IndexFillFactor = 0)
                            BEGIN
                                SET @IndexFillFactor = 99
                                SET @FFA = 0
                            END
                            ELSE
                            BEGIN
                                SET @FFA = dbo.svfCalculateFillfactor(@LastScanned,@PageCount)

                                IF (@FFA < 1)
                                    SET @FFA = 1

                                IF (@FFA > 5)
                                    SET @FFA = 5
                            END
                            
                            PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... ... Adjustment Recommended: ' + CAST(@FFA AS VARCHAR)
                            SET @IndexFillFactor = @IndexFillFactor + @FFA
                                        
                            IF (@IndexFillFactor > 99)
                                SET @IndexFillFactor = 99
                                
                            IF (@DebugMode = 1)
                                PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Adjusting Fill Factor.  After adjustment: ' + CAST(@IndexFillFactor AS VARCHAR)
                            END
                        ELSE
                            SET @IndexFillFactor = 0

						UPDATE dbo.MasterIndexCatalog
						   SET IndexFillFactor = @IndexFillFactor,
							   MaxSkipCount = CASE WHEN (@LastScanned = '1900-01-01 00:00:00.000') AND @MaxSkipCount >= 0 THEN @MaxSkipCount + 1
												   WHEN (@LastScanned = '1900-01-01 00:00:00.000') AND @MaxSkipCount < 0 THEN 0
												   WHEN (@MaxSkipCount + DATEDIFF(DAY,@LastScanned,GetDate()) > 30) THEN 30
												   ELSE @MaxSkipCount + DATEDIFF(DAY,@LastScanned,GetDate()) END
						 WHERE DatabaseID = @DatabaseID
						   AND TableID = @TableID
						   AND IndexID = @IndexID
						   AND PartitionNumber = @PartitionNumber

					END -- END -- No Operation for current index and it is not disabled

					IF ((@LogNOOPMsgs = 1) AND (@PrintOnlyNoExecute = 0))
						INSERT INTO dbo.MaintenanceHistory (MasterIndexCatalogID, Page_Count, Fragmentation, OperationType, OperationStartTime, OperationEndTime, ErrorDetails)
						SELECT MIC.ID,
							   @PageCount,
							   @FragmentationLevel,
							  'NOOP', @OpStartTime, @OpEndTime, @ReasonForNOOP
						 FROM dbo.MasterIndexCatalog MIC
						WHERE MIC.DatabaseID = @DatabaseID
						  AND MIC.TableID = @TableID
						  AND MIC.IndexID = @IndexID 
						  AND MIC.PartitionNumber = @PartitionNumber
							
			    END -- END -- No Operation for current Index.
			
            END -- END -- Maintain Indexes for Databases where TLog is not Full.
            ELSE
            BEGIN -- START -- Either TLog is Full or Skip Count has not reached Max Skip Count or We are out of time!

				IF (@DebugMode = 1)
				BEGIN
					IF EXISTS (SELECT * FROM dbo.DatabaseStatus WHERE DatabaseID = @DatabaseID AND IsLogFileFull = 1)
						PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Skipping Index - TLog Full'

					IF (@SkipCount < @MaxSkipCount)
						PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Skipping Index - Max Skip Count not reached (' + CAST(@SkipCount AS VARCHAR) + '/' + CAST(@MaxSkipCount AS VARCHAR) + ')'

					IF ((DATEADD(MILLISECOND,@FiveMinuteCheck,GETDATE())) > @MWEndTime)
						PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Skipping Index - Mainteance Window End Time Reached'
				END

                -- There is no operation to execute if database TLog is full.  However if 
                -- skip count has not been reached.  We must increment Skip Count for next time.
                --
                -- However if Database TLog is full then the index in fact did not get skipped, it got ignored.
                -- Therefore skip counter should not be adjusted; neither should the last evaluated date
                -- as index was not evaluated due to tlog being full.

                IF ((NOT EXISTS (SELECT * FROM dbo.DatabaseStatus WHERE DatabaseID = @DatabaseID AND IsLogFileFull = 1)) AND
                    (DATEADD(MILLISECOND,@FiveMinuteCheck,GETDATE())) < @MWEndTime)
                BEGIN -- START -- Database T-Log Is Not Full And We Are Not Out Of Time; i.e. Index was skipped due to skip count.
                    IF (@SkipCount <= @MaxSkipCount)
                    BEGIN -- START -- Increment Skip Count

						-- Only Adjust Skip Count Values if Normal Run
						IF (@PrintOnlyNoExecute = 0)
						BEGIN

							IF (@DebugMode = 1)
								PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Increasing skip count.'

							UPDATE dbo.MasterIndexCatalog
							   SET SkipCount = @SkipCount + DATEDIFF(DAY,@LastEvaluated,GetDate()),
								   LastEvaluated = GetDate()
							 WHERE DatabaseID = @DatabaseID
							   AND TableID = @TableID
							   AND IndexID = @IndexID 
							   AND PartitionNumber = @PartitionNumber
						END

                    END -- END -- Increment Skip Count
                END -- END -- Database T-Log Is Not Full And We Are Not Out Of Time
                ELSE
                BEGIN
                    IF ((NOT EXISTS (SELECT * FROM dbo.DatabaseStatus WHERE DatabaseID = @DatabaseID AND IsLogFileFull = 1)) AND
                        (DATEADD(MILLISECOND,@FiveMinuteCheck,GETDATE())) > @MWEndTime)
                    BEGIN -- START -- Database T-Log Is Not Full But We Are Out Of Time	
						IF (@DebugMode = 1)
							PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' ... ... Reached end of mainteance window.'
                        GOTO TheEnd
                    END -- END -- Database T-Log Is Not Full But We Are Out Of Time
                END
            END -- END -- Either TLog is Full or Skip Count has not reached Max Skip Count

			FETCH NEXT FROM cuIndexList
			INTO @DatabaseID, @DatabaseName, @SchemaName, @TableID, @TableName, @IndexID, @PartitionNumber, @IndexName, @IndexFillFactor, @OfflineOpsAllowed, @LastManaged, @LastScanned, @LastEvaluated, @SkipCount, @MaxSkipCount
		
		END -- END -- CURSOR
		
	CLOSE cuIndexList
	
	DEALLOCATE cuIndexList
	-- End of Stored Procedure

TheEnd:
PRINT FORMAT(GETDATE(),'yyyy-MM-dd HH:mm:ss') + ' Finishing index mainteance operation.'

END
GO