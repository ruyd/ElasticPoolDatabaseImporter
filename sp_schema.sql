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

 






 