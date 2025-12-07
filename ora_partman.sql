SET SERVEROUTPUT ON SIZE UNLIMITED;
SET ECHO ON;

PROMPT =========================================================
PROMPT STAGE 1: ENVIRONMENT SETUP
PROMPT Creating Metadata Tables and Package
PROMPT =========================================================

-- 1. Cleanup previous runs (optional, for idempotency)
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE part_man_log PURGE';
    EXECUTE IMMEDIATE 'DROP TABLE part_man_config PURGE';
    EXECUTE IMMEDIATE 'DROP TABLE test_sales PURGE';
    EXECUTE IMMEDIATE 'DROP TABLE test_child_orphan PURGE';
    EXECUTE IMMEDIATE 'DROP TABLE test_parent_orphan PURGE';
    EXECUTE IMMEDIATE 'DROP TABLE test_child_ok PURGE';
    EXECUTE IMMEDIATE 'DROP TABLE test_parent_ok PURGE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

-- 2. Create Config Table
CREATE TABLE part_man_config (
    table_owner     VARCHAR2(128) NOT NULL,
    table_name      VARCHAR2(128) NOT NULL,
    retention_days  NUMBER NOT NULL,
    is_active       VARCHAR2(1) DEFAULT 'Y',
    partition_type  VARCHAR2(10) DEFAULT 'DAILY',
    created_at      TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_part_man PRIMARY KEY (table_owner, table_name)
);

-- 3. Create Log Table
CREATE TABLE part_man_log (
    log_id          NUMBER GENERATED ALWAYS AS IDENTITY,
    log_date        TIMESTAMP DEFAULT SYSTIMESTAMP,
    table_name      VARCHAR2(128),
    partition_name  VARCHAR2(128),
    message         VARCHAR2(4000),
    status          VARCHAR2(20)
);

-- 4. Compile the Package (Paste the package logic from previous step)
CREATE OR REPLACE PACKAGE pkg_ora_partman AS
    PROCEDURE run_maintenance;
    PROCEDURE run_rename;
    PROCEDURE run_retention;
    FUNCTION validate_children(p_owner VARCHAR2, p_table VARCHAR2) RETURN BOOLEAN;
END pkg_ora_partman;
/

