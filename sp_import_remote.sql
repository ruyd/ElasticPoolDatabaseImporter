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
