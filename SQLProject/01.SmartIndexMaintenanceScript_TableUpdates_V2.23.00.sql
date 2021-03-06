USE [SQLSIM]
GO

/* To prevent any potential data loss issues, you should review this script in detail before running it outside the context of the database designer.*/
BEGIN TRANSACTION
SET QUOTED_IDENTIFIER ON
SET ARITHABORT ON
SET NUMERIC_ROUNDABORT OFF
SET CONCAT_NULL_YIELDS_NULL ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
COMMIT
BEGIN TRANSACTION
GO
ALTER TABLE dbo.MaintenanceWindow SET (LOCK_ESCALATION = TABLE)
GO
COMMIT
select Has_Perms_By_Name(N'dbo.MaintenanceWindow', 'Object', 'ALTER') as ALT_Per, Has_Perms_By_Name(N'dbo.MaintenanceWindow', 'Object', 'VIEW DEFINITION') as View_def_Per, Has_Perms_By_Name(N'dbo.MaintenanceWindow', 'Object', 'CONTROL') as Contr_Per BEGIN TRANSACTION
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfIndexFillFactor
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfIsDisabled
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfIsPageLockAllowed
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfOfflineOpsAllowed
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfRangeScanCount
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfSingletonLookupCount
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfLastRangeScanCount
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfLastSingletonLookupCount
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfOnlineOpsSupported
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfSkipCount
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfMaxSkipCount
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfMaintenanceWindowID
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfLastScanned
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfLastManaged
GO
ALTER TABLE dbo.MasterIndexCatalog
	DROP CONSTRAINT dfLastEvaluated
GO
CREATE TABLE dbo.Tmp_MasterIndexCatalog
	(
	ID bigint NOT NULL IDENTITY (1, 1),
	DatabaseID int NOT NULL,
	DatabaseName nvarchar(255) NOT NULL,
	SchemaID int NOT NULL,
	SchemaName nvarchar(255) NOT NULL,
	TableID bigint NOT NULL,
	TableName nvarchar(255) NOT NULL,
	IndexID int NOT NULL,
	IndexName nvarchar(255) NOT NULL,
	IndexType int NOT NULL,
	PartitionNumber int NOT NULL,
	IndexFillFactor tinyint NULL,
	IsDisabled bit NOT NULL,
	IndexPageLockAllowed bit NULL,
	OfflineOpsAllowed bit NULL,
	RangeScanCount bigint NOT NULL,
	SingletonLookupCount bigint NOT NULL,
	LastRangeScanCount bigint NOT NULL,
	LastSingletonLookupCount bigint NOT NULL,
	OnlineOpsSupported bit NULL,
	SkipCount int NOT NULL,
	MaxSkipCount int NOT NULL,
	MaintenanceWindowID int NULL,
	LastScanned datetime NOT NULL,
	LastManaged datetime NULL,
	LastEvaluated datetime NOT NULL
	)  ON [PRIMARY]
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog SET (LOCK_ESCALATION = TABLE)
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	DF_MasterIndexCatalog_IndexType DEFAULT 0 FOR IndexType
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfIndexFillFactor DEFAULT ((95)) FOR IndexFillFactor
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfIsDisabled DEFAULT ((0)) FOR IsDisabled
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfIsPageLockAllowed DEFAULT ((1)) FOR IndexPageLockAllowed
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfOfflineOpsAllowed DEFAULT ((0)) FOR OfflineOpsAllowed
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfRangeScanCount DEFAULT ((0)) FOR RangeScanCount
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfSingletonLookupCount DEFAULT ((0)) FOR SingletonLookupCount
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfLastRangeScanCount DEFAULT ((0)) FOR LastRangeScanCount
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfLastSingletonLookupCount DEFAULT ((0)) FOR LastSingletonLookupCount
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfOnlineOpsSupported DEFAULT ((1)) FOR OnlineOpsSupported
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfSkipCount DEFAULT ((0)) FOR SkipCount
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfMaxSkipCount DEFAULT ((0)) FOR MaxSkipCount
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfMaintenanceWindowID DEFAULT ((1)) FOR MaintenanceWindowID
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfLastScanned DEFAULT ('1900-01-01') FOR LastScanned
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfLastManaged DEFAULT ('1900-01-01') FOR LastManaged
GO
ALTER TABLE dbo.Tmp_MasterIndexCatalog ADD CONSTRAINT
	dfLastEvaluated DEFAULT (getdate()) FOR LastEvaluated
