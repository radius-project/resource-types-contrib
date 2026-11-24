#!/bin/bash
set -euo pipefail

if [[ "$ACCEPT_EULA" != Y ]]; then
    echo "Error: Set sqlServerAcceptEula to Y only after accepting the SQL Server license terms." >&2
    exit 1
fi

sqlcmd=/opt/mssql-tools18/bin/sqlcmd
umask 077
sql_file=$(mktemp)
server_pid=
cleanup() {
    rm -f "$sql_file"
    if [[ -n "$server_pid" ]]; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Pass values as SQL string literals, never as sqlcmd variables or identifiers.
database=$(printf '%s' "$RADIUS_DATABASE" | sed "s/'/''/g")
username=$(printf '%s' "$RADIUS_USERNAME" | sed "s/'/''/g")
password=$(printf '%s' "$MSSQL_SA_PASSWORD" | sed "s/'/''/g")
cat > "$sql_file" <<SQL
SET NOCOUNT ON;
DECLARE @database nvarchar(max) = N'$database';
DECLARE @username nvarchar(max) = N'$username';
DECLARE @password nvarchar(max) = N'$password';
IF DATALENGTH(@database) = 0 OR DATALENGTH(@database) > 256
   OR LOWER(@database) IN (N'master', N'model', N'msdb', N'tempdb')
    THROW 50000, 'Use a non-system database name of 1 to 128 characters.', 1;
IF DATALENGTH(@username) = 0 OR DATALENGTH(@username) > 256
    THROW 50000, 'Use a login name of 1 to 128 characters.', 1;
IF DATALENGTH(@password) = 0 OR DATALENGTH(@password) > 256
    THROW 50000, 'Use a password of 1 to 128 characters that meets SQL Server policy.', 1;
DECLARE @sql nvarchar(max);
IF DB_ID(@database) IS NULL
BEGIN
    SET @sql = N'CREATE DATABASE ' + QUOTENAME(@database);
    EXEC (@sql);
END;
IF LOWER(@username) <> N'sa'
BEGIN
    IF SUSER_ID(@username) IS NULL
    BEGIN
        SET @sql = N'CREATE LOGIN ' + QUOTENAME(@username) + N' WITH PASSWORD = '
            + QUOTENAME(@password, '''') + N', CHECK_POLICY = ON';
        EXEC (@sql);
    END;
    SET @sql = N'ALTER SERVER ROLE sysadmin ADD MEMBER ' + QUOTENAME(@username);
    IF IS_SRVROLEMEMBER(N'sysadmin', @username) <> 1 EXEC (@sql);
END;
SET @sql = N'ALTER LOGIN ' + QUOTENAME(@username) + N' WITH DEFAULT_DATABASE = ' + QUOTENAME(@database);
EXEC (@sql);
SQL

/opt/mssql/bin/sqlservr &
server_pid=$!
ready=false
for ((attempt = 0; attempt < 120; attempt++)); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "Error: SQL Server stopped before database setup." >&2
        exit 1
    fi
    if SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$sqlcmd" -S tcp:127.0.0.1,1433 -U sa -C -x -b -l 3 -t 3 -Q 'SELECT 1' >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 2
done
if [[ "$ready" != true ]]; then
    echo "Error: SQL Server did not become ready; check the server log and stored credentials." >&2
    exit 1
fi
if ! SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$sqlcmd" -S tcp:127.0.0.1,1433 -U sa -C -x -b -l 5 -t 120 -i "$sql_file" >/dev/null 2>&1; then
    echo "Error: SQL Server database/login setup failed; check names, password policy and stored credentials." >&2
    exit 1
fi
rm -f "$sql_file"
if ! SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$sqlcmd" -S tcp:127.0.0.1,1433 -U "$RADIUS_USERNAME" -d "$RADIUS_DATABASE" -C -x -b -l 5 -t 5 -Q 'SELECT 1' >/dev/null 2>&1; then
    echo "Error: The requested SQL Server login cannot query the requested database." >&2
    exit 1
fi
echo "SQL Server database and administrator login are ready."
wait "$server_pid"
