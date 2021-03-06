-- **INSTALL SCRIPT MIGHT NOT HAVE LATEST SPROCS

 /* Azure SQL Elastic Pool Database Consolidator / Importer Install
 * ----------------------------------------------------------
 * Requirements: 
 * - SQL login with access to master and create database or dbManager role
 * - Created Elastic Pool (ensure Per Database Resources are at Maximum eDTU)
 *
 * Author: Ruy Delgado
 * 1/31/2019 v007
 */

-- START HERE >> Is Pool Created?
-- Set Config Variables below and Hit Execute [F5 on SSMS]

DECLARE @PoolName NVARCHAR(100) = 'DBPool';

DECLARE @RepoMaster NVARCHAR(100) = 'DBRepoMaster';
DECLARE @RepoName NVARCHAR(100) = 'DBRepo';
DECLARE @RepoLobs NVARCHAR(100) = 'DBRepoNotes';

DECLARE @CredName NVARCHAR(100) = 'PoolCred';
DECLARE @CredIdentity NVARCHAR(100) = 'pool_user';
DECLARE @CredSecret NVARCHAR(100) = '1234';
DECLARE @MasterKeySecret NVARCHAR(100) = '1234';

--*END OF CONFIG
--*RUN/EXECUTE/F5*****************************************  

PRINT 'DETECTING VARIABLES...' 
DECLARE @ServerName NVARCHAR(100) = CAST(SERVERPROPERTY('SERVERNAME') AS NVARCHAR) 
DECLARE @AzureUrl NVARCHAR(100) = @ServerName + N'.database.windows.net';
DECLARE @IsAzure BIT = IIF(SERVERPROPERTY('EngineEdition') = 5, 1, 0);
DECLARE @query NVARCHAR(MAX);
DECLARE @IsInstalled BIT = 0; 

IF @IsAzure = 1 
BEGIN 
	PRINT 'CHECKING REQUIREMENTS...'
	IF NOT EXISTS(SELECT elastic_pool_name FROM sys.database_service_objectives WHERE elastic_pool_name = @PoolName)
	BEGIN 
		PRINT 'Elastic Pool not yet created, stopping. Please configure ' + @PoolName +' via PS, CLI or Azure Portal before continuing...';
		GOTO AbortEnd 
	END 
	ELSE 
	BEGIN 
		PRINT 'ELASTIC POOL CHECK: PASSED' 	 
	END
END
  
IF DB_NAME() <> 'master' AND DB_NAME() <> @RepoMaster 
BEGIN 

	IF NOT EXISTS (SELECT name FROM sys.databases WHERE Name = @RepoMaster)
		PRINT 'PLEASE SELECT master DATABASE TO START INSTALLATION'; 
	ELSE 
		PRINT 'PLEASE SELECT ' + @RepoMaster + ' TO CONTINUE INSTALL'; 

	GOTO AbortEnd 

END 

--STEP 1 
IF DB_NAME() = 'master' 
BEGIN 

	PRINT 'MASTER DETECTED, INSTALLING REPO: ' + @RepoMaster + ' > ' + @RepoName + ' + ' +@RepoLobs; 

	IF NOT EXISTS(SELECT name FROM sys.databases WHERE Name = @RepoMaster) 
	BEGIN
		PRINT 'CREATING RepoMaster DB...' 
		EXEC('CREATE DATABASE ' + @RepoMaster);
	END 

	IF NOT EXISTS(SELECT name FROM sys.databases WHERE Name = @RepoName) 
	BEGIN
		PRINT 'Main DB...' 
		EXEC('CREATE DATABASE ' + @RepoName);
	END

	IF NOT EXISTS(SELECT name FROM sys.databases WHERE Name = @RepoLobs) 
	BEGIN
		PRINT 'Notes DB...' 
		EXEC('CREATE DATABASE ' + @RepoLobs);
	END

	IF @IsAzure = 1
	BEGIN
		PRINT 'CONFIGURING POOL...'  
		EXEC('ALTER DATABASE [' + @RepoMaster + '] MODIFY ( SERVICE_OBJECTIVE = ELASTIC_POOL ( name = [' + @PoolName + ']));');
		EXEC('ALTER DATABASE ' + @RepoName + ' MODIFY ( SERVICE_OBJECTIVE = ELASTIC_POOL ( name = ' + @PoolName + '));'); 
		EXEC('ALTER DATABASE ' + @RepoLobs + ' MODIFY ( SERVICE_OBJECTIVE = ELASTIC_POOL ( name = ' + @PoolName + '));');		
	END 
	PRINT 'STEP 1 COMPLETED. PLEASE SELECT OR USE DATABASE ' + @RepoMaster + ' AND EXECUTE [F5] AGAIN TO CONTINUE...'; 
END 
 
