SET SERVEROUTPUT ON
SET LINESIZE 200
SET PAGESIZE 100
SET FEEDBACK ON
SET VERIFY OFF
SET HEADING ON

PROMPT === DATABASE INFORMATION ===
SELECT name AS db_name, log_mode, force_logging FROM v$database;
SELECT instance_name, version FROM v$instance;

PROMPT === SUPPLEMENTAL LOGGING STATUS ===
SELECT supplemental_log_data_min, supplemental_log_data_all,
       supplemental_log_data_ui, supplemental_log_data_fk,
       supplemental_log_data_pk, supplemental_log_data_pl
  FROM v$database;

PROMPT === GOLDENGATE PARAMETER ===
SHOW PARAMETER enable_goldengate_replication;

PROMPT === REDO LOG AND ARCHIVE DESTINATIONS ===
SELECT group#, thread#, sequence#, status, archived FROM v$log;
SELECT destination, status, error FROM v$archive_dest WHERE status != 'INACTIVE';

PROMPT === CAPTURE PROCESS (Extract) STATUS ===
SELECT capture_name, status, start_scn, capture_type, checkpoint_time
FROM dba_capture;

PROMPT === CAPTURE PROCESS ERROR DETAILS ===
SELECT capture_name, error_message, error_number, restart_scn
FROM dba_capture_prepared_schemas;

PROMPT === APPLY PROCESS (Replicat) STATUS ===
SELECT apply_name, status, checkpoint_scn, checkpoint_time
FROM dba_apply;

PROMPT === APPLY ERROR DETAILS ===
SELECT apply_name, transaction_id, source_database, error_number, error_message
FROM dba_apply_error;

PROMPT === APPLY STATISTICS ===
SELECT apply_name, total_transactions, applied_transactions,
       discarded_transactions, apply_time, latency
  FROM dba_apply_progress;

PROMPT === CAPTURE STATISTICS ===
SET SERVEROUTPUT ON
SET LINESIZE 200
SET PAGESIZE 100
SET FEEDBACK ON
SET VERIFY OFF
SET HEADING ON

PROMPT === DATABASE INFORMATION ===
SELECT name AS db_name, log_mode, force_logging FROM v$database;
SELECT instance_name, version FROM v$instance;

PROMPT === SUPPLEMENTAL LOGGING STATUS ===
SELECT supplemental_log_data_min, supplemental_log_data_all,
       supplemental_log_data_ui, supplemental_log_data_fk,
       supplemental_log_data_pk, supplemental_log_data_pl
  FROM v$database;

PROMPT === GOLDENGATE PARAMETER ===
SHOW PARAMETER enable_goldengate_replication;

PROMPT === REDO LOG AND ARCHIVE DESTINATIONS ===
SELECT group#, thread#, sequence#, status, archived FROM v$log;
SELECT destination, status, error FROM v$archive_dest WHERE status != 'INACTIVE';

PROMPT === CAPTURE PROCESS (Extract) STATUS ===
SELECT capture_name, status, start_scn, capture_type, checkpoint_time
FROM dba_capture;

PROMPT === CAPTURE PROCESS ERROR DETAILS ===
SELECT capture_name, error_message, error_number, restart_scn
FROM dba_capture_prepared_schemas;

PROMPT === APPLY PROCESS (Replicat) STATUS ===
SELECT apply_name, status, checkpoint_scn, checkpoint_time
FROM dba_apply;

PROMPT === APPLY ERROR DETAILS ===
SELECT apply_name, transaction_id, source_database, error_number, error_message
FROM dba_apply_error;

PROMPT === APPLY STATISTICS ===
SELECT apply_name, total_transactions, applied_transactions,
       discarded_transactions, apply_time, latency
  FROM dba_apply_progress;

PROMPT === CAPTURE STATISTICS ===
SELECT capture_name, total_messages_captured, total_lcrs_captured,
       total_messages_enqueued
  FROM dba_capture;

PROMPT === TRAIL FILE QUEUE MONITORING (AQ) ===
SELECT queue_name, queue_table, enqueue_enabled, dequeue_enabled, num_msgs
  FROM dba_queues WHERE owner NOT IN ('SYS', 'SYSTEM');

PROMPT === TABLE SUPPORT CHECK ===
-- Replace below with relevant table
SELECT owner, table_name, logging, temporary, partitioned
  FROM dba_tables
 WHERE owner = 'HR' AND table_name = 'EMPLOYEES';

PROMPT === SUPPLEMENTAL LOGGING ON TABLE ===
-- Replace with actual schema/table
SELECT log_group_name, always, log_group_type
  FROM dba_log_groups
 WHERE owner = 'HR' AND table_name = 'EMPLOYEES';

PROMPT === GGS_USER PRIVILEGES ===
-- Replace GGS_USER with actual GoldenGate OS/DB user
SELECT * FROM dba_sys_privs WHERE grantee = 'GGS_USER';
SELECT * FROM dba_role_privs WHERE grantee = 'GGS_USER';
SELECT * FROM dba_tab_privs WHERE grantee = 'GGS_USER';

PROMPT === UNDO SPACE MONITORING ===
SELECT s.sid, s.serial#, t.used_ublk * TO_NUMBER(p.value)/1024/1024 AS undo_mb
  FROM v$transaction t
  JOIN v$session s ON s.saddr = t.ses_addr
  JOIN v$parameter p ON p.name = 'db_block_size';

PROMPT === PATCH HISTORY ===
SELECT * FROM registry$history ORDER BY action_time DESC;

PROMPT === GOLDENGATE PROCESS WAIT ANALYSIS (Extract/Replicat) ===

PROMPT === INTEGRATED CAPTURE (EXTRACT) WAIT EVENTS ===
SELECT CAPTURE_NAME, TOTAL_WAIT_TIME, WAIT_COUNT, WAIT_TIME_PER_SEC, EVENT
  FROM V$GG_CAPTURE;

PROMPT === APPLY COORDINATOR WAIT EVENTS ===
SELECT APPLY_NAME, EVENT, WAIT_COUNT, TOTAL_WAIT_TIME, WAIT_TIME_PER_SEC
  FROM V$GG_APPLY_COORDINATOR;

PROMPT === APPLY READER WAIT EVENTS ===
SELECT APPLY_NAME, EVENT, WAIT_COUNT, TOTAL_WAIT_TIME, WAIT_TIME_PER_SEC
  FROM V$GG_APPLY_READER;

PROMPT === ACTIVE GG SESSION WAITS (via V$SESSION) ===
SELECT s.sid, s.serial#, s.username, s.program, s.status, s.event, s.wait_class,
       s.seconds_in_wait, s.state
  FROM v$session s
 WHERE s.program LIKE '%goldengate%' OR s.module LIKE '%OGG%';

PROMPT === SYSTEM-WIDE GOLDENGATE WAITS (TOP) ===
SELECT event, total_waits, time_waited, average_wait
  FROM v$system_event
 WHERE event LIKE '%goldengate%'
 ORDER BY time_waited DESC;

PROMPT === END OF GOLDENGATE HEALTH CHECK ===


PROMPT === LAG BETWEEN SOURCE AND TARGET FOR EACH REPLICAT (APPLY) PROCESS ===
SELECT apply_name,
       source_commit_scn,
       apply_time,
       apply_lag,
       (SYSDATE - apply_time) * 86400 AS lag_seconds
  FROM dba_apply_progress
 ORDER BY apply_name;