CREATE OR REPLACE PACKAGE BODY pkg_ora_partman AS

    -------------------------------------------------------------------------
    -- 1. UTILITY: Get High Value
    -------------------------------------------------------------------------
    FUNCTION get_part_high_value(p_owner VARCHAR2, p_table VARCHAR2, p_part VARCHAR2) RETURN DATE IS
        v_high_value_clob CLOB;
        v_high_value_str  VARCHAR2(1000);
        v_date            DATE;
    BEGIN
        SELECT xmlquery('//HIGH_VALUE/text()' PASSING 
               dbms_xmlgen.getxmltype('SELECT high_value FROM all_tab_partitions WHERE table_owner = ''' || p_owner || ''' AND table_name = ''' || p_table || ''' AND partition_name = ''' || p_part || '''')
               RETURNING CONTENT).getStringVal()
        INTO v_high_value_clob FROM dual;

        v_high_value_str := DBMS_LOB.SUBSTR(v_high_value_clob, 1000, 1);
        IF v_high_value_str LIKE '%MAXVALUE%' THEN RETURN NULL; END IF;
        EXECUTE IMMEDIATE 'BEGIN :1 := ' || v_high_value_str || '; END;' USING OUT v_date;
        RETURN v_date;
    EXCEPTION WHEN OTHERS THEN RETURN NULL;
    END;

    -------------------------------------------------------------------------
    -- 2. SAFETY CHECK: Validate Child Tables
    -------------------------------------------------------------------------
    FUNCTION validate_children(p_owner VARCHAR2, p_table VARCHAR2) RETURN BOOLEAN IS
        v_missing_count NUMBER := 0;
    BEGIN
        SELECT COUNT(*) INTO v_missing_count
        FROM all_constraints child
        JOIN all_constraints parent ON child.r_constraint_name = parent.constraint_name AND child.r_owner = parent.owner
        WHERE parent.owner = p_owner AND parent.table_name = p_table
          AND parent.constraint_type IN ('P', 'U') AND child.constraint_type = 'R'
          AND NOT EXISTS (SELECT 1 FROM part_man_config c WHERE c.table_owner = child.owner AND c.table_name = child.table_name AND c.is_active = 'Y');
        
        IF v_missing_count > 0 THEN
            INSERT INTO part_man_log (table_name, message, status) VALUES (p_table, 'ABORT: Found ' || v_missing_count || ' unregistered child tables.', 'WARNING');
            COMMIT;
            RETURN FALSE;
        END IF;
        RETURN TRUE;
    END;

    -------------------------------------------------------------------------
    -- 3. RENAME: Make names readable
    -------------------------------------------------------------------------
    PROCEDURE run_rename IS
        v_high_date DATE;
        v_new_name  VARCHAR2(128);
        v_msg       VARCHAR2(4000); -- Variable to hold error messages
    BEGIN
        FOR t IN (SELECT * FROM part_man_config WHERE is_active = 'Y') LOOP
            FOR p IN (SELECT partition_name FROM all_tab_partitions WHERE table_owner = t.table_owner AND table_name = t.table_name AND partition_name LIKE 'SYS_P%') LOOP
                v_high_date := get_part_high_value(t.table_owner, t.table_name, p.partition_name);
                IF v_high_date IS NOT NULL THEN
                    IF t.partition_type = 'DAILY' THEN v_new_name := 'P_' || TO_CHAR(v_high_date - 1, 'YYYYMMDD');
                    ELSIF t.partition_type = 'MONTHLY' THEN v_new_name := 'P_' || TO_CHAR(ADD_MONTHS(v_high_date, -1), 'YYYYMM'); END IF;
                    BEGIN
                        EXECUTE IMMEDIATE 'ALTER TABLE ' || t.table_owner || '.' || t.table_name || ' RENAME PARTITION ' || p.partition_name || ' TO ' || v_new_name;
                        INSERT INTO part_man_log (table_name, partition_name, message, status) VALUES (t.table_name, v_new_name, 'Renamed from ' || p.partition_name, 'SUCCESS');
                    EXCEPTION WHEN OTHERS THEN 
                        -- Optional: Log rename failures if needed, but usually ignored for "name taken"
                        NULL;
                    END;
                END IF;
            END LOOP;
        END LOOP;
    END;

    -------------------------------------------------------------------------
    -- 4. RETENTION: Drop Old Partitions
    -------------------------------------------------------------------------
    PROCEDURE run_retention IS
        v_retention_date DATE;
        v_high_date      DATE;
        v_msg            VARCHAR2(4000); -- FIX: Variable defined here
    BEGIN
        FOR t IN (SELECT * FROM part_man_config WHERE is_active = 'Y') LOOP
            IF NOT validate_children(t.table_owner, t.table_name) THEN CONTINUE; END IF;
            
            v_retention_date := TRUNC(SYSDATE) - t.retention_days;
            
            FOR p IN (SELECT partition_name FROM all_tab_partitions WHERE table_owner = t.table_owner AND table_name = t.table_name ORDER BY partition_position) LOOP
                v_high_date := get_part_high_value(t.table_owner, t.table_name, p.partition_name);
                
                IF v_high_date IS NOT NULL AND v_high_date < v_retention_date THEN
                    BEGIN
                        EXECUTE IMMEDIATE 'ALTER TABLE ' || t.table_owner || '.' || t.table_name || ' DROP PARTITION ' || p.partition_name || ' UPDATE INDEXES';
                        INSERT INTO part_man_log (table_name, partition_name, message, status) VALUES (t.table_name, p.partition_name, 'Dropped successfully', 'SUCCESS');
                    EXCEPTION WHEN OTHERS THEN
                        -- FIX: Assign SQLERRM to variable before INSERT
                        v_msg := SUBSTR(SQLERRM, 1, 3900); 
                        INSERT INTO part_man_log (table_name, partition_name, message, status) VALUES (t.table_name, p.partition_name, v_msg, 'ERROR');
                    END;
                END IF;
            END LOOP;
            COMMIT;
        END LOOP;
    END;

    PROCEDURE run_maintenance IS
    BEGIN
        run_rename;
        run_retention;
    END;
END pkg_ora_partman;
/