IF DB_NAME() = @RepoMaster  
	BEGIN 
 	--STEP 2 - Change DB to @RepoMaster and RUN
		
	IF @IsAzure = 1 
	BEGIN 
	
		IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE symmetric_key_id = 101)
		BEGIN
		PRINT 'Creating Database Master Key'
		EXEC('CREATE MASTER KEY ENCRYPTION BY PASSWORD = ''' + @MasterKeySecret + ''';');
		END
	
		--FOR MASTER AND EACH DS
		IF NOT EXISTS (SELECT * FROM sys.database_scoped_credentials WHERE [name] = @CredName) 
		BEGIN 
			PRINT 'Creating Scoped Credential ' + @CredName; 
			SET @query = N'CREATE DATABASE SCOPED CREDENTIAL ['+@CredName+'] WITH IDENTITY = N'''+@CredIdentity+''', SECRET = N'''+@CredSecret+''';';
			PRINT @query;
			EXEC @query; 
		END 
	
		--DATASOURCES
		IF NOT EXISTS (SELECT * FROM sys.external_data_sources WHERE [name] = 'RepoDS')	
		BEGIN
			PRINT 'CREATING MAIN DS';
			EXEC('CREATE EXTERNAL DATA SOURCE [RepoDS] WITH (TYPE = RDBMS, LOCATION = ''' + @AzureUrl + ''', 
			CREDENTIAL = [' + @CredName + '], DATABASE_NAME = ''' + @RepoName + ''')');

			EXEC sp_execute_remote N'RepoDS', @query; 
		END 
				
		IF NOT EXISTS (SELECT * FROM sys.external_data_sources WHERE [name] = 'RepoNotesDS') 
		BEGIN 
			PRINT 'CREATING NOTES DS';
			EXEC('CREATE EXTERNAL DATA SOURCE [RepoNotesDS] WITH (TYPE = RDBMS, LOCATION = ''' + @AzureUrl + ''', 
			CREDENTIAL = ['+ @CredName+'], DATABASE_NAME = '''+@RepoLobs+''')');

			--CREDENTIAL 
			EXEC sp_execute_remote N'RepoNotesDS', @query; 
		END		
		
		IF OBJECT_ID('repo_objs') IS NULL 
		BEGIN 
			PRINT 'Creating repo.objects...'
			EXEC('CREATE EXTERNAL TABLE [repo_objs] (name sysname, object_id int,principal_id int,schema_id int,parent_object_id int, type char(2)) WITH (DATA_SOURCE = [RepoDS], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''objects'');'); 
		END

		IF OBJECT_ID('note_objs') IS NULL 
		BEGIN 
			PRINT 'Creating note.objects...'
			EXEC('CREATE EXTERNAL TABLE [note_objs] (name sysname, object_id int,principal_id int,schema_id int,parent_object_id int, type char(2)) WITH (DATA_SOURCE = [RepoNotesDS], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''objects'');');
		END

	END

	IF NOT EXISTS(SELECT name FROM sys.types WHERE name = 's_objs' AND is_user_defined = 1)		
	BEGIN
 		CREATE TYPE s_objs AS TABLE (name sysname,object_id int,principal_id int,schema_id int,parent_object_id int, type char(2));
	END

	IF NOT EXISTS(SELECT name FROM sys.types WHERE name = 's_cols' AND is_user_defined = 1) 
	BEGIN
		CREATE TYPE s_cols AS TABLE (object_id	int, name sysname, column_id int, system_type_id tinyint, user_type_id	int, max_length	smallint, precision	tinyint, scale tinyint, is_nullable	bit, is_rowguidcol	bit, is_identity bit, is_computed bit); 
	END

	IF NOT EXISTS(SELECT name FROM sys.types WHERE name = 's_tables' AND is_user_defined = 1) 
	BEGIN
		CREATE TYPE s_tables AS TABLE (name sysname, object_id	int, principal_id int, schema_id	int, parent_object_id int, is_filetable bit, is_memory_optimized	bit, is_external	bit);
	END

	IF NOT EXISTS(SELECT name FROM sys.types WHERE name = 's_schemas' AND is_user_defined = 1) 
	BEGIN
		CREATE TYPE s_schemas AS TABLE (name sysname, schema_id int, principal_id int);
	END

	IF NOT EXISTS(SELECT name FROM sys.types WHERE name = 's_cmps' AND is_user_defined = 1) 
	BEGIN
		CREATE TYPE s_cmps AS TABLE (object_id	int, name sysname, column_id int, system_type_id tinyint, user_type_id	int, max_length	smallint, precision	tinyint, scale tinyint, is_nullable	bit, is_rowguidcol	bit, is_identity bit, is_computed bit, definition nvarchar(max) null, is_persisted bit);
	END

	IF NOT EXISTS(SELECT name FROM sys.types WHERE name = 's_types' AND is_user_defined = 1) 
	BEGIN
		CREATE TYPE s_types AS TABLE (name sysname,system_type_id tinyint,user_type_id int,schema_id int,principal_id int,max_length smallint,precision tinyint,scale	tinyint,is_nullable bit,is_user_defined	bit,is_assembly_type bit,default_object_id int,rule_object_id	int,is_table_type	bit);
	END

	IF NOT EXISTS(SELECT name FROM sys.types WHERE name = 's_indexes' AND is_user_defined = 1) 
	BEGIN		
		CREATE TYPE s_indexes AS TABLE (name SYSNAME, object_id INT, index_id INT, type TINYINT, is_unique BIT, is_primary_key BIT);
	END
	   
	IF NOT EXISTS(SELECT name FROM sys.types WHERE name = 's_keys' AND is_user_defined = 1) 
	BEGIN	 		
		CREATE TYPE s_keys AS TABLE (name sysname, object_id int, principal_id int, schema_id int, parent_object_id int, type char(2), create_date datetime, modify_date datetime, unique_index_id int, is_system_named bit);
	END

	IF NOT EXISTS(SELECT name FROM sys.types WHERE name = 's_fkeys' AND is_user_defined = 1) 
	BEGIN		
		CREATE TYPE s_fkeys AS TABLE (name sysname, object_id int, principal_id int, schema_id int, parent_object_id int, type char(2), create_date datetime, modify_date datetime, referenced_object_id int, is_system_named bit);
	END

	
	--IMPORTER TABLES 
	IF OBJECT_ID('ImportConfig') IS NULL 
	CREATE TABLE [dbo].[ImportConfig](
		[ID] [int] IDENTITY(1,1) NOT NULL,
		[DateTimeFrom] [datetimeoffset](7) NULL,
		[DateTimeTo] [datetimeoffset](7) NULL,
		[RepoName] [varchar](50) NULL,
		[RepoNotes] [varchar](50) NULL,
		[PoolName] [varchar](250) NULL,
		[CredentialName] [varchar](150) NULL,
		[Enabled] [bit] NULL,
	CONSTRAINT [PK_ImportConfig] PRIMARY KEY CLUSTERED 
	(
		[ID] ASC
	))
	
	IF OBJECT_ID('ImportTables') IS NULL 
	CREATE TABLE [dbo].[ImportTables](
		[ID] [int] IDENTITY(1,1) NOT NULL,
		[TableName] [varchar](250) NULL,
		[Enabled] [bit] NULL,
		[SequenceOrder] [int] NULL,
		[RunUpdate] [bit] NULL,
		[WhereFilter] [varchar](250) NULL,
		[DateFilterColumn] [varchar](250) NULL,
		[PrimaryKeyColumn] [varchar](250) NULL,
		[NoteStorage] [bit] NULL,
	 CONSTRAINT [PK_ImportTables] PRIMARY KEY CLUSTERED 
	(
		[ID] ASC
	)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
	)
	 	 
	IF NOT EXISTS(SELECT * FROM ImportConfig) 
	BEGIN 
		PRINT 'SETTING INITIAL CONFIG...'
		SET IDENTITY_INSERT [dbo].[ImportConfig] ON 	
		INSERT [dbo].[ImportConfig] ([ID], [DateTimeFrom], [DateTimeTo], [RepoName], [RepoNotes], [PoolName], [CredentialName], [Enabled]) VALUES (1, NULL, NULL, @RepoName, @RepoLobs, @PoolName, @CredName, 1)
		SET	IDENTITY_INSERT [dbo].[ImportConfig] OFF
	END
	
	IF NOT EXISTS(SELECT * FROM ImportTables) 
	BEGIN
	PRINT 'FILLING IMPORT ENTRIES...' 
	SET IDENTITY_INSERT [dbo].[ImportTables] ON 
	
	INSERT [dbo].[ImportTables] ([ID], [TableName], [Enabled], [SequenceOrder], [RunUpdate], [WhereFilter], [DateFilterColumn], [PrimaryKeyColumn], [NoteStorage]) VALUES (1, N'AuditEvents', 0, NULL, NULL, NULL, NULL, NULL, NULL)
	
	SET IDENTITY_INSERT [dbo].[ImportTables] OFF
	END 

	SET @query = 'CREATE OR ALTER PROCEDURE [dbo].[sp_log]
	(
	    @tableName VARCHAR(150), @sourceName VARCHAR(150), @DatabaseKey VARCHAR(50), 
		@loopId INT, @t1 DATETIME, @g1 DATETIME, @affected INT = 0, @message VARCHAR(1000) = NULL, @BatchID VARCHAR(50) = NULL  
	)
	AS
	BEGIN

	IF OBJECT_ID(''ImportLogs'') IS NULL 
	BEGIN 

	CREATE TABLE [dbo].[ImportLogs](
	[ID] [int] IDENTITY(1,1) NOT NULL,
	[TableName] [varchar](150) NULL,	
	[SourceName] [varchar](50) NULL,
	[DatabaseKey] [varchar](50) NULL,	
	[Message] [varchar](1000) NULL,
	[LoopID] [int] NULL,
	[LoopInSeconds] [int] NULL,
	[LoopInMinutes] [int] NULL,
	[RunMinutes] [int] NULL,
	[AvgCPU] [decimal](18, 1) NULL,
	[MaxCPU] [decimal](18, 1) NULL,
	[AvgIO] [decimal](18, 1) NULL,
	[MaxIO] [decimal](18, 1) NULL,
	[AvgLog] [decimal](18, 1) NULL,
	[MaxLog] [decimal](18, 1) NULL,
	[AvgMem] [decimal](18, 1) NULL,
	[MaxMem] [decimal](18, 1) NULL,
	[AvgDTU] [decimal](18, 1) NULL,
	[MaxDTU] [decimal](18, 1) NULL,
	[DateTimeCreated] [datetime] NULL,
	[DateTimeStart] [datetime] NULL,
	[PartScheme] [int] NULL,
	[CompressScheme] [varchar](150) NULL,
	[AfterCount] [int] NULL,
	[AffectedCount] [int] NULL,
	[BatchID] [varchar](50) NULL,
	CONSTRAINT [PK_ImportLogs] PRIMARY KEY CLUSTERED ([ID] ASC)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF) ON [PRIMARY]) ON [PRIMARY]

	ALTER TABLE [dbo].[ImportLogs] ADD  CONSTRAINT [DF_Logs_DateTimeCreated]  DEFAULT (getdate()) FOR [DateTimeCreated]

	END
 
    SET NOCOUNT ON

		DECLARE @AvgCPU	decimal(18, 1);
		DECLARE @MaxCPU	decimal(18, 1);
		DECLARE @AvgIO	decimal(18, 1);
		DECLARE @MaxIO	decimal(18, 1);
		DECLARE @AvgLog	decimal(18, 1);
		DECLARE @MaxLog	decimal(18, 1);
		DECLARE @AvgMem	decimal(18, 1);
		DECLARE @MaxMem	decimal(18, 1);
		DECLARE @AvgDTU	decimal(18, 1);
		DECLARE @MaxDTU	decimal(18, 1);

		DECLARE @Compression VARCHAR(100); 
		DECLARE @AfterCount INT; 
 
		DECLARE @Partitions INT; 
		 
		SELECT @Partitions = COUNT(a.partition_number), @AfterCount = SUM(a.rows), @Compression = MAX(a.data_compression_desc) FROM sys.partitions a WITH (NOLOCK) 
		INNER JOIN sys.tables b ON a.object_id = b.object_id 
		WHERE b.name = @tableName

		SELECT @AvgCPU = AVG(avg_cpu_percent), @MaxCPU = MAX(avg_cpu_percent), @AvgIO = AVG(avg_data_io_percent), @MaxIO = MAX(avg_data_io_percent), 
			@AvgLog = AVG(avg_log_write_percent), @MaxLog = MAX(avg_log_write_percent), @AvgMem = AVG(avg_memory_usage_percent), @MaxMem = MAX(avg_memory_usage_percent) 
		FROM sys.dm_db_resource_stats WHERE end_time >= @g1;

 
		SELECT 
				@AvgDTU = AVG(t.[avg_DTU_percent]), 
				@MaxDTU = MAX(t.[max_DTU_percent]) 
				FROM 		
					(SELECT end_time, 
							(SELECT Avg(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) AS value(v)) AS [avg_DTU_percent], 
							(SELECT Max(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) AS value(v)) AS [max_DTU_percent] 
					FROM sys.dm_db_resource_stats WHERE end_time >= @g1) as t 
		
    -- Insert statements for procedure here
    INSERT INTO ImportLogs(TableName, SourceName, DatabaseKey, [Message], LoopID, LoopInSeconds, LoopInMinutes, RunMinutes, AvgCPU,
		MaxCPU,
		AvgIO,
		MaxIO,
		AvgLog,
		MaxLog,
		AvgMem,
		MaxMem,
		AvgDTU,
		MaxDTU,
		DateTimeStart, 
		PartScheme, 
		CompressScheme, 
		AfterCount, 
		AffectedCount,
		BatchID)
	VALUES(@tableName, @sourceName, @DatabaseKey, @message, @loopId, DATEDIFF(second, @t1, GETDATE()), DATEDIFF(MINUTE, @t1, GETDATE()), DATEDIFF(MINUTE, @g1, GETDATE()), 
		@AvgCPU,
		@MaxCPU,
		@AvgIO,
		@MaxIO,
		@AvgLog,
		@MaxLog,
		@AvgMem,
		@MaxMem,
		@AvgDTU,
		@MaxDTU,
		@t1, 
		@Partitions, 
		@Compression, 
		@AfterCount,
		@affected, 
		@BatchID);

		END'; 
 
	IF OBJECT_ID('sp_log') IS NULL
	BEGIN 
		PRINT 'ADDING sp_log...'; 	
		EXEC sp_executesql @query;		
	END 
	 
	EXEC sp_execute_remote N'RepoDS', @query; 
	EXEC sp_execute_remote N'RepoNotesDS', @query; 


	--SP IMPORT
	 


	--FIX REOWKR
	PRINT 'CONFIGURING PARTITION STORAGE...'
	IF @IsAzure = 0
	BEGIN 	
		EXEC('USE ' + @RepoLobs);
		IF NOT EXISTS(SELECT * from sys.partition_functions WHERE name = 'PF_NotesByDate')
			CREATE PARTITION FUNCTION [PF_NotesByDate](datetime) AS RANGE LEFT FOR VALUES (N'2014-01-01T00:00:00.000', N'2016-01-01T00:00:00.000', N'2018-01-01T00:00:00.000', N'2020-01-01T00:00:00.000', N'2022-01-01T00:00:00.000')

		IF NOT EXISTS(SELECT * from sys.partition_schemes WHERE name = 'PS_NotesByDate')
			CREATE PARTITION SCHEME [PS_NotesByDate] AS PARTITION [PF_NotesByDate] TO ([PRIMARY], [PRIMARY], [PRIMARY], [PRIMARY], [PRIMARY], [PRIMARY])	
	END 
	ELSE 
	BEGIN 		
		EXEC sp_execute_remote N'RepoNotesDS', N'IF NOT EXISTS(SELECT * from sys.partition_functions WHERE name = ''PF_NotesByDate'') CREATE PARTITION FUNCTION [PF_NotesByDate](datetime) AS RANGE LEFT FOR VALUES (N''2014-01-01T00:00:00.000'', N''2016-01-01T00:00:00.000'', N''2018-01-01T00:00:00.000'', N''2020-01-01T00:00:00.000'', N''2022-01-01T00:00:00.000'')';
		EXEC sp_execute_remote N'RepoNotesDS', N'IF NOT EXISTS(SELECT * from sys.partition_schemes WHERE name = ''PS_NotesByDate'') CREATE PARTITION SCHEME [PS_NotesByDate] AS PARTITION [PF_NotesByDate] TO ([PRIMARY], [PRIMARY], [PRIMARY], [PRIMARY], [PRIMARY], [PRIMARY])';
	END 
	SET @IsInstalled = 1; 
END 

AbortEnd:

IF @IsInstalled = 1 
	PRINT 'INSTALLATION COMPLETED. DB REPO IS READY TO USE'

PRINT 'END OF SCRIPT';

GO 

--**************************************************** SPROC INSTALLATION *********************************************** 
--* SELECT TEXT FROM HERE TO END OF FILE. FOLLOW LABEL FOR END OF SELECT. TIP: USE SHIFT WITH SCROLLBAR
/*
--*START 

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 11/29/2018
-- Description: Generates Create Table Statement 
-- =============================================
-- BASED ON hansmichiels.com CLONE TABLE SCRIPT

CREATE 
--OR ALTER 
PROCEDURE sp_get_create
(   
    @createText VARCHAR(300),  
    @tableName VARCHAR(100), 
	@pkColumn VARCHAR(100), 
	@dateColumn VARCHAR(100), 
	@oid INT, 
	@tables s_tables READONLY, 
	@schemas s_schemas READONLY, 
	@cols s_cols READONLY, 
	@types s_types READONLY, 
	@cmps s_cmps READONLY, 
	@query_out NVARCHAR(MAX) OUTPUT 
)
AS
BEGIN
    -- SET NOCOUNT ON added to prevent extra result sets from
    -- interfering with SELECT statements.
    SET NOCOUNT ON;
	DECLARE @CrLf NVARCHAR(2) = CHAR(13) + CHAR(10);
	DECLARE @Indent NVARCHAR(2) = SPACE(2);	
	-- For 'min' script use this (in case sql is near 4000 characters):
	-- , @CrLf  = ' '
	-- , @Indent = ''	 
  
    SET @query_out = '';

	SELECT @query_out = ISNULL(@query_out, '') + CASE col_sequence WHEN 1 THEN       
	@CrLf + @createText + ' ' + @tableName + @CrLf + @Indent + '( ' ELSE @CrLf + @Indent + ', ' END
	    + [definition]
	FROM (SELECT ROW_NUMBER() OVER (PARTITION BY tb.object_id ORDER BY tb.object_id, col.column_id) AS col_sequence
		, QUOTENAME(col.name) + ' ' + COALESCE('AS ' + cmp.definition + CASE ISNULL(cmp.is_persisted, 0) WHEN 1 THEN ' PERSISTED ' ELSE '' END,
        CASE WHEN col.system_type_id != col.user_type_id THEN QUOTENAME(usr_tp.schema_name) + '.' + QUOTENAME(usr_tp.name)
			ELSE QUOTENAME(sys_tp.name) +
                CASE
                  WHEN sys_tp.name IN ('char', 'varchar', 'binary', 'varbinary') THEN '(' + CONVERT(VARCHAR, CASE col.max_length WHEN -1 THEN 'max' ELSE CAST(col.max_length AS varchar(10)) END) + ')'
                  WHEN sys_tp.name IN ('nchar', 'nvarchar') THEN '(' + CONVERT(VARCHAR, CASE col.max_length WHEN -1 THEN 'max' ELSE CAST(col.max_length/2 AS varchar(10)) END) + ')'
                  WHEN sys_tp.name IN ('decimal', 'numeric') THEN '(' + CAST(col.precision AS VARCHAR) + ',' + CAST(col.scale AS VARCHAR) +  ')'
                  WHEN sys_tp.name IN ('datetime2') THEN '(' + CAST(col.scale AS VARCHAR) +  ')'
                  ELSE ''
                END          
            END
            )       
			+ CASE WHEN col.is_nullable = 0 AND (col.name = @pkColumn OR col.name = @dateColumn) THEN ' NOT' ELSE '' END + ' NULL' AS [definition]
			FROM @tables tb 
			JOIN @schemas sch ON sch.schema_id = tb.schema_id
			JOIN @cols col ON col.object_id = tb.object_id
			JOIN @types sys_tp ON col.system_type_id = sys_tp.system_type_id AND col.system_type_id = sys_tp.user_type_id 
			LEFT JOIN
            (SELECT tp.*, sch.name AS [schema_name] 
				FROM @types tp JOIN @schemas sch ON tp.schema_id = sch.schema_id) usr_tp 
				ON col.system_type_id = usr_tp.system_type_id
			AND col.user_type_id = usr_tp.user_type_id 
			LEFT JOIN @cmps cmp ON cmp.object_id = tb.object_id AND cmp.column_id = col.column_id 
			WHERE tb.object_id = @oid AND col.is_computed=0) subqry;

	--SELECT @query_out;     
END
GO

/****** Object:  StoredProcedure [dbo].[sp_import_database]  ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author: Ruy
-- Create Date: 1/31/2019
-- Description: Import Database from same Elastic Pool
-- =============================================
--EXEC [sp_import_database] 'DBNAME' 
-- sp_mon  sp_report  sp_reset 1 
--SELECT * FROM ImportLogs; SELECT TableName FROM ImportTables WHERE Enabled = 1 

CREATE 
OR ALTER 
PROCEDURE [dbo].[sp_import_database]
	@sourceName VARCHAR(100), 
	@dateFrom DATETIME = NULL, 
	@dateTo DATETIME = NULL 
AS
BEGIN
	SET NOCOUNT ON;
	
	--DEBUG FLAGS
	DECLARE @NoDrop BIT = 0; 
	DECLARE @NoLog BIT = 0;
	
	PRINT CONCAT('START OF SCRIPT // ', GETDATE());

	IF OBJECT_ID('ImportConfig') IS NULL
	BEGIN 
		PRINT 'REPO MASTER CONFIG NOT FOUND - ARE WE IN CORRECT DB? ABORTING...'
		GOTO AbortEnd 
	END 

	DECLARE @globalFrom DATETIME;
	DECLARE @globalTo DATETIME;
	
	--GET ENV
	DECLARE @ServerName NVARCHAR(100) = CAST(SERVERPROPERTY('SERVERNAME') AS NVARCHAR) 
	DECLARE @AzureUrl NVARCHAR(100) = @ServerName + N'.database.windows.net';
	DECLARE @IsAzure BIT = IIF(SERVERPROPERTY('EngineEdition') = 5, 1, 0);
	DECLARE @PoolName NVARCHAR(100) = 'DBPool';
	DECLARE @RepoMaster NVARCHAR(100) = DB_NAME();
	DECLARE @RepoName NVARCHAR(100) = 'Repo';
	DECLARE @RepoNotes NVARCHAR(100) = 'RepoNotes';
	DECLARE @CredName NVARCHAR(100) = 'PoolCred';
	DECLARE @Enabled BIT = 1; 
	  
	SELECT TOP 1 
		@RepoName = RepoName, 
		@RepoNotes = RepoNotes, 
		@PoolName = PoolName, 
		@CredName = CredentialName, 
		@Enabled = [Enabled], 
		@globalFrom = DateTimeFrom, 
		@globalTo = DateTimeTo
	FROM ImportConfig 


	IF @Enabled = 0 
	BEGIN 
		PRINT 'Repo Disabled via ImportConfig. ABORTING...';
		GOTO AbortEnd 
	END 

	IF @dateFrom IS NOT NULL 
	BEGIN 
		PRINT 'COMMAND LINE DATE OVERRIDE: ' + @dateFrom; 
		SET @globalFrom = @dateFrom; 
		SET @globalTo = @dateTo; 
	END 
		
	PRINT CONCAT('IMPORT RUN CONTEXT: ', DB_NAME(), ' Azure: ', @IsAzure); 
	PRINT CONCAT('SOURCE: ', @sourceName); 
	PRINT CONCAT('TARGET REPOS - Main: ', @RepoName, ' | Notes: ', @RepoNotes); 	
	PRINT CONCAT('CRED: ', @CredName, ' POOL: ', @PoolName); 
	PRINT CONCAT('GLOBAL DATE FILTER: ', @globalFrom, ' => ', @globalTo);
			
	DECLARE @message NVARCHAR(100) = 'V1R8';
	DECLARE @g1 DATETIME = GETDATE();
	DECLARE @t1 DATETIME = GETDATE();
	DECLARE @LoopId DECIMAL(18,2) = 1;
	DECLARE @query NVARCHAR(MAX) 
	DECLARE @hash TABLE (Result VARCHAR(MAX))	
	DECLARE @columnNames NVARCHAR(MAX); 
	DECLARE @excludeNames NVARCHAR(MAX); 
	DECLARE @pk NVARCHAR(250); 
	DECLARE @id UNIQUEIDENTIFIER; 
	DECLARE @pkColumn NVARCHAR(250); 
	DECLARE @upd DATETIME; 
	DECLARE @tableName VARCHAR(500)
	DECLARE @update BIT = 1; 
	DECLARE @whereFilter VARCHAR(500); 
	DECLARE @whereText VARCHAR(2000) = ''; 
	DECLARE @whereAppend VARCHAR(2000) = ''; 
	DECLARE @dateColumn NVARCHAR(500); 
	DECLARE @dateFilter VARCHAR(500); 
	DECLARE @noteStorage BIT = 0;
	DECLARE @DatabaseKey VARCHAR(200); 

	--**** AUTO-SCRIPT OPTIONS
	DECLARE @CrLf NVARCHAR(2) = CHAR(13) + CHAR(10);
	DECLARE @Indent NVARCHAR(2) = SPACE(2);	

	--**** CACHE  
	DECLARE @objs AS s_objs 
	DECLARE @cols AS s_cols
	DECLARE @tables AS s_tables
	DECLARE @schemas AS s_schemas
	DECLARE @cmps AS s_cmps
	DECLARE @types AS s_types	
	DECLARE @indexes AS s_indexes
	DECLARE @keys AS s_keys 
	DECLARE @fkeys AS s_fkeys 	

	DECLARE @suffix NVARCHAR(100) = CONCAT('', ABS(Checksum(NewID()))); 
	PRINT @suffix;
	DECLARE @dsName NVARCHAR(500) = CONCAT('DS', @suffix); 
	PRINT CONCAT('Temp DS: ',@dsName);
	
	PRINT CONCAT('Loop:', @LoopId, ' Time:', DATEDIFF(second, @t1, GETDATE()), 's or ', DATEDIFF(minute, @t1, GETDATE()), 'mins ', DATEDIFF(minute, @g1, GETDATE()), 'mins');
 
	--**** EXISTS PRE-CHECK 
	IF @IsAzure = 1 
	BEGIN 
		IF NOT EXISTS(SELECT 1 FROM sys.external_data_sources WHERE name = 'MasterDS')
		BEGIN
			PRINT 'Creating Datasource MasterDB...';
			SET @query = N'CREATE EXTERNAL DATA SOURCE [MasterDS] WITH (TYPE = RDBMS, LOCATION = N'''+ @AzureUrl +''', CREDENTIAL = ['+ @CredName +'], DATABASE_NAME = N''master'')';
			PRINT @query; 
			EXEC sp_executesql @query 
			PRINT 'Created'
		END

		IF OBJECT_ID('master_dbs') IS NULL	
		BEGIN
			EXEC('CREATE EXTERNAL TABLE master_dbs (name SYSNAME, database_id INT, state TINYINT) WITH (DATA_SOURCE = [MasterDS], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''databases'')'); 
		END 

		IF NOT EXISTS(SELECT name FROM master_dbs WHERE name = @sourceName) 
		BEGIN 
			PRINT 'SOURCE DATABASE NOT FOUND/MOUNTED IN SERVER: ' + @serverName; 	
			PRINT 'TYPO? FAILED UPLOAD? ABORTING...'	
			GOTO AbortEnd; 
		END 
	END 
	ELSE 
	BEGIN 
		IF NOT EXISTS(SELECT name FROM sys.databases WHERE name = @sourceName) 
		BEGIN 
			PRINT 'SOURCE DATABASE NOT FOUND/MOUNTED IN SERVER: ' + @serverName; 
			PRINT 'TYPO? FAILED UPLOAD? ABORTING...'
			GOTO AbortEnd; 
		END 
	END 
	
	--**** DATASOURCE 				
	IF @IsAzure = 1  
	BEGIN 

		--database_name = @sourceName OR //to avoid recreating, then take previous suffix REPLACE(name, 'DS','')	
		--CREATE DATASOURCE FOR SOURCE 
		IF NOT EXISTS(SELECT 1 FROM sys.external_data_sources WHERE name = @dsName)
		BEGIN
			PRINT 'Creating Datasource ' + @dsName + '...';
			SET @query = N'CREATE EXTERNAL DATA SOURCE [' + @dsName + '] WITH (TYPE = RDBMS, LOCATION = N'''+ @AzureUrl +''', CREDENTIAL = ['+ @CredName +'], DATABASE_NAME = N'''+ @sourceName +''')';
			PRINT @query; 
			EXEC sp_executesql @query 
			PRINT 'Created'
		END
 
		--CREATE DATASOURCE IN REPOs 
		EXEC sp_execute_remote N'RepoDS', @query; 	
		EXEC sp_execute_remote N'RepoNotesDS', @query;
		
		IF OBJECT_ID('repo_objs') IS NULL 
		BEGIN 
			PRINT 'Creating repo.objects...'
			EXEC('CREATE EXTERNAL TABLE [repo_objs] (name sysname, object_id int,principal_id int,schema_id int,parent_object_id int, type char(2)) WITH (DATA_SOURCE = [RepoDS], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''objects'');');
		END

		IF OBJECT_ID('note_objs') IS NULL 
		BEGIN 
			PRINT 'Creating note.objects...'
			EXEC('CREATE EXTERNAL TABLE [note_objs] (name sysname, object_id int,principal_id int,schema_id int,parent_object_id int, type char(2)) WITH (DATA_SOURCE = [RepoNotesDS], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''objects'');');
		END

		PRINT 'LINKING DATABASES ...'
		--CACHED SOURCES 
		IF OBJECT_ID(CONCAT('objs', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.objects...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('objs', @suffix) + '] ' +  
			'(name sysname, object_id int,principal_id int,schema_id int,parent_object_id int, type char(2)) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''objects'')';
			PRINT @query
			EXEC sp_executesql @query 
		END

		IF OBJECT_ID(CONCAT('cols', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.columns...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('cols', @suffix) + '] ' +  
			'(object_id	int, name sysname, column_id int, system_type_id tinyint, user_type_id	int, max_length	smallint, precision	tinyint, scale tinyint, is_nullable	bit, is_rowguidcol	bit, is_identity bit, is_computed bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''columns'')';
			PRINT @query
			EXEC sp_executesql @query 
		END
		
		IF OBJECT_ID(CONCAT('tb', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.tables...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('tb', @suffix) + '] ' +  
			'(name	sysname, object_id	int, principal_id	int, schema_id	int, parent_object_id int, is_filetable bit, is_memory_optimized	bit, is_external	bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''tables'')';
			PRINT @query
			EXEC sp_executesql @query 
		END
		

		IF OBJECT_ID(CONCAT('sch', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.schemas...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('sch', @suffix) + '] ' +  
			'(name sysname, schema_id int, principal_id int) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''schemas'')';
			PRINT @query
			EXEC sp_executesql @query 
		END
		
		IF OBJECT_ID(CONCAT('cmp', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.computed...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('cmp', @suffix) + '] ' +  
			'(object_id	int, name sysname, column_id int, system_type_id tinyint, user_type_id	int, max_length	smallint, precision	tinyint, scale tinyint, is_nullable	bit, is_rowguidcol	bit, is_identity bit, is_computed bit, definition nvarchar(max) null, is_persisted bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''computed_columns'')';
			PRINT @query
			EXEC sp_executesql @query 
		END
 
		IF OBJECT_ID(CONCAT('tp', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.types...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('tp', @suffix) + '] ' +  
			'(name sysname,system_type_id tinyint,user_type_id int,schema_id int,principal_id int,max_length smallint,precision tinyint,scale	tinyint,is_nullable bit,is_user_defined	bit,is_assembly_type bit,default_object_id int,rule_object_id	int,is_table_type	bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''types'')';
			PRINT @query
			EXEC sp_executesql @query 
		END	

		IF OBJECT_ID(CONCAT('ix', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.indexes...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('ix', @suffix) + '] ' +  
			'(name SYSNAME NULL, object_id INT, index_id INT, type TINYINT, is_unique BIT, is_primary_key BIT) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''indexes'')';
			PRINT @query
			EXEC sp_executesql @query 
		END	
 
		IF OBJECT_ID(CONCAT('key', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.key_constraints...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('key', @suffix) + '] ' +  
			'(name sysname, object_id int, principal_id int, schema_id	int, parent_object_id int, type	char(2), create_date datetime, modify_date datetime, unique_index_id int, is_system_named bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''key_constraints'')';
			PRINT @query
			EXEC sp_executesql @query 
		END	

		IF OBJECT_ID(CONCAT('fk', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.foreign_keys...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('fk', @suffix) + '] ' +  
			'(name sysname, object_id int, principal_id int, schema_id	int, parent_object_id int, type	char(2), create_date datetime, modify_date datetime, referenced_object_id int, is_system_named bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''foreign_keys'')';
			PRINT @query
			EXEC sp_executesql @query 
		END	
	 
		--CACHE FILL 

		SET @query = N'SELECT * FROM objs' + @suffix; 
		INSERT INTO @objs 
			EXEC sp_executesql @query;
		PRINT CONCAT('Objects: ', @@rowcount); 

		SET @query = N'SELECT * FROM cols' + @suffix; 
		INSERT INTO @cols 
			EXEC sp_executesql @query;
		PRINT CONCAT('Cols: ', @@rowcount); 

		SET @query = N'SELECT * FROM tb' + @suffix; 
		INSERT INTO @tables 
			EXEC sp_executesql @query;	
		PRINT CONCAT('Tables: ', @@rowcount); 

		SET @query = N'SELECT * FROM sch' + @suffix; 
		INSERT INTO @schemas  
			EXEC sp_executesql @query;
		PRINT CONCAT('Schemas: ', @@rowcount); 

		SET @query = N'SELECT * FROM cmp' + @suffix; 
		INSERT INTO @cmps  
			EXEC sp_executesql @query;
		PRINT CONCAT('Cmps: ', @@rowcount); 
	
		SET @query = N'SELECT * FROM tp' + @suffix; 
		INSERT INTO @types 
			EXEC sp_executesql @query;
		PRINT CONCAT('Types: ', @@rowcount); 

		SET @query = N'SELECT * FROM ix' + @suffix + ' WHERE name IS NOT NULL '; 
		INSERT INTO @indexes  
			EXEC sp_executesql @query;
		PRINT CONCAT('Indexes: ', @@rowcount); 

		SET @query = N'SELECT * FROM key' + @suffix; 
		INSERT INTO @keys 
			EXEC sp_executesql @query;
		PRINT CONCAT('Keys: ', @@rowcount); 

		SET @query = N'SELECT * FROM fk' + @suffix; 
		INSERT INTO @fkeys  
			EXEC sp_executesql @query;
		PRINT CONCAT('Foreign: ', @@rowcount); 

		--GET DatabaseKey 	
		PRINT 'GETTING DatabaseKey...'	
		IF EXISTS(SELECT object_id FROM @tables WHERE name = 'DatabaseImportInfo')
		BEGIN 
			IF OBJECT_ID(CONCAT('dbo.DatabaseImportInfo', @suffix)) IS NULL 
			BEGIN 
				PRINT 'Creating Database Information...'
				SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('DatabaseImportInfo', @suffix) + '] ' +  
				'(DatabaseKey VARCHAR(50) NULL) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''dbo'', OBJECT_NAME = ''DatabaseImportInfo'')';
				PRINT @query
				EXEC sp_executesql @query 
			END
			 	 		
			SET @query = N'SELECT @DatabaseKey = [DatabaseKey] FROM ' + CONCAT('DatabaseImportInfo', @suffix) + ' '; 
			EXEC sp_executesql @query, N'@DatabaseKey VARCHAR(50) OUTPUT', @DatabaseKey OUTPUT ;
		END 
		ELSE 
		BEGIN 
			PRINT 'Database Information Not Found '
			--Abort?
		END 
	END 
	ELSE 
	BEGIN
		PRINT 'READING SYSTEM TABLES...'
		
		SET @query = N'SELECT name, object_id, principal_id, schema_id, parent_object_id, type FROM ' + CONCAT(@sourceName, '.sys.objects'); 
		INSERT INTO @objs 
			EXEC sp_executesql @query;
		PRINT CONCAT('Objects: ', @@rowcount); 

		SET @query = N'SELECT object_id, name, column_id, system_type_id, user_type_id, max_length, precision, scale, is_nullable, is_rowguidcol, is_identity, is_computed FROM ' + CONCAT(@sourceName, '.sys.columns'); 
		INSERT INTO @cols 
			EXEC sp_executesql @query;
		PRINT CONCAT('Cols: ', @@rowcount); 

		SET @query = N'SELECT name, object_id, principal_id, schema_id, parent_object_id, is_filetable, is_memory_optimized, is_external FROM ' + CONCAT(@sourceName, '.sys.tables'); 
		INSERT INTO @tables 
			EXEC sp_executesql @query;	
		PRINT CONCAT('Tables: ', @@rowcount); 

		SET @query = N'SELECT name, schema_id, principal_id FROM ' + CONCAT(@sourceName, '.sys.schemas'); 
		INSERT INTO @schemas  
			EXEC sp_executesql @query;
		PRINT CONCAT('Schemas: ', @@rowcount); 

		SET @query = N'SELECT object_id, name, column_id, system_type_id, user_type_id, max_length, precision, scale, is_nullable, is_rowguidcol, is_identity, is_computed, definition, is_persisted FROM ' + CONCAT(@sourceName, '.sys.computed_columns'); 
		INSERT INTO @cmps  
			EXEC sp_executesql @query;
		PRINT CONCAT('Cmps: ', @@rowcount); 
	
		SET @query = N'SELECT name, system_type_id, user_type_id, schema_id, principal_id, max_length, precision, scale, is_nullable, is_user_defined, is_assembly_type, default_object_id, rule_object_id, is_table_type FROM ' + CONCAT(@sourceName, '.sys.types'); 
		INSERT INTO @types 
			EXEC sp_executesql @query;
		PRINT CONCAT('Types: ', @@rowcount); 
		 
		SET @query = N'SELECT name, object_id, index_id, type, is_unique, is_primary_key FROM ' + CONCAT(@sourceName, '.sys.indexes') + ' WHERE name IS NOT NULL '; 
		INSERT INTO @indexes 
			EXEC sp_executesql @query;
		PRINT CONCAT('Indexes: ', @@rowcount); 

		SET @query = N'SELECT name, object_id, principal_id, schema_id, parent_object_id, type, create_date, modify_date, unique_index_id, is_system_named FROM ' + CONCAT(@sourceName, '.sys.key_constraints'); 
		INSERT INTO @keys 
			EXEC sp_executesql @query;
		PRINT CONCAT('Keys: ', @@rowcount); 

		SET @query = N'SELECT name, object_id, principal_id, schema_id, parent_object_id, type, create_date, modify_date, referenced_object_id, is_system_named FROM ' + CONCAT(@sourceName, '.sys.foreign_keys'); 
		INSERT INTO @fkeys  
			EXEC sp_executesql @query;
		PRINT CONCAT('Foreign: ', @@rowcount); 

		IF EXISTS(SELECT object_id FROM @tables WHERE name = 'DatabaseImportInfo')
		BEGIN 
			SET @query = N'SELECT @DatabaseKey = [DatabaseKey] FROM ' + CONCAT(@sourceName,'.dbo.DatabaseImportInfo') + ' '; 
			EXEC sp_executesql @query, N'@DatabaseKey VARCHAR(50) OUTPUT', @DatabaseKey OUTPUT 
		END 
		ELSE 
		BEGIN 
			PRINT 'Database Information Not Found '
			--Abort?
		END 

	END 

	PRINT CONCAT('DatabaseKey: ', @DatabaseKey);
	--Initialize Local ImportLogs 
	EXEC sp_log NULL, @sourceName, @DatabaseKey, NULL, @t1, @g1, NULL, N'START', @suffix; 

	--OPTIMIZE SOURCE DATABASE FOR REMOTE QUERY 
	IF @IsAzure = 1 
	BEGIN 	
		PRINT 'EXEC sp_prep DISABLED - UNCOMMENT TO ENABLE *IT DELETES INDEXES ON SOURCE...'
		--EXEC sp_prep @dsName, @objs, @cols, @indexes, @keys, @fkeys, @tables 
	END 

	--GOTO AbortEnd; 
	--*****************************************************************************************************************************************************************************************
	--**** IMPORT CONFIGURED TABLES 

	DECLARE tbl_cursor CURSOR FOR  
	SELECT TableName, WhereFilter, DateFilterColumn, PrimaryKeyColumn, RunUpdate, NoteStorage FROM ImportTables WHERE Enabled = 1 ORDER BY SequenceOrder, TableName 
	
	OPEN tbl_cursor   
	FETCH NEXT FROM tbl_cursor INTO @tableName, @whereFilter, @dateColumn, @pkColumn, @update, @noteStorage  
	
	WHILE @@FETCH_STATUS = 0   
	BEGIN
		
		DECLARE @nsql NVARCHAR(MAX)	
		DECLARE @oid INT; 
		DECLARE @inserted INT = 0;
		DECLARE @updated INT = 0;

		DECLARE @TableOptions NVARCHAR(500) = ' WITH (SCHEMA_NAME = ''dbo'', OBJECT_NAME = '''+ @tableName +''', DATA_SOURCE = ['+ @dsName +'])'
		
		DECLARE @SQN VARCHAR(MAX) = @sourceName + '.dbo.' + @tableName; 
		DECLARE @DQN VARCHAR(MAX) = @RepoName + '.dbo.' + @tableName; 

		IF @noteStorage = 1 
			SET @DQN = @RepoNotes + '.dbo.' + @tableName;
		ELSE
			SET @noteStorage = 0;
			 		
		PRINT @SQN + ' => ' + @DQN;

		PRINT CONCAT('STORAGE: ', @noteStorage ,' | ', IIF(@noteStorage = 0, 'MAIN', 'NOTES'));

		--************************************** 
		--SOURCE CHECK 
		SELECT @oid = [object_id] FROM @objs WHERE name = @tableName AND type = 'U';
		PRINT CONCAT('ObjectID: ', @oid); 				
		IF @oid IS NULL
		BEGIN 
			PRINT 'SOURCE TABLE NOT FOUND! SKIPPING...' 
			Goto Cont
		END 

		--PRIMARY KEY   
		--CHANGE TO GET FROM SYS.INDEXES
		IF @pkColumn IS NULL 
		BEGIN
			PRINT 'PrimaryKey not set, auto-discovering...'; 
			SELECT @pkColumn = [name] FROM @cols WHERE [object_id] = @oid AND [NAME] like 'PK_%'; 
			PRINT CONCAT('FOUND PK: ', @pkColumn);
		END		 

		IF @pkColumn IS NULL
		BEGIN 
			PRINT 'NO PK, SET IN IMPORTTABLES, SKIPPING FOR NOW...';
			Goto Cont
		END 

		--DATE COLUMN 
		IF @dateColumn IS NULL
		BEGIN 
			PRINT 'Date Column not set, auto-discovering...'; 
			IF EXISTS(SELECT name FROM @cols WHERE object_id = @oid AND name = 'DateTimeOcurrance')
			BEGIN 
				PRINT 'FOUND DateTimeOcurrance'
				SET @dateColumn = 'DateTimeOcurrance';
			END 

			IF EXISTS(SELECT name FROM @cols WHERE object_id = @oid AND name = 'DateTimeCreated') AND @dateColumn IS NULL 
			BEGIN
				PRINT 'FOUND DateTimeCreated'
				SET @dateColumn = 'DateTimeCreated';
			END 
		END 

		IF @dateColumn IS NULL
		BEGIN 
			PRINT @tableName + ' DATE COLUMN NOT SET AND COULD NOT BE DETECTED...';		 
		END
		
		--WHERE 
		IF @whereFilter IS NOT NULL OR @globalFrom IS NOT NULL 
		BEGIN 
			PRINT CONCAT('CONFIGURED WHERE FILTER: ',  @whereFilter);
			
			IF PATINDEX('%{date}%', @whereFilter) > 0
				BEGIN 
					IF @dateColumn IS NOT NULL 
					BEGIN 
						PRINT 'DATE FILTER';
						SET @whereFilter = REPLACE(@whereFilter, '{date}', @dateColumn);
					END 
					ELSE 
						PRINT CONCAT('WARNING: Table ', @tableName, ' has ok MARKUP but no date COLUMN specified...');
				END

			IF @globalFrom IS NOT NULL
			BEGIN 
				PRINT 'GLOBAL DATE FILTER FOR DATE COLUMNED TABLES'
				PRINT @globalFrom; 
				PRINT @globalTo; 

				IF @dateColumn IS NOT NULL 
				BEGIN 
					PRINT 'DATE FILTER';
					IF @globalTo IS NOT NULL 
						BEGIN 
							SET @dateFilter = CONCAT('x.',@dateColumn, ' BETWEEN ''', @globalFrom,''' AND ''', @globalTo, '''');
						END 
					ELSE
						BEGIN  
							SET @dateFilter = CONCAT('x.',@dateColumn, ' >= ''',@globalFrom,'''');
						END 
				END 
				ELSE 
					PRINT 'GLOBAL DATE FILTER ON BUT NO DATE COLUMN SET, SKIPPING...'
			END 
			
			IF LEN(@whereFilter)>1 OR LEN(@dateFilter) >1 
			BEGIN 
				SET @whereText = CONCAT(' WHERE ', @whereFilter, IIF(LEN(@whereFilter) > 1 AND LEN(@dateFilter) > 1, ' AND ', ' '), @dateFilter);
				SET @whereAppend = CONCAT(' AND ', @whereFilter, IIF(LEN(@whereFilter) > 1 AND LEN(@dateFilter) > 1, ' AND ', ' '), @dateFilter);
			END

		END 

		--TABLE LINK
		IF @IsAzure = 1
		BEGIN 
			-- GENERATE EXTERNAL TABLE SCRIPT 
			PRINT 'Creating External Table...';
			DECLARE @exName VARCHAR(500) = CONCAT(@tableName, @suffix);
			EXEC sp_get_create N'CREATE EXTERNAL TABLE', @exName, @pkColumn, @dateColumn, @oid, @tables, @schemas, @cols, @types, @cmps, @query_out = @nsql OUTPUT 
		 	
			SELECT @nsql = CONCAT(@nsql, @CrLf, @indent,') ', @TableOptions); 
			PRINT @nsql; 
			EXEC sp_executesql @nsql 
			PRINT 'CREATED'; 
	
			--CREATE EXTERNAL TABLE IN REPO 
			PRINT 'CREATING EXTERNAL IN REPO'
			IF @noteStorage = 1
				EXEC sp_execute_remote [RepoNotesDS], @nsql; 
			ELSE
				EXEC sp_execute_remote [RepoDS], @nsql; 
			PRINT 'CREATED'
		END 
 
  
		--*****************************
		--**** INSERT STATEMENT 		  		

		PRINT 'CHECKING DESTINATION...';
		DECLARE @destinationId INT; 
		
		DECLARE @indexsql NVARCHAR(MAX) = 'CREATE NONCLUSTERED INDEX IX_'+@tableName+'_DatabaseKey ON ['+ @tableName + '] (DatabaseKey);';
		DECLARE @pksql NVARCHAR(MAX) = ', CONSTRAINT [IXC_PK_' + @tableName + '] PRIMARY KEY CLUSTERED (['+@pkColumn+'] ASC)';

		IF @IsAzure = 1 
			BEGIN 
				
				IF @noteStorage = 1 
					SELECT @destinationId = object_id from note_objs WHERE name = @tableName AND type = 'U';
				ELSE 
					SELECT @destinationId = object_id from repo_objs WHERE name = @tableName AND type = 'U';

				IF @destinationId IS NULL  
				BEGIN
					PRINT 'DESTINATION NOT FOUND - CREATING...'
						
					EXEC sp_get_create N'CREATE TABLE', @tableName, @pkColumn, @dateColumn, @oid, @tables, @schemas, @cols, @types, @cmps, @query_out = @nsql OUTPUT;				 				
										 
					IF @noteStorage = 1
					BEGIN 
						SET @pksql = ', INDEX [' + @pkColumn + 's] CLUSTERED COLUMNSTORE, INDEX [IX_CS_' + @tableName + '] (['+@dateColumn+'] ASC, ['+@pkColumn+'] ASC) '; 
						PRINT 'EXECUTING IN NOTES...' 
						IF @dateColumn IS NULL 
							SET @nsql = CONCAT(@nsql, @CrLf, @indent,', DatabaseKey VARCHAR(50) NULL, RepoAdded DATETIME NULL ', @pksql,')', ';', @indexsql);
						ELSE 
							SET @nsql = CONCAT(@nsql, @CrLf, @indent,', DatabaseKey VARCHAR(50) NULL, RepoAdded DATETIME NULL ', @pksql,')', ' ON [PS_NotesByDate]([', @dateColumn,']);', @indexsql);
						PRINT @nsql;
						EXEC sp_execute_remote [RepoNotesDS], @nsql;
					END
					ELSE
					BEGIN
						PRINT 'EXECUTING IN MAIN...'				
						SET @nsql = CONCAT(@nsql, @CrLf, @indent,', DatabaseKey VARCHAR(50) NULL, RepoAdded DATETIME NULL ', @pksql,');', @indexsql);  
						PRINT @nsql;
						EXEC sp_execute_remote [RepoDS], @nsql; 
					END 
					PRINT 'CREATED'

					IF @noteStorage = 1 
						SELECT @destinationId = object_id from note_objs WHERE name = @tableName AND type = 'U';
					ELSE 
						SELECT @destinationId = object_id from repo_objs WHERE name = @tableName AND type = 'U';
			
				END 
			END 
		ELSE 
			BEGIN
				--**** FULLSQL

				IF @noteStorage = 1 
					SET @query = 'SELECT @destinationId = object_id FROM ' +  @RepoNotes + '.sys.objects WHERE name = '''+ @tableName +''' AND type = ''U'';';
				ELSE 				
					SET @query = 'SELECT @destinationId = object_id FROM ' +  @RepoName + '.sys.objects WHERE name = '''+ @tableName +''' AND type = ''U'';';
				
				PRINT @query;
				EXEC sp_executesql @query, N'@destinationId INT OUTPUT', @destinationId OUTPUT 

				IF @destinationId IS NULL  
				BEGIN
					PRINT 'DESTINATION NOT FOUND - CREATING...'					
					EXEC sp_get_create N'CREATE TABLE', @tableName, @pkColumn, @dateColumn, @oid, @tables, @schemas, @cols, @types, @cmps, @query_out = @nsql OUTPUT;
										 
					IF @noteStorage = 1
					BEGIN 
						--COLUMNSTORE AND VMAX IN FULLSQL UNSUPPORTED?
						SET @pksql = ', INDEX [IX_CS_' + @tableName + '] (['+@dateColumn+'] ASC, ['+@pkColumn+'] ASC) '; 
						PRINT 'EXECUTING IN NOTES...' 
						SET @nsql = CONCAT('USE ', @RepoNotes,';', @nsql, @CrLf, @indent,', DatabaseKey VARCHAR(50) NULL, RepoAdded DATETIME NULL ', @pksql,')', 
									' ON [PS_NotesByDate]([', @dateColumn,']);', @indexsql); 
					END
					ELSE
					BEGIN
						PRINT 'EXECUTING IN MAIN...'				
						SET @nsql = CONCAT('USE ', @RepoName,';', @nsql, @CrLf, @indent,', DatabaseKey VARCHAR(50) NULL, RepoAdded DATETIME NULL ', @pksql,');', @indexsql);  						
					END 

					PRINT @nsql;
					EXEC sp_executesql @nsql;
					PRINT 'CREATED'

					IF @noteStorage = 1 
						SET @query = 'SELECT @destinationId = object_id FROM ' +  @RepoNotes + '.sys.objects WHERE name = '''+ @tableName +''' AND type = ''U'';';
					ELSE 				
						SET @query = 'SELECT @destinationId = object_id FROM ' +  @RepoName + '.sys.objects WHERE name = '''+ @tableName +''' AND type = ''U'';';
				
					PRINT @query;
					EXEC sp_executesql @query, N'@destinationId INT OUTPUT', @destinationId OUTPUT 
			
				END 
			END 
 
		PRINT CONCAT('DestinationId: ', @destinationId);
 		--
		PRINT 'BUILD INSERT...'	

		IF @noteStorage = 1 AND @IsAzure = 1 
		BEGIN
						
			PRINT CONCAT('NOTE SHARD INSERT... //', GETDATE());
			SET @exName = CONCAT(@tableName, @suffix, '_Merge');
			EXEC sp_get_create N'CREATE TABLE', @exName, @pkColumn, @dateColumn, @oid, @tables, @schemas, @cols, @types, @cmps, @query_out = @nsql OUTPUT;
			SET @nsql = CONCAT(@nsql, @CrLf, @indent,') '); 
			PRINT @nsql;
			EXEC sp_execute_remote N'RepoNotesDS', @nsql, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1  

			--VMAX COUNT 
			DECLARE @VCNT INT = 0; 
			SELECT @VCNT = COUNT(1) FROM @cols WHERE object_id = @oid AND max_length = -1; 
			IF @VCNT IS NULL SET @VCNT = 0; 

			PRINT CONCAT('VMAX: ', @VCNT); 
  
			SELECT @columnNames = STUFF((SELECT '], [' + [NAME] FROM @cols WHERE object_id = @oid AND 
			(@VCNT <= 1 OR (@VCNT >= 2 AND max_length <> -1)) FOR xml path('')),1,1,'') + ']';
			SET @columnNames = SUBSTRING(@columnNames,2,LEN(@columnNames)-1) 

			PRINT CONCAT('COLS: ', @columnNames); 

			SET @query = ' INSERT INTO ' + CONCAT(@tableName, @suffix, '_Merge') + ' (' + @columnNames + ')
						SELECT ' + @columnNames + ' FROM ' + CONCAT(@tableName, @suffix, ' ', REPLACE(@whereText,'x.','')) + ';
						EXEC sp_log '''+ @tableName +'_Merge'', '''+ @sourceName +''', '''+ @DatabaseKey +''','+ CONCAT('',@LoopId) +', @p1, @p2, @@rowcount,''INSERT'', N'''+ @suffix +'''; 
						';			
			PRINT @query;
			EXEC sp_execute_remote N'RepoNotesDS', @query, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1  

			RAISERROR('...',0,1) WITH NOWAIT;	
		
			DECLARE @name VARCHAR(500), @cnt DECIMAL(18,2) = @LoopId; 

			IF @VCNT > 1
			BEGIN 

				PRINT 'MULTI VMAX COLUMN TABLE...';

				DECLARE curx CURSOR FOR	
				SELECT name FROM @cols WHERE object_id = @oid AND max_length = -1;

				OPEN curx 		
				FETCH NEXT FROM curx INTO @name 
				WHILE @@FETCH_STATUS = 0   
				BEGIN		
					SET @t1 = GETDATE();

					PRINT CONCAT(@name, ' COL SHARD INSERT... //', @t1);
					SET @cnt = @cnt + .01;				
					SET @query = '				
					SELECT ' + @pkColumn + ', '+ @name  +' INTO ' + CONCAT(@tableName, @suffix, '_', @name) + ' FROM ' + CONCAT(@tableName, @suffix) + ';
					UPDATE m SET '+ @name  +'= s.' + @name + ' FROM ' +  CONCAT(@tableName, @suffix, '_Merge') + ' m INNER JOIN ' + CONCAT(@tableName, @suffix, '_', @name) + ' s ON m.'+ @pkColumn  +'= s.' + @pkColumn + '; 
					DROP TABLE ' + CONCAT(@tableName, @suffix, '_', @name) + ';  
					EXEC sp_log '''+ @tableName + @name + ''', '''+ @sourceName +''', '''+ @DatabaseKey +''', '+ CAST(@cnt AS VARCHAR(5)) +', @p1, @p2, @@rowcount,''INSERT'', N'''+ @suffix +'''; 
					'
					PRINT @query;
					EXEC sp_execute_remote N'RepoNotesDS', @query, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1;
		 
		 			RAISERROR('....',0,1) WITH NOWAIT;	

					FETCH NEXT FROM curx INTO @name
				END

				CLOSE curx   
				DEALLOCATE curx 
			END

			SET @t1 = GETDATE();
			PRINT 'RUNNING FROM LOCAL MERGED SHARDS...';
			--Back to original but with local join of LocalMergedTable 

			SELECT @columnNames = STUFF((SELECT '], [' + [NAME] FROM @cols WHERE object_id = @oid AND is_computed = 0 FOR xml path('')),1,1,'') + ']';
			SET @columnNames = SUBSTRING(@columnNames,2,LEN(@columnNames)-1) 

			SET @query = '
			SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;	
			INSERT INTO '+ @tableName +' ('+ @columnNames +', DatabaseKey, RepoAdded)	
			SELECT sp.*, '''+ @DatabaseKey +''' as DatabaseKey, GETUTCDATE() as RepoAdded FROM '+ CONCAT(@tableName, @suffix, '_Merge') +' sp 
					LEFT JOIN (SELECT * FROM ' + @tableName + ' WHERE DatabaseKey = '''+ @DatabaseKey +''') dp  
					ON sp.'+@pkColumn+' = dp.'+@pkColumn+' 
			WHERE dp.'+ @pkColumn +' IS NULL ' + REPLACE(@whereAppend,'x.','sp.') + '; 
			EXEC sp_log '''+ @tableName +''', '''+ @sourceName +''', '''+ @DatabaseKey +''','+ CONCAT('',@LoopId) +', @p1, @p2, @@rowcount,''INSERT'', N'''+ @suffix +'''; 
			'
			PRINT @query; 

			--TEST ERRORS 
			BEGIN TRY  
				EXEC sp_execute_remote N'RepoNotesDS', @query, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1 
			END TRY  
			BEGIN CATCH  
				PRINT 'CATCH UPDATE ERROR:'
				IF @@TRANCOUNT > 0  	  
					DECLARE @ErrorMessage nvarchar(4000),  @ErrorSeverity int;
				SELECT @ErrorMessage = ERROR_MESSAGE(),@ErrorSeverity = ERROR_SEVERITY();  
				RAISERROR(@ErrorMessage, @ErrorSeverity, 1);  
			END CATCH;  

			
			IF @NoDrop = 0 
			BEGIN 
				PRINT 'DROPPING MERGED SHARDS...';
				SET @query = 'DROP TABLE ' + CONCAT(@tableName, @suffix, '_Merge');
				EXEC sp_execute_remote N'RepoNotesDS', @query, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1 
			END 
		END
		
		IF @noteStorage = 0 AND @IsAzure = 1 
		BEGIN
			
			PRINT CONCAT('MAIN INSERT... //', GETDATE());

			SELECT @columnNames = STUFF((SELECT '],sp.[' + [NAME] FROM @cols WHERE object_id = @oid and name <> 'ComputedRecordNo' and is_identity=0 and is_computed=0 FOR xml path('')),1,1,'') + ']';		
			SET @columnNames = SUBSTRING(@columnNames,2,LEN(@columnNames)-1) 

			SET @query = '
			SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;	
			INSERT INTO '+ @tableName +' ('+ @columnNames +', DatabaseKey, RepoAdded)	
			SELECT ' + @columnNames +','''+ @DatabaseKey +''' as DatabaseKey, GETUTCDATE() as RepoAdded FROM '+ CONCAT(@tableName, @suffix) +' sp 
					LEFT JOIN (SELECT * FROM ' + @tableName + ' WHERE DatabaseKey = '''+ @DatabaseKey +''') dp  
					ON sp.'+@pkColumn+' = dp.'+@pkColumn+' 
			WHERE dp.'+ @pkColumn +' IS NULL '+ REPLACE(@whereAppend,'x.','sp.') + '; 
			EXEC sp_log '''+ @tableName +''', '''+ @sourceName +''', '''+ @DatabaseKey +''','+ CONCAT('',@LoopId) +', @p1, @p2, @@rowcount,''INSERT'', N'''+ @suffix +'''; 
			' 
			PRINT @query;
			EXEC sp_execute_remote N'RepoDS', @query, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1  

		END 

		IF @IsAzure = 0
		BEGIN
						
			PRINT CONCAT('INSERT... // FULLSQL //', GETDATE());

			SELECT @columnNames = STUFF((SELECT '],sp.[' + [NAME] FROM @cols WHERE object_id = @oid and name <> 'ComputedRecordNo' and is_identity=0 and is_computed=0 FOR xml path('')),1,1,'') + ']';		
			SET @columnNames = SUBSTRING(@columnNames,2,LEN(@columnNames)-1) 

			SET @query = '
			SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;	
			INSERT INTO '+ @DQN +' ('+ @columnNames +', DatabaseKey, RepoAdded)	
			SELECT ' + @columnNames +','''+ @DatabaseKey +''' as DatabaseKey, GETUTCDATE() as RepoAdded FROM '+ @SQN +' sp 
					LEFT JOIN (SELECT * FROM ' + @DQN + ' WHERE DatabaseKey = '''+ @DatabaseKey +''') dp  
					ON sp.'+@pkColumn+' = dp.'+@pkColumn+' 
			WHERE dp.'+ @pkColumn +' IS NULL '+ REPLACE(@whereAppend,'x.','sp.') + '; 
			EXEC sp_log '''+ @tableName +''', '''+ @sourceName +''', '''+ @DatabaseKey +''','+ CONCAT('',@LoopId) +', @p1, @p2, @@rowcount,''INSERT'', N'''+ @suffix +'''; 
			' 
			PRINT @query;
			EXEC sp_executesql @query, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1  

		END 		

		PRINT CONCAT('INSERTED: ', @@ROWCOUNT, ' Time:', DATEDIFF(second, @t1, GETDATE()), 's or ', DATEDIFF(minute, @t1, GETDATE()), 'mins ', DATEDIFF(minute, @g1, GETDATE()), 'mins');
		SET @t1 = GETDATE();

		--*****************************
		--**** UPDATE STATEMENT 

		IF @update = 1  
		BEGIN
			PRINT CONCAT('UPDATING: ', @tableName, ' Time:', DATEDIFF(second, @t1, GETDATE()), 's or ', DATEDIFF(minute, @t1, GETDATE()), 'mins ', DATEDIFF(minute, @g1, GETDATE()), 'mins');
			
			BEGIN TRY  

			SELECT @columnNames = STUFF((SELECT '], dp.['+[NAME]+'] = sp.[' + [NAME] FROM @cols WHERE object_id = @oid and name <> 'ComputedRecordNo' and is_identity=0 and is_computed=0 FOR xml path('')),1,1,'') + ']';			
			SET @columnNames = SUBSTRING(@columnNames,2,LEN(@columnNames)-1) 			

			IF @IsAzure = 1 
				BEGIN 
					SET @query = '	
					UPDATE dp SET '+ @columnNames +' 
						FROM '+ CONCAT(@tableName, @suffix) +' sp 
						INNER JOIN ' + @tableName + ' dp  
							ON sp.' + @pkColumn + ' = dp.'+ @pkColumn + ';
					EXEC sp_log '''+ @tableName +''', '''+ @sourceName +''', '''+ @DatabaseKey +''','+ CONCAT('',@LoopId) +', @p1, @p2, @@rowcount,''UPDATE'', N'''+ @suffix +'''; 
					';
					PRINT @query; 
					IF @noteStorage = 1 
						EXEC sp_execute_remote N'RepoNotesDS', @query, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1  
					ELSE 
						EXEC sp_execute_remote N'RepoDS', @query, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1   
				END 
			ELSE 
				BEGIN 
					SET @query = '	
					UPDATE dp SET '+ @columnNames +' 
					FROM '+ @SQN +' sp 
						INNER JOIN ' + @DQN + ' dp  
						ON sp.'+@pkColumn+' = dp.'+@pkColumn+';
					EXEC sp_log '''+ @tableName +''', '''+ @sourceName +''', '''+ @DatabaseKey +''','+ CONCAT('',@LoopId) +', @p1, @p2, @@rowcount,''UPDATE'', N'''+ @suffix +'''; 
					';
					PRINT @query; 
					EXEC sp_executesql @query, N'@p1 DATETIME, @p2 DATETIME', @t1, @g1 
				END

			PRINT CONCAT('UPDATED: ', @@ROWCOUNT, ' Time:', DATEDIFF(second, @t1, GETDATE()), 's or ', DATEDIFF(minute, @t1, GETDATE()), 'mins ', DATEDIFF(minute, @g1, GETDATE()), 'mins');
				
			END TRY  
			BEGIN CATCH
				PRINT 'UPDATE ERROR: '  
				IF @@TRANCOUNT > 0  	  
					DECLARE @ErrorMessage2 nvarchar(4000),  @ErrorSeverity2 int;  				
				SELECT @ErrorMessage2 = ERROR_MESSAGE(),@ErrorSeverity2 = ERROR_SEVERITY();  
				RAISERROR(@ErrorMessage2, @ErrorSeverity2, 1);  
			END CATCH;  

		END
	
		--*********************************************************************************************************************************************************************************
		--**** EXPAND @TABLENAME PROCESSING HERE 
 

		--*********************************************************************************************************************************************************************************
		
		IF @NoDrop = 0 AND @IsAzure = 1 
		BEGIN 
			PRINT 'DROPPING EXTERNAL TABLE...';	
			SET @query = N'DROP EXTERNAL TABLE ' + @tableName + @suffix;
			EXEC(@query);
		
			PRINT 'DROPPING FROM REPOS'	
			IF @noteStorage = 1 
				EXEC sp_execute_remote N'RepoNotesDS', @query 
			ELSE 
				EXEC sp_execute_remote N'RepoDS', @query  
		END 

		--***** UNSET VARS FOR NEXT LOOP
		SET @pkColumn = null; 
		SET @oid = null;
		SET @destinationId = null;
		
		SET @nsql = '';  				
		SET @query = NULL; 
		SET @columnNames = NULL;
		SET @whereFilter = NULL; 
		SET @whereText = ''; 
		SET @whereAppend = ''; 
		SET @dateFilter = NULL; 

		SET @LoopId = @LoopId + 1;

        PRINT CONCAT('FINISHED: ', @tableName, ' Time:', DATEDIFF(second, @t1, GETDATE()), 's or ', DATEDIFF(minute, @t1, GETDATE()), 'mins ', DATEDIFF(minute, @g1, GETDATE()), 'mins');
					
	Cont:		
		RAISERROR('...',0,1) WITH NOWAIT; --FLUSH
		FETCH NEXT FROM tbl_cursor INTO  @tableName, @whereFilter, @dateColumn, @pkColumn, @update, @noteStorage 
	END   
	
	CLOSE tbl_cursor   
	DEALLOCATE tbl_cursor


	--*********************************************************************************************************************************************************************************
	--**** EXPAND PROCESSING HERE 


	-->
		


	--*********************************************************************************************************************************************************************************

 
	PRINT 'PROCESSING LOG RESULTS...'
	IF @IsAzure = 1 
	BEGIN 
	  
		IF NOT EXISTS(SELECT * FROM sys.external_tables WHERE name = 'repo_logs')
		BEGIN 
			EXEC('CREATE EXTERNAL TABLE repo_logs ([ID] [int], [TableName] [varchar](150), [SourceName] [varchar](50), [DatabaseKey] [varchar](50), [Message] [varchar](1000), [LoopID] [decimal](18, 2), [LoopInSeconds] [int], [LoopInMinutes] [int], [RunMinutes] [int], [AvgCPU] [decimal](18, 1), [MaxCPU] [decimal](18, 1), [AvgIO] [decimal](18, 1), [MaxIO] [decimal](18, 1), [AvgLog] [decimal](18, 1), [MaxLog] [decimal](18, 1), [AvgMem] [decimal](18, 1), [MaxMem] [decimal](18, 1), [AvgDTU] [decimal](18, 1), [MaxDTU] [decimal](18, 1), [DateTimeCreated] [datetime] NULL, [DateTimeStart] [datetime] NULL, [PartScheme] [int] NULL, [CompressScheme] [varchar](150) NULL, [AfterCount] [int] NULL, [AffectedCount] [int] NULL, [BatchID] [varchar](50) NULL, ) 
			WITH (DATA_SOURCE = [RepoDS], SCHEMA_NAME = ''dbo'', OBJECT_NAME = ''ImportLogs'');');
		END 

		IF NOT EXISTS(SELECT * FROM sys.external_tables WHERE name = 'note_logs')
		BEGIN 
			EXEC('CREATE EXTERNAL TABLE note_logs ([ID] [int], [TableName] [varchar](150), [SourceName] [varchar](50), [DatabaseKey] [varchar](50), [Message] [varchar](1000), [LoopID] [decimal](18, 2), [LoopInSeconds] [int], [LoopInMinutes] [int], [RunMinutes] [int], [AvgCPU] [decimal](18, 1), [MaxCPU] [decimal](18, 1), [AvgIO] [decimal](18, 1), [MaxIO] [decimal](18, 1), [AvgLog] [decimal](18, 1), [MaxLog] [decimal](18, 1), [AvgMem] [decimal](18, 1), [MaxMem] [decimal](18, 1), [AvgDTU] [decimal](18, 1), [MaxDTU] [decimal](18, 1), [DateTimeCreated] [datetime] NULL, [DateTimeStart] [datetime] NULL, [PartScheme] [int] NULL, [CompressScheme] [varchar](150) NULL, [AfterCount] [int] NULL, [AffectedCount] [int] NULL, [BatchID] [varchar](50) NULL, ) 
			WITH (DATA_SOURCE = [RepoNotesDS], SCHEMA_NAME = ''dbo'', OBJECT_NAME = ''ImportLogs'');');
		END 
	END 

	EXEC sp_log NULL, @sourceName, @DatabaseKey, NULL, @t1, @g1, NULL, N'END', @suffix; 
	

	PRINT 'WAITING FOR LOGS TO COMMIT....';
	
	IF @IsAzure = 1 
	BEGIN 
		INSERT INTO ImportLogs 
		SELECT [TableName], [SourceName], [DatabaseKey], [Message], [LoopID], [LoopInSeconds], [LoopInMinutes], [RunMinutes], [AvgCPU], [MaxCPU], [AvgIO], [MaxIO], [AvgLog], [MaxLog], [AvgMem], [MaxMem], [AvgDTU], [MaxDTU], [DateTimeCreated], [DateTimeStart], [PartScheme], [CompressScheme], [AfterCount], [AffectedCount], [BatchID] 
		FROM repo_logs WHERE BatchID = @suffix; 
	
		INSERT INTO ImportLogs
		SELECT [TableName], [SourceName], [DatabaseKey], [Message], [LoopID], [LoopInSeconds], [LoopInMinutes], [RunMinutes], [AvgCPU], [MaxCPU], [AvgIO], [MaxIO], [AvgLog], [MaxLog], [AvgMem], [MaxMem], [AvgDTU], [MaxDTU], [DateTimeCreated], [DateTimeStart], [PartScheme], [CompressScheme], [AfterCount], [AffectedCount], [BatchID] 
		FROM note_logs WHERE BatchID = @suffix; 
	END 
	ELSE
	BEGIN
		IF OBJECT_ID(@RepoName + '.dbo.ImportLogs') IS NOT NULL 
		BEGIN 
			INSERT INTO ImportLogs 
			EXEC('SELECT [TableName], [SourceName], [DatabaseKey], [Message], [LoopID], [LoopInSeconds], [LoopInMinutes], [RunMinutes], [AvgCPU], [MaxCPU], [AvgIO], [MaxIO], [AvgLog], [MaxLog], [AvgMem], [MaxMem], [AvgDTU], [MaxDTU], [DateTimeCreated], [DateTimeStart], [PartScheme], [CompressScheme], [AfterCount], [AffectedCount], [BatchID] 
			FROM ' + @RepoName + '.dbo.ImportLogs WHERE BatchID = '''+@suffix+''''); 
		END 

		IF OBJECT_ID(@RepoNotes + '.dbo.ImportLogs') IS NOT NULL 
		BEGIN 
			INSERT INTO ImportLogs
			EXEC('SELECT [TableName], [SourceName], [DatabaseKey], [Message], [LoopID], [LoopInSeconds], [LoopInMinutes], [RunMinutes], [AvgCPU], [MaxCPU], [AvgIO], [MaxIO], [AvgLog], [MaxLog], [AvgMem], [MaxMem], [AvgDTU], [MaxDTU], [DateTimeCreated], [DateTimeStart], [PartScheme], [CompressScheme], [AfterCount], [AffectedCount], [BatchID] 
			FROM ' + @RepoNotes + '.dbo.ImportLogs WHERE BatchID = '''+@suffix+''''); 
		END 
	END  
 	
	 
	Select * FROM ImportLogs WHERE BatchID = @suffix ORDER BY DateTimeCreated; 

	AbortEnd: 
	
	--*** CLEAN UP **************************************************
	
	IF @NoDrop = 0 AND @IsAzure = 1 
	BEGIN
		--DROP ALL EXTERNAL TABLES 
		WHILE EXISTS(SELECT * FROM sys.external_tables a INNER JOIN sys.external_data_sources b 
			ON a.data_source_id = b.data_source_id WHERE b.name = @dsName)
		BEGIN 
			DECLARE @drop VARCHAR(500); 
			SELECT TOP 1 @drop = a.name FROM sys.external_tables a INNER JOIN sys.external_data_sources b 
			ON a.data_source_id = b.data_source_id WHERE b.name = @dsName;
			PRINT CONCAT('Dropping ', @drop, '...');
			EXEC('DROP EXTERNAL TABLE ' + @drop);

		END  

		IF EXISTS(SELECT * FROM sys.external_data_sources WHERE name = @dsName)
		BEGIN
			PRINT 'DROPPING DS...'
			SET @query = N'DROP EXTERNAL DATA SOURCE [' + @dsName + '] '; 
			PRINT @query;

			EXEC sp_executesql @query 	
			EXEC sp_execute_remote N'RepoDS', @query 
			EXEC sp_execute_remote N'RepoNotesDS', @query 

 			PRINT 'DROPPED DS';	
		END
	END 
	
	PRINT CONCAT('END OF SCRIPT // ', GETDATE());

 END

  
 
GO
/****** Object:  StoredProcedure [dbo].[sp_import_remote]  ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 1/31/2019
-- Description: Remote Server-to-Server Copy + Import Wrapper 
-- Requirements: Azure SQL Logical DB
-- :: sp_import_remote @sourceName = 'DBNAME', @noDrop=1 
-- :: sp_reset 1  
-- =============================================
CREATE OR ALTER PROCEDURE sp_import_remote
(
    @sourceName VARCHAR(200), 
	@serverName VARCHAR(500) = 'server_name',
	@dateFrom DATETIME = NULL, 
	@dateTo DATETIME = NULL, 
	@noDrop BIT = 0 
)
AS
BEGIN

    SET NOCOUNT ON

	DECLARE @poolName NVARCHAR(500); 
	DECLARE @query NVARCHAR(MAX); 
	DECLARE @copyName NVARCHAR(500); 
	DECLARE @copyState INT;
	DECLARE @serviceLevel NVARCHAR(500); 
	DECLARE @i INT = 0;
	DECLARE @percent REAL; 

	DECLARE @LocalServerName NVARCHAR(100) = CAST(SERVERPROPERTY('SERVERNAME') AS NVARCHAR) 
	DECLARE @LocalAzureUrl NVARCHAR(100) = @LocalServerName + N'.database.windows.net';
	DECLARE @CredName NVARCHAR(100) = 'PoolCred';
	SELECT @CredName = CredentialName FROM ImportConfig; 
	
	PRINT 'STARTING REMOTE COPY OF ' + @sourceName + '...';

	IF @CredName IS NULL 
	BEGIN 
		PRINT 'CREDENTIAL NAME NOT SET IN CONFIG. ABORTING...'
		GOTO AbortEnd; 
	END 
	
	IF NOT EXISTS(SELECT 1 FROM sys.external_data_sources WHERE name = 'MasterDS')
		BEGIN
			PRINT 'Creating Datasource MasterDB...';
			SET @query = N'CREATE EXTERNAL DATA SOURCE [MasterDS] WITH (TYPE = RDBMS, LOCATION = N'''+ @LocalAzureUrl +''', CREDENTIAL = ['+ @CredName +'], DATABASE_NAME = N''master'')';
			PRINT @query; 
			EXEC sp_executesql @query 
			PRINT 'Created'
		END

	IF OBJECT_ID('master_dbs') IS NULL	
		BEGIN
			CREATE EXTERNAL TABLE master_dbs (name SYSNAME, database_id INT, state TINYINT) WITH (DATA_SOURCE = [MasterDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'databases')
		END 

	IF OBJECT_ID('master_copying') IS NULL	
	BEGIN	 
		CREATE EXTERNAL TABLE master_copying (database_id INT, start_date datetimeoffset, modify_date datetimeoffset, percent_complete real, error_code int, partner_server sysname, partner_database sysname) WITH (DATA_SOURCE = [MasterDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'dm_database_copies')
	END 
		
	--COPY NAME
	SET @copyName = @sourceName + 'Copy'; 
	WHILE EXISTS(SELECT name FROM master_dbs WHERE name = @copyName)
	BEGIN 
			
		SET @i = @i + 1; 
		SET @copyName = CONCAT(@sourceName, 'Copy', @i);
		PRINT 'COPY NAME ALREADY TAKEN...' 
		IF @i > 5 
			BREAK
	END 
	
	SET @i = 0; 
	
	PRINT CONCAT('STARTING COPY // ', GETDATE());
	RAISERROR('...',0,1) WITH NOWAIT;

	SET @query = CONCAT(' CREATE DATABASE ', @copyName, ' AS COPY OF ', @serverName, '.', @sourceName, ' (SERVICE_OBJECTIVE = ''S4'') '); 
	PRINT @query; 

	BEGIN TRY  
		EXEC sp_executesql @query; 
	END TRY  
	BEGIN CATCH  
		PRINT 'REMOTE COPY ERROR: '
		IF @@TRANCOUNT > 0  	  
			DECLARE @ErrorMessage nvarchar(4000),  @ErrorSeverity int;
		SELECT @ErrorMessage = ERROR_MESSAGE(),@ErrorSeverity = ERROR_SEVERITY();  
		RAISERROR(@ErrorMessage, @ErrorSeverity, 1);  
		GOTO AbortEnd 
	END CATCH;  
 
	IF OBJECT_ID('master_dbs') IS NOT NULL
	BEGIN 
		
		--WHILE NOT EXISTS(SELECT name FROM [master_dbs] WHERE name = @copyName AND state = 0) 
		WHILE EXISTS(SELECT partner_database FROM [master_copying] WHERE partner_database = @sourceName) 
		BEGIN 
					 
			SELECT @percent = percent_complete FROM [master_copying] WHERE partner_database = @sourceName;  
			PRINT CONCAT('WAITING FOR COPY: ', CAST(@percent AS VARCHAR(5))); 

			SET @i = @i + 1; 
			RAISERROR('...',0,1) WITH NOWAIT;
			WAITFOR DELAY '00:00:02';

			IF @i > 200
			BEGIN
				PRINT 'TAKING TOO LONG, BREAKING...' 
				BREAK 
			END 
		END 

		SELECT @copyState = state FROM [master_dbs] WHERE name = @copyName AND state = 0 
		PRINT CONCAT('Copy DB State: ', @copyState); 
		
		PRINT '30 SECOND COOLDOWN BECAUSE EVEN WITH AFTER COPY ROW DISAPPEARING AND STATE = 0 ITS STILL NOT READY...'
		WAITFOR DELAY '00:00:30';
	END 

	IF EXISTS(SELECT name FROM master_dbs WHERE name = @copyName ) 
		BEGIN 
			PRINT 'CREATED SUCCESFULLY...'
			 
			PRINT 'CHECKING POOL...'
			SELECT TOP 1 @poolName = PoolName FROM ImportConfig	
			IF @poolName IS NOT NULL 
			BEGIN 
				PRINT 'AZURE - SETTING POOL...';
				EXEC('ALTER DATABASE ' + @copyName + '  MODIFY ( SERVICE_OBJECTIVE = ELASTIC_POOL ( name = ' + @poolName + '));');
				PRINT 'ADDED TO POOL';
			END 
 
			WAITFOR DELAY '00:00:10';

			PRINT CONCAT('STARTING IMPORT... //', GETDATE()); 
			EXEC sp_import_database @copyName, @dateFrom, @dateTo 

			IF @noDrop = 0 
			BEGIN 
				PRINT 'DROPPING...' 	
				EXEC('DROP DATABASE ' + @copyName);  	
				PRINT 'DONE'
			END 

		END 
	ELSE 
		PRINT 'ERROR CREATING DB, ABORTING...'

	AbortEnd: 
		
	PRINT CONCAT('END OF SCRIPT // ', GETDATE());

END
GO

/****** Object:  StoredProcedure [dbo].[sp_log]  ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author: Ruy
-- Create Date: 11/30/2018
-- Description: Custom Azure Stats Collection for Queries 
-- =============================================
-- DROP TABLE ImportLogs 

ALTER PROCEDURE [dbo].[sp_log]
(
    @tableName VARCHAR(150), @sourceName VARCHAR(150), @DatabaseKey VARCHAR(50), 
	@loopId DECIMAL(18,2), @t1 DATETIME, @g1 DATETIME, @affected INT = 0, @message VARCHAR(1000) = NULL, @BatchID VARCHAR(50) = NULL  
)
AS
BEGIN

	IF OBJECT_ID('ImportLogs') IS NULL 
	BEGIN 
	 
	CREATE TABLE [dbo].[ImportLogs](
	[ID] [int] IDENTITY(1,1) NOT NULL,
	[TableName] [varchar](150) NULL,	
	[SourceName] [varchar](50) NULL,
	[DatabaseKey] [varchar](50) NULL,	
	[Message] [varchar](1000) NULL,
	[LoopID] [decimal](18, 2) NULL,
	[LoopInSeconds] [int] NULL,
	[LoopInMinutes] [int] NULL,
	[RunMinutes] [int] NULL,
	[AvgCPU] [decimal](18, 1) NULL,
	[MaxCPU] [decimal](18, 1) NULL,
	[AvgIO] [decimal](18, 1) NULL,
	[MaxIO] [decimal](18, 1) NULL,
	[AvgLog] [decimal](18, 1) NULL,
	[MaxLog] [decimal](18, 1) NULL,
	[AvgMem] [decimal](18, 1) NULL,
	[MaxMem] [decimal](18, 1) NULL,
	[AvgDTU] [decimal](18, 1) NULL,
	[MaxDTU] [decimal](18, 1) NULL,
	[DateTimeCreated] [datetime] NULL,
	[DateTimeStart] [datetime] NULL,
	[PartScheme] [int] NULL,
	[CompressScheme] [varchar](150) NULL,
	[AfterCount] [int] NULL,
	[AffectedCount] [int] NULL,
	[BatchID] [varchar](50) NULL,
	CONSTRAINT [PK_ImportLogs] PRIMARY KEY CLUSTERED ([ID] ASC)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF) ON [PRIMARY]) ON [PRIMARY]

	ALTER TABLE [dbo].[ImportLogs] ADD  CONSTRAINT [DF_Logs_DateTimeCreated]  DEFAULT (getdate()) FOR [DateTimeCreated]

	END



    -- SET NOCOUNT ON added to prevent extra result sets from
    -- interfering with SELECT statements.
    SET NOCOUNT ON

		DECLARE @AvgCPU	decimal(18, 1);
		DECLARE @MaxCPU	decimal(18, 1);
		DECLARE @AvgIO	decimal(18, 1);
		DECLARE @MaxIO	decimal(18, 1);
		DECLARE @AvgLog	decimal(18, 1);
		DECLARE @MaxLog	decimal(18, 1);
		DECLARE @AvgMem	decimal(18, 1);
		DECLARE @MaxMem	decimal(18, 1);
		DECLARE @AvgDTU	decimal(18, 1);
		DECLARE @MaxDTU	decimal(18, 1);

		DECLARE @Compression VARCHAR(100); 
		DECLARE @AfterCount INT; 
		DECLARE @Partitions INT; 
		DECLARE @IsAzure BIT = IIF(SERVERPROPERTY('EngineEdition') = 5, 1, 0);

		 
		SELECT @Partitions = COUNT(a.partition_number), @AfterCount = SUM(a.rows), @Compression = MIN(a.data_compression_desc) FROM sys.partitions a WITH (NOLOCK) 
		INNER JOIN sys.tables b ON a.object_id = b.object_id 
		WHERE b.name = @tableName AND a.index_id = 1 

		IF @IsAzure = 1 
		BEGIN 

			SELECT @AvgCPU = AVG(avg_cpu_percent), @MaxCPU = MAX(avg_cpu_percent), @AvgIO = AVG(avg_data_io_percent), @MaxIO = MAX(avg_data_io_percent), 
				@AvgLog = AVG(avg_log_write_percent), @MaxLog = MAX(avg_log_write_percent), @AvgMem = AVG(avg_memory_usage_percent), @MaxMem = MAX(avg_memory_usage_percent) 
			FROM sys.dm_db_resource_stats WHERE end_time >= @g1;

 
			SELECT 
				@AvgDTU = AVG(t.[avg_DTU_percent]), 
				@MaxDTU = MAX(t.[max_DTU_percent]) 
				FROM 		
					(SELECT end_time, 
							(SELECT Avg(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) AS value(v)) AS [avg_DTU_percent], 
							(SELECT Max(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) AS value(v)) AS [max_DTU_percent] 
					FROM sys.dm_db_resource_stats WHERE end_time >= @g1) as t 

		END 
	
		PRINT CONCAT('Loop: ', @loopId, ' Size: ', ' Time: ', DATEDIFF(second, @t1, GETDATE()), 's or ', DATEDIFF(minute, @t1, GETDATE()), 'mins | Run: ', DATEDIFF(minute, @g1, GETDATE()), 'mins @ DTU: ', @MaxDTU, ' | Rows: ', @AfterCount, ' Affected: ', @affected, GETDATE());
	
		-- Insert statements for procedure here
		INSERT INTO ImportLogs(TableName, SourceName, DatabaseKey, [Message], LoopID, LoopInSeconds, LoopInMinutes, RunMinutes, AvgCPU,
		MaxCPU,
		AvgIO,
		MaxIO,
		AvgLog,
		MaxLog,
		AvgMem,
		MaxMem,
		AvgDTU,
		MaxDTU,
		DateTimeStart, 
		PartScheme, 
		CompressScheme, 
		AfterCount, 
		AffectedCount,
		BatchID)
	VALUES(@tableName, @sourceName, @DatabaseKey, @message, @loopId, DATEDIFF(second, @t1, GETDATE()), DATEDIFF(MINUTE, @t1, GETDATE()), DATEDIFF(MINUTE, @g1, GETDATE()), 
		@AvgCPU,
		@MaxCPU,
		@AvgIO,
		@MaxIO,
		@AvgLog,
		@MaxLog,
		@AvgMem,
		@MaxMem,
		@AvgDTU,
		@MaxDTU,
		@t1, 
		@Partitions, 
		@Compression, 
		@AfterCount,
		@affected, 
		@BatchID);

END
GO
/****** Object:  StoredProcedure [dbo].[sp_mon]  ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 12/5/2018
-- Description: sp_who azure alternative 
-- =============================================

CREATE OR ALTER PROCEDURE sp_mon
AS
BEGIN
	SET NOCOUNT ON    
	DECLARE @LocalServerName NVARCHAR(100) = CAST(SERVERPROPERTY('SERVERNAME') AS NVARCHAR) 
	DECLARE @LocalAzureUrl NVARCHAR(100) = @LocalServerName + N'.database.windows.net';
	
	DECLARE @poolName NVARCHAR(500); 
	DECLARE @query NVARCHAR(MAX); 
	DECLARE @CredName NVARCHAR(100) = 'PoolCred';
	SELECT @CredName = CredentialName FROM ImportConfig; 
		
	IF @CredName IS NULL 
	BEGIN 
		PRINT 'CREDENTIAL NAME NOT SET IN CONFIG. ABORTING...'
		GOTO AbortEnd; 
	END 

	IF NOT EXISTS(SELECT 1 FROM sys.external_data_sources WHERE name = 'MasterDS')
		BEGIN
			PRINT 'Creating Datasource MasterDB...';
			SET @query = N'CREATE EXTERNAL DATA SOURCE [MasterDS] WITH (TYPE = RDBMS, LOCATION = N'''+ @LocalAzureUrl +''', CREDENTIAL = ['+ @CredName +'], DATABASE_NAME = N''master'')';
			PRINT @query; 
			EXEC sp_executesql @query 
			PRINT 'Created'
		END

	IF OBJECT_ID('master_dbs') IS NULL	
		BEGIN
			CREATE EXTERNAL TABLE master_dbs (name SYSNAME, database_id INT, state TINYINT) WITH (DATA_SOURCE = [MasterDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'databases')
		END 
    
	SELECT  
		d.name
		,SPID       = s.session_id
        ,Program        = s.[program_name]
        ,StartTime      = DATEADD(HOUR, -5, r.start_time)
        ,ElapsedTime    = CONVERT(TIME, DATEADD(SECOND, DATEDIFF(SECOND, r.start_time, GETDATE()), 0), 114)
        ,s.last_request_end_time        
		,(r.wait_time / 1000 / 60) as WaitMins
		,(r.total_elapsed_time / 1000 / 60) as ElapsedMins
        ,CalculatedStartTime = DATEADD(MILLISECOND, -r.total_elapsed_time, GETDATE()) 
		,command
		,r.status as Request_Status
		,s.status as Session_Status
		,r.last_wait_type
		,s.host_name
		,s.login_name
		,s.row_count
		,s.cpu_time
		,s.logical_reads
		,s.writes
		,s.open_transaction_count  		 		
	FROM  sys.dm_exec_sessions s JOIN sys.dm_exec_requests r ON s.session_id = r.session_id JOIN master_dbs d ON s.database_id = d.database_id 
	WHERE  [program_name] IS NOT NULL AND [program_name] NOT IN ('TdService') AND r.[status] <> 'background' and last_wait_type NOT IN ('MISCELLANEOUS')
	ORDER BY r.wait_time DESC

	AbortEnd: 


END
GO

/****** Object:  StoredProcedure [dbo].[sp_prep] ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 11/29/2018
-- Description: After Elastic Pool Mount, 
-- before importing, optimizations to source db
-- =============================================
CREATE   PROCEDURE [dbo].[sp_prep]
(
   @dsName NVARCHAR(500), 
   @objs s_objs READONLY, 
   @cols s_cols READONLY,    
   @indexes s_indexes READONLY, 
   @keys s_keys READONLY, 
   @fkeys s_fkeys READONLY, 
   @tables s_tables READONLY 
)
AS
BEGIN

	DECLARE @oid INT, @parentName NVARCHAR(500), @tableName NVARCHAR(500), @query NVARCHAR(MAX), @ix NVARCHAR(500), @dbName VARCHAR(500), @ispk BIT;

	SELECT @dbName = database_name FROM sys.external_data_sources WHERE name = @dsName;

	--MOST CURRENT COMPATIBILITY LEVEL  				
	SET @query = N'ALTER DATABASE ' + @dbName + ' SET COMPATIBILITY_LEVEL = 140 ';
	
	EXEC sp_execute_remote @dsName, @query;

	--CHECK TABLES WITH 2+ VARCHAR/BINARY(MAX) FIELDS AND CHANGE TO COLUMNSTORE
	
	DECLARE maxcur CURSOR FOR  	
	SELECT o.object_id, o.name FROM @cols c INNER JOIN @objs o ON o.object_id = c.object_id 
		WHERE c.max_length = -1 AND o.type = 'U' GROUP BY o.object_id, o.name HAVING COUNT(1) > 1; 

	OPEN maxcur 
	FETCH NEXT FROM maxcur INTO @oid, @tableName  
	WHILE @@FETCH_STATUS = 0 
	BEGIN
	 
		--DEPENDANT FOREIGN KEYS 
		PRINT 'CHECKING FOREIGN KEYS...'
		DECLARE fkcur CURSOR FOR 
		SELECT f.name, t.name FROM @fkeys f INNER JOIN @tables t ON f.parent_object_id = t.object_id WHERE referenced_object_id = @oid; 
 
		OPEN fkcur 
		FETCH NEXT FROM fkcur INTO @ix, @parentName 
		WHILE @@FETCH_STATUS = 0 
		BEGIN 			
			PRINT 'DROPPING FK PKS ' + @ix;
			SET @query = 'ALTER TABLE ' + @parentName + ' DROP CONSTRAINT ' + @ix;			
			PRINT @query;
			EXEC sp_execute_remote @dsName, @query;
			FETCH NEXT FROM fkcur INTO @ix, @parentName 
		END 		
		CLOSE fkcur 
		DEALLOCATE fkcur 

		SET @ix = NULL; 
		
		PRINT 'CHECKING INDEXES...'
		--1.1 REMOVE PREVIOUS IXES 
		DECLARE ixcur CURSOR FOR 
		SELECT name, is_primary_key FROM @indexes WHERE object_id = @oid AND [type] <> 5; 

		OPEN ixcur 
		FETCH NEXT FROM ixcur INTO @ix, @ispk 
		WHILE @@FETCH_STATUS = 0 
		BEGIN 			
			PRINT 'DROPPING INDEX ' + @ix;
			
			IF @ispk = 1 
				SET @query = 'ALTER TABLE ' + @tableName + ' DROP CONSTRAINT ' + @ix;
			ELSE 
				SET @query = 'DROP INDEX IF EXISTS ' + @ix + ' ON ' + @tableName + '';

			PRINT @query;

			EXEC sp_execute_remote @dsName, @query;

			FETCH NEXT FROM ixcur INTO @ix, @ispk 
		END 		
		CLOSE ixcur 
		DEALLOCATE ixcur 

		--1.2 NEW
		SET @query = CONCAT('IF NOT EXISTS(SELECT NAME FROM sys.indexes WHERE name = ''IX_CS_', @tableName,''') CREATE CLUSTERED COLUMNSTORE INDEX [IX_CS_', @tableName, '] ON ', 
									@tableName, ' WITH (DATA_COMPRESSION = COLUMNSTORE_ARCHIVE) '); 		
		PRINT 'CREATING COLUMNSTORE...';
		PRINT @query; 			
		EXEC sp_execute_remote @dsName, @query;

		FETCH NEXT FROM maxcur INTO @oid, @tableName 
	END

	CLOSE maxcur 
	DEALLOCATE maxcur 

	--*******EXPAND PROCESSING HERE ************** 
 

