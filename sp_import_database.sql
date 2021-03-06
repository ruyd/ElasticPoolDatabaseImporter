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
		--ADD SUPPORT FOR MAPTBL DUAL TRIPLE FK'S
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

 






 