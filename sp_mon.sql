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