GO
SET IDENTITY_INSERT dbo.Tmp_MasterIndexCatalog ON
GO
IF EXISTS(SELECT * FROM dbo.MasterIndexCatalog)
	 EXEC('INSERT INTO dbo.Tmp_MasterIndexCatalog (ID, DatabaseID, DatabaseName, SchemaID, SchemaName, TableID, TableName, IndexID, IndexName, PartitionNumber, IndexFillFactor, IsDisabled, IndexPageLockAllowed, OfflineOpsAllowed, RangeScanCount, SingletonLookupCount, LastRangeScanCount, LastSingletonLookupCount, OnlineOpsSupported, SkipCount, MaxSkipCount, MaintenanceWindowID, LastScanned, LastManaged, LastEvaluated)
		SELECT ID, DatabaseID, DatabaseName, SchemaID, SchemaName, TableID, TableName, IndexID, IndexName, PartitionNumber, IndexFillFactor, IsDisabled, IndexPageLockAllowed, OfflineOpsAllowed, RangeScanCount, SingletonLookupCount, LastRangeScanCount, LastSingletonLookupCount, OnlineOpsSupported, SkipCount, MaxSkipCount, MaintenanceWindowID, LastScanned, LastManaged, LastEvaluated FROM dbo.MasterIndexCatalog WITH (HOLDLOCK TABLOCKX)')
GO
SET IDENTITY_INSERT dbo.Tmp_MasterIndexCatalog OFF
GO
ALTER TABLE dbo.MaintenanceHistory
	DROP CONSTRAINT fkMasterIndexCatalogID_MasterIndexCatalog_ID
GO
DROP TABLE dbo.MasterIndexCatalog
GO
EXECUTE sp_rename N'dbo.Tmp_MasterIndexCatalog', N'MasterIndexCatalog', 'OBJECT' 
GO
ALTER TABLE dbo.MasterIndexCatalog ADD CONSTRAINT
	pkMasterIndexCatalog_ID PRIMARY KEY CLUSTERED 
	(
	ID
	) WITH( STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]

GO
ALTER TABLE dbo.MasterIndexCatalog ADD CONSTRAINT
	fkMaintenanceWindowID_MasterIndexCatalog_MaintenanceWindowID FOREIGN KEY
	(
	MaintenanceWindowID
	) REFERENCES dbo.MaintenanceWindow
	(
	MaintenanceWindowID
	) ON UPDATE  NO ACTION 
	 ON DELETE  NO ACTION 
	
GO
COMMIT
select Has_Perms_By_Name(N'dbo.MasterIndexCatalog', 'Object', 'ALTER') as ALT_Per, Has_Perms_By_Name(N'dbo.MasterIndexCatalog', 'Object', 'VIEW DEFINITION') as View_def_Per, Has_Perms_By_Name(N'dbo.MasterIndexCatalog', 'Object', 'CONTROL') as Contr_Per BEGIN TRANSACTION
GO
ALTER TABLE dbo.MaintenanceHistory ADD CONSTRAINT
	fkMasterIndexCatalogID_MasterIndexCatalog_ID FOREIGN KEY
	(
	MasterIndexCatalogID
	) REFERENCES dbo.MasterIndexCatalog
	(
	ID
	) ON UPDATE  NO ACTION 
	 ON DELETE  NO ACTION 
	
GO
ALTER TABLE dbo.MaintenanceHistory SET (LOCK_ESCALATION = TABLE)
GO
COMMIT
select Has_Perms_By_Name(N'dbo.MaintenanceHistory', 'Object', 'ALTER') as ALT_Per, Has_Perms_By_Name(N'dbo.MaintenanceHistory', 'Object', 'VIEW DEFINITION') as View_def_Per, Has_Perms_By_Name(N'dbo.MaintenanceHistory', 'Object', 'CONTROL') as Contr_Per 