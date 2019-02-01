# ElasticPoolDatabaseImporter
Azure SQL Elastic Pool Database Consolidator / Importer Scripts


Consolidating or Merging Azure SQL Databases
---------------------------------------------------------------

T-SQL only import tables script for Azure SQL Logical Databases and Elastic Pool utilizing 
dynamic external tables and lots of sp_execute_remote + Utilities  


Scripts have optional functionality to separate Large OBject (LOBs = NVARCHAR(MAX) = COL LENGTH = -1)
into another database (little performance gain)


## Troubleshooting Azure Sql Server-to-Server Database Copy
---------------------------------------------------------------

Sample Script: 

'''
CREATE DATABASE copyName AS COPY OF sourceServerName.sourceDatabaseName 

ALTER DATABASE DbName MODIFY (SERVICE_OBJECTIVE = ELASTIC_POOL (NAME = PoolName))
GO


ERROR: 
Msg 45137, Level 16, State 1, Line 9
Insufficient permission to create a database copy on server 'serverName'
'''

### Possibles Causes: 
- Missing db_Owner role on source 
- Missing dbManager role on execution context login (Your Connection on SSMS or connection string user)
- When executing in SQL Server Management Studio firewall rules are needed on both servers, otherwise 
  the insufficient permission error will drive you nuts



