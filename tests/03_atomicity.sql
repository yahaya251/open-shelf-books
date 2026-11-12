-- 故障注入：验证借出已经INSERT后，预约UPDATE失败时仍全部回滚。 / Failure injection verifies rollback after loan INSERT when reservation UPDATE fails.
-- 在全新独立演示 schema另行执行；会临时CREATE/DROP一个触发器。 / Run separately in the dedicated schema; creates/drops a temporary trigger.
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
CREATE OR REPLACE TRIGGER trg_demo_fail_fulfill
 BEFORE UPDATE OF reservation_status ON RESERVATION FOR EACH ROW
BEGIN
 IF :NEW.title_id=950 AND :NEW.reservation_status='FULFILLED' THEN
  RAISE_APPLICATION_ERROR(-20077,'Injected update failure / 注入更新失败');
 END IF;
END;
/
DECLARE v_errors NUMBER; BEGIN
 SELECT COUNT(*) INTO v_errors FROM USER_ERRORS WHERE name='TRG_DEMO_FAIL_FULFILL';
 IF v_errors>0 THEN RAISE_APPLICATION_ERROR(-20998,'Failure trigger did not compile / 故障触发器编译失败'); END IF;
END;
/
SAVEPOINT atomicity_demo;
DECLARE v_id NUMBER; v_error NUMBER:=0; v_count NUMBER; BEGIN
 INSERT INTO MEMBER_TYPE VALUES(950,'Atomicity test',2,7,3);
 INSERT INTO LIB_MEMBER VALUES(950,'TEST950','Atomicity member','test950@example.invalid',950,DATE '2030-12-31','ACTIVE');
 INSERT INTO BOOK_TITLE VALUES(950,NULL,'Atomicity title',NULL,NULL);
 INSERT INTO BOOK_COPY VALUES(950,'TEST-C950',950,'TEST','AVAILABLE');
 INSERT INTO RESERVATION VALUES(950,950,950,DATE '2026-10-28','ACTIVE',NULL);
 BEGIN
  circulation_api.checkout(950,950,1,DATE '2026-10-29',v_id);
 EXCEPTION WHEN OTHERS THEN v_error:=SQLCODE;
 END;
 IF v_error<>-20077 THEN RAISE_APPLICATION_ERROR(-20997,'Expected injected error / 未取得预期故障'); END IF;
 SELECT COUNT(*) INTO v_count FROM LOAN WHERE copy_id=950;
 IF v_count<>0 THEN RAISE_APPLICATION_ERROR(-20996,'Partial loan survived / 错误保留部分借阅'); END IF;
 SELECT COUNT(*) INTO v_count FROM RESERVATION WHERE reservation_id=950 AND reservation_status='ACTIVE';
 IF v_count<>1 THEN RAISE_APPLICATION_ERROR(-20995,'Reservation was not restored / 预约未恢复'); END IF;
 DBMS_OUTPUT.PUT_LINE('PASS: inserted loan rolled back, hold remains active / 通过：借阅插入已回滚，预约仍有效');
END;
/
ROLLBACK TO atomicity_demo;
DROP TRIGGER trg_demo_fail_fulfill;
-- 若失败导致脚本提前退出，请在专用schema运行DROP TRIGGER trg_demo_fail_fulfill后检查原因。 / On early failure, drop temporary trigger manually in the dedicated schema after review.
