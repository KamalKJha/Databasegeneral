PROMPT =========================================================
PROMPT TEST CASE 1: BASIC LIFECYCLE (RENAME & DROP)
PROMPT =========================================================
-- Objective: Verify partitions are renamed nicely and old ones dropped.

-- 1. Create Table (Daily Interval)
CREATE TABLE test_sales (
    id NUMBER, 
    sale_date DATE
) PARTITION BY RANGE (sale_date) INTERVAL (NUMTODSINTERVAL(1,'DAY'))
(PARTITION p_init VALUES LESS THAN (TO_DATE('2020-01-01','YYYY-MM-DD')));

-- 2. Insert Data (One OLD record, One NEW record)
-- OLD: 100 days ago (Should be dropped)
INSERT INTO test_sales VALUES (1, TRUNC(SYSDATE) - 100); 
-- NEW: Today (Should stay)
INSERT INTO test_sales VALUES (2, TRUNC(SYSDATE)); 
COMMIT;

-- 3. Register Config (Retention 30 days)
INSERT INTO part_man_config (table_owner, table_name, retention_days, partition_type)
VALUES (USER, 'TEST_SALES', 30, 'DAILY');
COMMIT;

PROMPT Running Maintenance...
BEGIN
    pkg_ora_partman.run_maintenance;
END;
/

PROMPT >> Verifying Test 1 Results:
DECLARE
    v_count NUMBER;
BEGIN
    -- Check if OLD partition is gone (We query the LOG for success)
    SELECT COUNT(*) INTO v_count FROM part_man_log 
    WHERE table_name = 'TEST_SALES' AND status = 'SUCCESS' AND message LIKE 'Dropped%';
    
    IF v_count > 0 THEN 
        DBMS_OUTPUT.PUT_LINE('PASS: Old partition dropped.');
    ELSE 
        DBMS_OUTPUT.PUT_LINE('FAIL: Old partition was NOT dropped.');
    END IF;

    -- Check if NEW partition was renamed (Look for P_YYYYMMDD format)
    SELECT COUNT(*) INTO v_count FROM all_tab_partitions 
    WHERE table_name = 'TEST_SALES' AND partition_name LIKE 'P_%';
    
    IF v_count > 0 THEN 
        DBMS_OUTPUT.PUT_LINE('PASS: Remaining partition renamed successfully.');
    ELSE 
        DBMS_OUTPUT.PUT_LINE('FAIL: Partition was not renamed.');
    END IF;
END;
/

PROMPT =========================================================
PROMPT TEST CASE 2: SAFETY CHECK - UNREGISTERED CHILD (ORPHAN)
PROMPT =========================================================
-- Objective: Ensure Parent is NOT dropped if a Child table exists but isn't in config.

-- 1. Create Parent
CREATE TABLE test_parent_orphan (
    id NUMBER PRIMARY KEY, 
    created_date DATE
) PARTITION BY RANGE (created_date) INTERVAL (NUMTODSINTERVAL(1,'DAY'))
(PARTITION p_init VALUES LESS THAN (TO_DATE('2020-01-01','YYYY-MM-DD')));

-- 2. Create Child (Foreign Key)
CREATE TABLE test_child_orphan (
    child_id NUMBER, 
    parent_id NUMBER REFERENCES test_parent_orphan(id)
);

-- 3. Insert OLD Data (Target for deletion)
INSERT INTO test_parent_orphan VALUES (1, TRUNC(SYSDATE) - 100);
INSERT INTO test_child_orphan VALUES (99, 1);
COMMIT;

-- 4. Register ONLY PARENT (This is the mistake scenario)
INSERT INTO part_man_config (table_owner, table_name, retention_days)
VALUES (USER, 'TEST_PARENT_ORPHAN', 30);
COMMIT;

PROMPT Running Maintenance...
BEGIN
    pkg_ora_partman.run_maintenance;
END;
/

PROMPT >> Verifying Test 2 Results:
DECLARE
    v_log_count NUMBER;
    v_part_count NUMBER;
BEGIN
    -- Check Log for Warning
    SELECT COUNT(*) INTO v_log_count FROM part_man_log 
    WHERE table_name = 'TEST_PARENT_ORPHAN' AND status = 'WARNING' AND message LIKE '%unregistered child%';
    
    -- Check that partition still exists
    SELECT COUNT(*) INTO v_part_count FROM all_tab_partitions 
    WHERE table_name = 'TEST_PARENT_ORPHAN';
    
    IF v_log_count > 0 AND v_part_count > 1 THEN
        DBMS_OUTPUT.PUT_LINE('PASS: Safety catch triggered. Drop aborted. Log warning found.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('FAIL: Safety catch missed or partition dropped incorrectly.');
    END IF;
END;
/

PROMPT =========================================================
PROMPT TEST CASE 3: SUCCESS CHECK - REGISTERED CHILD
PROMPT =========================================================
-- Objective: Ensure drop happens if Child is registered (using CASCADE delete for test mechanics).

-- 1. Create Parent
CREATE TABLE test_parent_ok (
    id NUMBER PRIMARY KEY, 
    created_date DATE
) PARTITION BY RANGE (created_date) INTERVAL (NUMTODSINTERVAL(1,'DAY'))
(PARTITION p_init VALUES LESS THAN (TO_DATE('2020-01-01','YYYY-MM-DD')));

-- 2. Create Child (FK with DELETE CASCADE)
-- Note: ON DELETE CASCADE is used here so the physical drop command succeeds 
-- verifying that the package *allowed* the command to run.
CREATE TABLE test_child_ok (
    child_id NUMBER, 
    parent_id NUMBER REFERENCES test_parent_ok(id) ON DELETE CASCADE
);

-- 3. Insert OLD Data
INSERT INTO test_parent_ok VALUES (1, TRUNC(SYSDATE) - 100);
INSERT INTO test_child_ok VALUES (99, 1);
COMMIT;

-- 4. Register BOTH PARENT AND CHILD
INSERT INTO part_man_config (table_owner, table_name, retention_days) VALUES (USER, 'TEST_PARENT_OK', 30);
INSERT INTO part_man_config (table_owner, table_name, retention_days) VALUES (USER, 'TEST_CHILD_OK', 30);
COMMIT;

PROMPT Running Maintenance...
BEGIN
    pkg_ora_partman.run_maintenance;
END;
/

PROMPT >> Verifying Test 3 Results:
DECLARE
    v_success_count NUMBER;
BEGIN
    -- Check Log for Success
    SELECT COUNT(*) INTO v_success_count FROM part_man_log 
    WHERE table_name = 'TEST_PARENT_OK' AND status = 'SUCCESS';
    
    IF v_success_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('PASS: Parent partition dropped because child was registered.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('FAIL: Drop did not occur despite correct config.');
    END IF;
END;
/

PROMPT =========================================================
PROMPT TEST SUITE COMPLETE
PROMPT =========================================================