END
GO
/****** Object:  StoredProcedure [dbo].[sp_remove]  ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 11/15/2018
-- Description: Rollback / Remove Data by Key
-- =============================================
CREATE   PROCEDURE [dbo].[sp_remove] 
(
	@key VARCHAR(50) 
)
AS
BEGIN
  
	PRINT 'REMOVING/DATA ROLLBACK FOR DatabaseKey' + @key;
			
	IF OBJECT_ID('repo_tables') IS NULL 
		BEGIN 
			CREATE EXTERNAL TABLE repo_tables (name SYSNAME, is_external BIT, object_id INT) WITH (DATA_SOURCE = [RepoDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'tables')				
		END 

	IF OBJECT_ID('note_tables') IS NULL 
		BEGIN 
			CREATE EXTERNAL TABLE note_tables (name SYSNAME, is_external BIT, object_id INT) WITH (DATA_SOURCE = [RepoNotesDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'tables')
		END 			

	DECLARE @name VARCHAR(500);
	DECLARE @query NVARCHAR(2000)
	DECLARE repocur CURSOR FOR 
	SELECT name FROM repo_tables WHERE is_external = 0  

	OPEN repocur 
	FETCH NEXT FROM repocur INTO @name 

	WHILE @@FETCH_STATUS = 0 
	BEGIN 
			
		SET @query = N'DELETE FROM ' + @name + ' WHERE DatabaseKey = ''' + @key + ''' ';
		PRINT @query;
		EXEC sp_execute_remote N'RepoDS', @query; 
		PRINT '- DONE';

		FETCH NEXT FROM repocur INTO @name 
	END 

	CLOSE repocur 
	DEALLOCATE repocur 

		
	DECLARE repocur CURSOR FOR 
	SELECT name FROM note_tables WHERE is_external = 0  

	OPEN repocur 
	FETCH NEXT FROM repocur INTO @name 

	WHILE @@FETCH_STATUS = 0 
	BEGIN 
			
		SET @query = N'DELETE FROM ' + @name + ' WHERE DatabaseKey = ''' + @key + ''' ';
		PRINT @query;
		EXEC sp_execute_remote N'RepoNotesDS', @query; 
		PRINT '- DONE';

		FETCH NEXT FROM repocur INTO @name 
	END 

	CLOSE repocur 
	DEALLOCATE repocur 
	     
	PRINT CONCAT('END OF SCRIPT // ', GETDATE());

END
GO
/****** Object:  StoredProcedure [dbo].[sp_report]  ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 11/30/2018
-- Description: Report Counts and Totals 
-- sp_report
-- =============================================
CREATE PROCEDURE [dbo].[sp_report] 
(
 @option VARCHAR(2) = NULL
)
AS
BEGIN

    SET NOCOUNT ON	 

	DECLARE @query NVARCHAR(MAX); 

	SET @query = '
		IF OBJECT_ID(''ImportCounts'') IS NULL 
		BEGIN 		 
			CREATE TABLE ImportCounts (TableName VARCHAR(100), RecordCount INT, SizeMB DECIMAL(18, 2), NoteStore BIT)
		END 
		TRUNCATE TABLE ImportCounts; 
		INSERT INTO ImportCounts 	
		SELECT t.name, SUM(s.row_count), SUM(reserved_page_count * 8.0 / 1024), @isNote FROM sys.tables t join sys.dm_db_partition_stats s 
		ON t.object_id = s.object_id AND t.type_desc = ''USER_TABLE'' AND t.name not like ''%dss%'' AND s.index_id = 1 
		GROUP BY t.name 
		ORDER BY t.name 
	'; 

	EXEC sp_execute_remote [RepoDS], @query, N'@isNote BIT = 0'; 

	EXEC sp_execute_remote [RepoNotesDS], @query, N'@isNote BIT = 1'; 

	IF OBJECT_ID('repo_counts') IS NULL 
	BEGIN 
		CREATE EXTERNAL TABLE repo_counts (TableName VARCHAR(100), RecordCount INT, SizeMB DECIMAL(18, 2), NoteStore BIT)
		WITH (DATA_SOURCE = [RepoDS], SCHEMA_NAME = 'dbo', OBJECT_NAME = 'ImportCounts') 
	END 
	
	IF OBJECT_ID('note_counts') IS NULL 
	BEGIN 
		CREATE EXTERNAL TABLE note_counts (TableName VARCHAR(100), RecordCount INT, SizeMB DECIMAL(18, 2), NoteStore BIT)
		WITH (DATA_SOURCE = [RepoNotesDS], SCHEMA_NAME = 'dbo', OBJECT_NAME = 'ImportCounts') 
	END 

	IF OBJECT_ID('ImportCounts') IS NULL 
	BEGIN 		 	 
		CREATE TABLE ImportCounts (TableName VARCHAR(100), RecordCount INT, SizeMB DECIMAL(18, 2), NoteStore BIT)
	END 
	TRUNCATE TABLE ImportCounts; 
	INSERT INTO ImportCounts (TableName, RecordCount, SizeMB, NoteStore) 
	SELECT * FROM repo_counts 
	UNION 
	SELECT * FROM note_counts 
	
	SELECT * FROM ImportCounts 
       
END
GO
/****** Object:  StoredProcedure [dbo].[sp_reset]  ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 1/15/2018
-- Description: Truncate Logs and Data Tables 
-- =============================================
CREATE PROCEDURE [dbo].[sp_reset] 
(
	@data BIT = 0 
)
AS
BEGIN
  
	PRINT 'TRUNCATING IMPORT LOGS...';
	TRUNCATE TABLE ImportLogs; 
	EXEC sp_execute_remote N'RepoDS', N'TRUNCATE TABLE ImportLogs'; 
	EXEC sp_execute_remote N'RepoNotesDS', N'TRUNCATE TABLE ImportLogs'; 
	PRINT 'DONE'

	IF @data = 1 
	BEGIN 
		PRINT 'TRUNCATING DATA TABLES...'

		IF OBJECT_ID('repo_tables') IS NULL 
			BEGIN 
				CREATE EXTERNAL TABLE repo_tables (name SYSNAME, is_external BIT, object_id INT) WITH (DATA_SOURCE = [RepoDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'tables')				

			END 

		IF OBJECT_ID('note_tables') IS NULL 
			BEGIN 
				CREATE EXTERNAL TABLE note_tables (name SYSNAME, is_external BIT, object_id INT) WITH (DATA_SOURCE = [RepoNotesDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'tables')

			END 			

		DECLARE @name VARCHAR(500);
		DECLARE @query NVARCHAR(2000)
		DECLARE repocur CURSOR FOR 
		SELECT name FROM repo_tables WHERE is_external = 0  

		OPEN repocur 
		FETCH NEXT FROM repocur INTO @name 

		WHILE @@FETCH_STATUS = 0 
		BEGIN 
			
			SET @query = N'TRUNCATE TABLE ' + @name;
			PRINT @query;
			EXEC sp_execute_remote N'RepoDS', @query; 
			PRINT '- DONE';

			FETCH NEXT FROM repocur INTO @name 
		END 

		CLOSE repocur 
		DEALLOCATE repocur 

		
		DECLARE repocur CURSOR FOR 
		SELECT name FROM note_tables WHERE is_external = 0  

		OPEN repocur 
		FETCH NEXT FROM repocur INTO @name 

		WHILE @@FETCH_STATUS = 0 
		BEGIN 
			
			SET @query = N'TRUNCATE TABLE ' + @name;
			PRINT @query;
			EXEC sp_execute_remote N'RepoNotesDS', @query; 
			PRINT '- DONE';

			FETCH NEXT FROM repocur INTO @name 
		END 

		CLOSE repocur 
		DEALLOCATE repocur 

	END 

	PRINT CONCAT('END OF SCRIPT // ', GETDATE());
     
END
GO
/****** Object:  StoredProcedure [dbo].[sp_schema]  ******/
-- =============================================
-- Author: Ruy
-- Create Date: 1/31/2019
-- Description: Elastic Consolidator Create Tables Script
-- =============================================
 
