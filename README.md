# Elastic Pool Database Importer
Azure SQL Elastic Pool Database Consolidator / Importer Scripts


Consolidating or Merging Azure SQL Databases
---------------------------------------------------------------

Import selected tables from multiple databases into one, even from remote subscriptions. T-SQL only import tables script for 
Azure SQL Logical Databases and Elastic Pool utilizing dynamic queries and lots of `sp_execute_remote` plus 
other utilities to check long running queries. 


Scripts have optional functionality to separate Large OBject (LOBs = NVARCHAR(MAX) = COL LENGTH = -1)
into another database for a performance gain. 



## Installation
--------------------------------------------------------------
Use them directly or open the install_script.sql in SSMS and follow the installation instructions. 
It will install the `ImportConfig`, `ImportTables` utility tables and the stored procedures.

Please check before running, install script will create 3 Databases: Master, Repo and LOBs. 


## Usage 
--------------------------------------------------------------

```

Basic Usage: 
EXEC sp_import_database 'dbName'

Optional Command Line Parameters: @DateFrom and @DateTo 
EXEC sp_import_database 'dbName', '2019-01-01', '2019-03-31'

Remote Server/Subscription:
EXEC sp_import_remote 'dbName, 'serverName' 


```


## Troubleshooting Azure Sql Server-to-Server Database Copy
---------------------------------------------------------------

Sample Script: 

```
CREATE DATABASE copyName AS COPY OF sourceServerName.sourceDatabaseName 

ALTER DATABASE copyName MODIFY (SERVICE_OBJECTIVE = ELASTIC_POOL (NAME = PoolName))
GO


ERROR: 
Msg 45137, Level 16, State 1, Line 9
Insufficient permission to create a database copy on server 'serverName'
```

### Possible Causes: 
* Missing db_Owner role on remote source database 
* Missing dbManager role on execution context login (Your Connection on SSMS or connection string user)
* When executing in SQL Server Management Studio firewall rules are needed on both servers, otherwise 
  the insufficient permission error will drive you nuts