--EXEC [sp_schema] 'DBNAME' 
--sp_schema sp_report 

CREATE OR ALTER PROCEDURE [dbo].[sp_schema]
	@sourceName VARCHAR(100) 
AS
BEGIN
	SET NOCOUNT ON;
	
	--DEBUG FLAGS
	DECLARE @NoDrop BIT = 0; 
	DECLARE @NoLog BIT = 0; 		
	
	PRINT CONCAT('START OF SCRIPT // ', GETDATE());

	IF OBJECT_ID('ImportConfig') IS NULL
	BEGIN 
		PRINT 'REPO MASTER CONFIG NOT FOUND - ARE WE IN CORRECT DB? ABORTING...'
		GOTO AbortEnd 
	END 
	 
	--GET ENV
	DECLARE @ServerName NVARCHAR(100) = CAST(SERVERPROPERTY('SERVERNAME') AS NVARCHAR) 
	DECLARE @AzureUrl NVARCHAR(100) = @ServerName + N'.database.windows.net';
	DECLARE @IsAzure BIT = IIF(SERVERPROPERTY('EngineEdition') = 5, 1, 0);
	DECLARE @PoolName NVARCHAR(100) = 'DBPool';
	DECLARE @RepoMaster NVARCHAR(100) = DB_NAME();
	DECLARE @RepoName NVARCHAR(100) = 'Repo';
	DECLARE @RepoNotes NVARCHAR(100) = 'RepoNotes';
	DECLARE @CredName NVARCHAR(100) = 'PoolCred';
	DECLARE @Enabled BIT = 1; 
	  
	SELECT TOP 1 
		@RepoName = RepoName, 
		@RepoNotes = RepoNotes, 
		@PoolName = PoolName, 
		@CredName = CredentialName, 
		@Enabled = [Enabled] 
	FROM ImportConfig 
	 
	PRINT CONCAT('IMPORT RUN CONTEXT: ', DB_NAME()); 
	PRINT CONCAT('SOURCE: ', @sourceName); 
	PRINT CONCAT('TARGET REPOS - Main: ', @RepoName, ' | Notes: ', @RepoNotes); 	
	PRINT CONCAT('CRED: ', @CredName, ' POOL: ', @PoolName); 	
			
	DECLARE @message NVARCHAR(100) = 'V1R10';
	DECLARE @g1 DATETIME = GETDATE();
	DECLARE @t1 DATETIME = GETDATE();
	DECLARE @LoopId INT = 1;
	DECLARE @query NVARCHAR(MAX) 
	DECLARE @hash TABLE (Result VARCHAR(MAX))	
	DECLARE @columnNames NVARCHAR(MAX); 	 	
	DECLARE @id UNIQUEIDENTIFIER; 
	DECLARE @pkColumn NVARCHAR(250); 	
	DECLARE @tableName VARCHAR(500)
	DECLARE @update BIT = 1; 
	DECLARE @whereFilter VARCHAR(500); 
	DECLARE @dateColumn NVARCHAR(500); 	 
	DECLARE @noteStorage BIT = 0;
 

	--**** AUTO-SCRIPT OPTIONS
	DECLARE @CrLf NVARCHAR(2) = CHAR(13) + CHAR(10);
	DECLARE @Indent NVARCHAR(2) = SPACE(2);	

	--**** CACHE  
	DECLARE @objs AS s_objs 
	DECLARE @cols AS s_cols
	DECLARE @tables AS s_tables
	DECLARE @schemas AS s_schemas
	DECLARE @cmps AS s_cmps
	DECLARE @types AS s_types	
	DECLARE @indexes AS s_indexes
	DECLARE @keys AS s_keys 
	DECLARE @fkeys AS s_fkeys 	
	
	PRINT CONCAT('Loop:', @LoopId, ' Time:', DATEDIFF(second, @t1, GETDATE()), 's or ', DATEDIFF(minute, @t1, GETDATE()), 'mins ', DATEDIFF(minute, @g1, GETDATE()), 'mins');
 
	--**** EXISTS PRE-CHECK 
	IF @IsAzure = 1 
	BEGIN 
		IF NOT EXISTS(SELECT 1 FROM sys.external_data_sources WHERE name = 'MasterDS')
		BEGIN
			PRINT 'Creating Datasource MasterDB...';
			SET @query = N'CREATE EXTERNAL DATA SOURCE [MasterDS] WITH (TYPE = RDBMS, LOCATION = N'''+ @AzureUrl +''', CREDENTIAL = ['+ @CredName +'], DATABASE_NAME = N''master'')';
			PRINT @query; 
			EXEC sp_executesql @query 
			PRINT 'Created'
		END

		IF OBJECT_ID('master_dbs') IS NULL	
		BEGIN
			CREATE EXTERNAL TABLE master_dbs (name SYSNAME, database_id INT, state TINYINT) WITH (DATA_SOURCE = [MasterDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'databases')
		END 

		IF NOT EXISTS(SELECT name FROM master_dbs WHERE name = @sourceName) 
		BEGIN 
			PRINT 'SOURCE DATABASE NOT FOUND/MOUNTED IN SERVER: ' + @serverName; 	
			PRINT 'TYPO? FAILED UPLOAD? ABORTING...'	
			GOTO AbortEnd; 
		END 
	END 
	ELSE 
	BEGIN 
		IF NOT EXISTS(SELECT name FROM sys.databases WHERE name = @sourceName) 
		BEGIN 
			PRINT 'SOURCE DATABASE NOT FOUND/MOUNTED IN SERVER: ' + @serverName; 
			PRINT 'TYPO? FAILED UPLOAD? ABORTING...'
			GOTO AbortEnd; 
		END 
	END 
 
	DECLARE @suffix NVARCHAR(100) = CONCAT('', ABS(Checksum(NewID()))); 
	PRINT @suffix;
	DECLARE @dsName NVARCHAR(500) = CONCAT('DS', @suffix); 

 
	PRINT 'LINKING DATABASES ...'		 
	IF @IsAzure = 1  
	BEGIN 

		PRINT CONCAT('Temp DS: ',@dsName);

		--CREATE DATASOURCE FOR SOURCE 
		IF NOT EXISTS(SELECT 1 FROM sys.external_data_sources WHERE name = @dsName)
		BEGIN
			PRINT 'Creating Datasource ' + @dsName + '...';
			SET @query = N'CREATE EXTERNAL DATA SOURCE [' + @dsName + '] WITH (TYPE = RDBMS, LOCATION = N'''+ @AzureUrl +''', CREDENTIAL = ['+ @CredName +'], DATABASE_NAME = N'''+ @sourceName +''')';
			PRINT @query; 
			EXEC sp_executesql @query 
			PRINT 'Created'
		END
 
		--CREATE DATASOURCE IN REPOs 
		EXEC sp_execute_remote N'RepoDS', @query; 	
		EXEC sp_execute_remote N'RepoNotesDS', @query;
		
		IF OBJECT_ID('repo_objs') IS NULL 
		BEGIN 
			PRINT 'Creating repo.objects...'
			CREATE EXTERNAL TABLE [repo_objs] 
			(name sysname, object_id int,principal_id int,schema_id int,parent_object_id int, type char(2)) WITH (DATA_SOURCE = [RepoDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'objects');
		END

		IF OBJECT_ID('note_objs') IS NULL 
		BEGIN 
			PRINT 'Creating note.objects...'
			CREATE EXTERNAL TABLE [note_objs] 
			(name sysname, object_id int,principal_id int,schema_id int,parent_object_id int, type char(2)) WITH (DATA_SOURCE = [RepoNotesDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'objects');
		END

		--CACHED SOURCES 
		IF OBJECT_ID(CONCAT('objs', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.objects...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('objs', @suffix) + '] ' +  
			'(name sysname, object_id int,principal_id int,schema_id int,parent_object_id int, type char(2)) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''objects'')';
			PRINT @query
			EXEC sp_executesql @query 
		END

		IF OBJECT_ID(CONCAT('cols', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.columns...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('cols', @suffix) + '] ' +  
			'(object_id	int, name sysname, column_id int, system_type_id tinyint, user_type_id	int, max_length	smallint, precision	tinyint, scale tinyint, is_nullable	bit, is_rowguidcol	bit, is_identity bit, is_computed bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''columns'')';
			PRINT @query
			EXEC sp_executesql @query 
		END
		
		IF OBJECT_ID(CONCAT('tb', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.tables...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('tb', @suffix) + '] ' +  
			'(name	sysname, object_id	int, principal_id	int, schema_id	int, parent_object_id int, is_filetable bit, is_memory_optimized	bit, is_external	bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''tables'')';
			PRINT @query
			EXEC sp_executesql @query 
		END
		

		IF OBJECT_ID(CONCAT('sch', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.schemas...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('sch', @suffix) + '] ' +  
			'(name sysname, schema_id int, principal_id int) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''schemas'')';
			PRINT @query
			EXEC sp_executesql @query 
		END
		
		IF OBJECT_ID(CONCAT('cmp', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.computed...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('cmp', @suffix) + '] ' +  
			'(object_id	int, name sysname, column_id int, system_type_id tinyint, user_type_id	int, max_length	smallint, precision	tinyint, scale tinyint, is_nullable	bit, is_rowguidcol	bit, is_identity bit, is_computed bit, definition nvarchar(max) null, is_persisted bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''computed_columns'')';
			PRINT @query
			EXEC sp_executesql @query 
		END
 
		IF OBJECT_ID(CONCAT('tp', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.types...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('tp', @suffix) + '] ' +  
			'(name sysname,system_type_id tinyint,user_type_id int,schema_id int,principal_id int,max_length smallint,precision tinyint,scale	tinyint,is_nullable bit,is_user_defined	bit,is_assembly_type bit,default_object_id int,rule_object_id	int,is_table_type	bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''types'')';
			PRINT @query
			EXEC sp_executesql @query 
		END	

		IF OBJECT_ID(CONCAT('ix', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.indexes...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('ix', @suffix) + '] ' +  
			'(name SYSNAME NULL, object_id INT, index_id INT, type TINYINT, is_unique BIT, is_primary_key BIT) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''indexes'')';
			PRINT @query
			EXEC sp_executesql @query 
		END	
 
		IF OBJECT_ID(CONCAT('key', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.key_constraints...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('key', @suffix) + '] ' +  
			'(name sysname, object_id int, principal_id int, schema_id	int, parent_object_id int, type	char(2), create_date datetime, modify_date datetime, unique_index_id int, is_system_named bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''key_constraints'')';
			PRINT @query
			EXEC sp_executesql @query 
		END	

		IF OBJECT_ID(CONCAT('fk', @suffix)) IS NULL 
		BEGIN 
			PRINT 'Creating sys.foreign_keys...'
			SET @query = N'CREATE EXTERNAL TABLE [' + CONCAT('fk', @suffix) + '] ' +  
			'(name sysname, object_id int, principal_id int, schema_id	int, parent_object_id int, type	char(2), create_date datetime, modify_date datetime, referenced_object_id int, is_system_named bit) WITH (DATA_SOURCE = ['+ @dsName +'], SCHEMA_NAME = ''sys'', OBJECT_NAME = ''foreign_keys'')';
			PRINT @query
			EXEC sp_executesql @query 
		END	
	 
		--CACHE FILL 

		SET @query = N'SELECT * FROM objs' + @suffix; 
		INSERT INTO @objs 
			EXEC sp_executesql @query;
		PRINT CONCAT('Objects: ', @@rowcount); 

		SET @query = N'SELECT * FROM cols' + @suffix; 
		INSERT INTO @cols 
			EXEC sp_executesql @query;
		PRINT CONCAT('Cols: ', @@rowcount); 

		SET @query = N'SELECT * FROM tb' + @suffix; 
		INSERT INTO @tables 
			EXEC sp_executesql @query;	
		PRINT CONCAT('Tables: ', @@rowcount); 

		SET @query = N'SELECT * FROM sch' + @suffix; 
		INSERT INTO @schemas  
			EXEC sp_executesql @query;
		PRINT CONCAT('Schemas: ', @@rowcount); 

		SET @query = N'SELECT * FROM cmp' + @suffix; 
		INSERT INTO @cmps  
			EXEC sp_executesql @query;
		PRINT CONCAT('Cmps: ', @@rowcount); 
	
		SET @query = N'SELECT * FROM tp' + @suffix; 
		INSERT INTO @types 
			EXEC sp_executesql @query;
		PRINT CONCAT('Types: ', @@rowcount); 

		SET @query = N'SELECT * FROM ix' + @suffix + ' WHERE name IS NOT NULL '; 
		INSERT INTO @indexes  
			EXEC sp_executesql @query;
		PRINT CONCAT('Indexes: ', @@rowcount); 

		SET @query = N'SELECT * FROM key' + @suffix; 
		INSERT INTO @keys 
			EXEC sp_executesql @query;
		PRINT CONCAT('Keys: ', @@rowcount); 

		SET @query = N'SELECT * FROM fk' + @suffix; 
		INSERT INTO @fkeys  
			EXEC sp_executesql @query;
		PRINT CONCAT('Foreign: ', @@rowcount); 

 
	END 
	ELSE 
	BEGIN

		SET @query = N'SELECT * FROM ' + CONCAT(@sourceName, '.sys.objects'); 
		INSERT INTO @objs 
			EXEC sp_executesql @query;
		PRINT CONCAT('Objects: ', @@rowcount); 

		SET @query = N'SELECT * FROM ' + CONCAT(@sourceName, '.sys.columns'); 
		INSERT INTO @cols 
			EXEC sp_executesql @query;
		PRINT CONCAT('Cols: ', @@rowcount); 

		SET @query = N'SELECT * FROM ' + CONCAT(@sourceName, '.sys.tables'); 
		INSERT INTO @tables 
			EXEC sp_executesql @query;	
		PRINT CONCAT('Tables: ', @@rowcount); 

		SET @query = N'SELECT * FROM ' + CONCAT(@sourceName, '.sys.schemas'); 
		INSERT INTO @schemas  
			EXEC sp_executesql @query;
		PRINT CONCAT('Schemas: ', @@rowcount); 

		SET @query = N'SELECT * FROM ' + CONCAT(@sourceName, '.sys.computed_columns'); 
		INSERT INTO @cmps  
			EXEC sp_executesql @query;
		PRINT CONCAT('Cmps: ', @@rowcount); 
	
		SET @query = N'SELECT * FROM ' + CONCAT(@sourceName, '.sys.types'); 
		INSERT INTO @types 
			EXEC sp_executesql @query;
		PRINT CONCAT('Types: ', @@rowcount); 
		 
		SET @query = N'SELECT * FROM ' + CONCAT(@sourceName, '.sys.indexes') + ' WHERE name IS NOT NULL '; 
		INSERT INTO @indexes 
			EXEC sp_executesql @query;
		PRINT CONCAT('Indexes: ', @@rowcount); 

		SET @query = N'SELECT * FROM ' + CONCAT(@sourceName, '.sys.key_constraints'); 
		INSERT INTO @keys 
			EXEC sp_executesql @query;
		PRINT CONCAT('Keys: ', @@rowcount); 

		SET @query = N'SELECT * FROM ' + CONCAT(@sourceName, '.sys.foreign_keys'); 
		INSERT INTO @fkeys  
			EXEC sp_executesql @query;
		PRINT CONCAT('Foreign: ', @@rowcount); 

	END 
   
	--*****************************************************************************************************************************************************************************************
	--**** IMPORT CONFIGURED TABLES 

	DECLARE tbl_cursor CURSOR FOR  
	SELECT TableName, WhereFilter, DateFilterColumn, PrimaryKeyColumn, RunUpdate, NoteStorage FROM ImportTables WHERE Enabled = 1 ORDER BY SequenceOrder, TableName 
	
	OPEN tbl_cursor   
	FETCH NEXT FROM tbl_cursor INTO @tableName, @whereFilter, @dateColumn, @pkColumn, @update, @noteStorage  
	
	WHILE @@FETCH_STATUS = 0   
	BEGIN
		
		DECLARE @nsql NVARCHAR(MAX)	
		DECLARE @oid INT; 
		DECLARE @FQN VARCHAR(MAX) = @sourceName + '.dbo.' + @tableName; 
		DECLARE @DQN VARCHAR(MAX) = @RepoName + '.dbo.' + @tableName; 

		DECLARE @TableOptions NVARCHAR(500) = ' WITH (SCHEMA_NAME = ''dbo'', OBJECT_NAME = '''+ @tableName +''', DATA_SOURCE = ['+ @dsName +'])'

		DECLARE @inserted INT = 0;
		DECLARE @updated INT = 0;
		-- ************************************** 

		IF @noteStorage = 1 
		BEGIN 
			SET @DQN = @RepoNotes + '.dbo.' + @tableName;
		END 
		
		PRINT @FQN + ' => ' + @DQN;

		--WE GOOD ON SOURCE?
		SELECT @oid = [object_id] FROM @objs WHERE name = @tableName AND type = 'U';
		PRINT CONCAT('ObjectID: ', @oid); 				
		IF @oid IS NULL
		BEGIN 
			PRINT 'SOURCE TABLE NOT FOUND! SKIPPING...' 
			Goto Cont
		END 

		--PRIMARY KEY   
		--TODO: CHANGE TO SYS.IX
		IF @pkColumn IS NULL 
		BEGIN
			PRINT 'PrimaryKey not set, auto-discovering...'; 
			SELECT @pkColumn = [name] FROM @cols WHERE [object_id] = @oid AND [NAME] like 'PK_%'; 
			PRINT CONCAT('FOUND PK: ', @pkColumn);
		END		 

		IF @pkColumn IS NULL
		BEGIN 
			PRINT 'NO PK, SKIPPING FOR NOW...';
			Goto Cont
		END 
		   
		--*****************************
		--**** INSERT STATEMENT 		  		

		PRINT 'CHECKING DESTINATION...';

		DECLARE @destinationId INT; 

		IF @noteStorage = 1 
			SELECT @destinationId = object_id from note_objs WHERE name = @tableName AND type = 'U';
		ELSE 
			SELECT @destinationId = object_id from repo_objs WHERE name = @tableName AND type = 'U';

		IF @destinationId IS NULL
		BEGIN
			PRINT 'DESTINATION NOT FOUND - CREATING...'
						
			EXEC sp_get_create N'CREATE TABLE', @tableName, @pkColumn, @dateColumn, @oid, @tables, @schemas, @cols, @types, @cmps, @query_out = @nsql OUTPUT;				 
			
			DECLARE @indexsql NVARCHAR(MAX) = 'CREATE NONCLUSTERED INDEX IX_'+@tableName+'_DatabaseKey ON ['+ @tableName + '] (DatabaseKey);';
			
			DECLARE @pksql NVARCHAR(MAX) = ', CONSTRAINT [' + @pkColumn + 's] PRIMARY KEY CLUSTERED (['+@pkColumn+'] ASC)'; 

			IF @noteStorage = 1
			BEGIN 				
				SET @pksql = ', INDEX [' + @pkColumn + 's] CLUSTERED COLUMNSTORE, INDEX [IX_CS_' + @tableName + '] (['+@dateColumn+'] ASC, ['+@pkColumn+'] ASC) '; 
				PRINT 'EXECUTING IN NOTES...' 
				SET @nsql = CONCAT(@nsql, @CrLf, @indent,', DatabaseKey VARCHAR(50) NULL, RepoAdded DATETIME NULL ', @pksql,')', 
									' ON [PS_NotesByDate]([', @dateColumn,']);', @indexsql);
				PRINT @nsql;
				EXEC sp_execute_remote [RepoNotesDS], @nsql;
			END
			ELSE
			BEGIN
				PRINT 'EXECUTING IN MAIN...'				
				SET @nsql = CONCAT(@nsql, @CrLf, @indent,', DatabaseKey VARCHAR(50) NULL, RepoAdded DATETIME NULL ', @pksql,');', @indexsql);  
				PRINT @nsql;
				EXEC sp_execute_remote [RepoDS], @nsql; 
			END 
			PRINT 'CREATED'

			IF @noteStorage = 1 
				SELECT @destinationId = object_id from note_objs WHERE name = @tableName AND type = 'U';
			ELSE 
				SELECT @destinationId = object_id from repo_objs WHERE name = @tableName AND type = 'U';
		END
		ELSE 
			PRINT 'DESTINATION TABLE ALREADY CREATED...'
		 

		PRINT CONCAT('DestinationId: ', @destinationId);
 
		--***** UNSET VARS FOR NEXT LOOP
		SET @pkColumn = NULL;
		SET @oid = NULL;
		SET @destinationId = NULL;		
		SET @nsql = '';  				
		SET @query = NULL; 
		SET @columnNames = NULL;

		SET @LoopId = @LoopId + 1;

        PRINT CONCAT('FINISHED: ', @tableName, ' Time:', DATEDIFF(second, @t1, GETDATE()), 's or ', DATEDIFF(minute, @t1, GETDATE()), 'mins ', DATEDIFF(minute, @g1, GETDATE()), 'mins');
					
	Cont:		
		RAISERROR('...',0,1) WITH NOWAIT; --FLUSH
		FETCH NEXT FROM tbl_cursor INTO  @tableName, @whereFilter, @dateColumn, @pkColumn, @update, @noteStorage 
	END   
	
	CLOSE tbl_cursor   
	DEALLOCATE tbl_cursor
 

	AbortEnd: 
 	
	PRINT CONCAT('END OF SCRIPT // ', GETDATE());

 END


--*END OF SELECT
*/










 