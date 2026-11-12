-- 借阅业务包：借出、归还、续借、预约、取消；统一加锁，每次调用失败时回滚，成功后由调用方提交。 / Circulation API: checkout, return, renew, reserve, cancel; ordered locks and atomic calls, caller commits.
-- Business mutations use this package, not direct table DML.
-- Each call is atomic via a reserved internal savepoint. Caller COMMITs.
-- Lock order is TITLE, MEMBER, COPY, LOAN. Title lock serializes FIFO/holds.
CREATE OR REPLACE PACKAGE circulation_api AUTHID DEFINER AS
 PROCEDURE checkout(p_copy_id NUMBER,p_member_id NUMBER,p_staff_id NUMBER,
                    p_borrowed_on DATE,p_loan_id OUT NUMBER);
 PROCEDURE return_loan(p_loan_id NUMBER,p_returned_on DATE DEFAULT SYSDATE);
 PROCEDURE renew_loan(p_loan_id NUMBER,p_staff_id NUMBER,p_renewed_on DATE,
                      p_renewal_id OUT NUMBER);
 PROCEDURE reserve_title(p_title_id NUMBER,p_member_id NUMBER,p_reserved_on DATE,
                         p_reservation_id OUT NUMBER);
 PROCEDURE cancel_reservation(p_reservation_id NUMBER,p_member_id NUMBER,p_closed_on DATE);
END circulation_api;
/
CREATE OR REPLACE PACKAGE BODY circulation_api AS
 PROCEDURE valid_date(p_on DATE) IS BEGIN
  IF p_on IS NULL THEN RAISE_APPLICATION_ERROR(-20013,'Event date is required / 必须提供事件时间'); END IF;
 END;
 PROCEDURE lock_title(p_title NUMBER) IS v_id NUMBER; BEGIN
  SELECT title_id INTO v_id FROM BOOK_TITLE WHERE title_id=p_title FOR UPDATE;
 END;
 PROCEDURE lock_member(p_member NUMBER) IS v_id NUMBER; BEGIN
  SELECT member_id INTO v_id FROM LIB_MEMBER WHERE member_id=p_member FOR UPDATE;
 END;
 PROCEDURE eligible_member(p_member NUMBER,p_on DATE,p_limit OUT NUMBER,
                           p_days OUT NUMBER,p_max OUT NUMBER) IS
  v_status LIB_MEMBER.status%TYPE; v_expiry DATE;
 BEGIN
  SELECT m.status,m.expires_on,t.loan_limit,t.loan_days,t.max_renewals
  INTO v_status,v_expiry,p_limit,p_days,p_max
  FROM LIB_MEMBER m JOIN MEMBER_TYPE t ON t.member_type_id=m.member_type_id
  WHERE m.member_id=p_member FOR UPDATE OF m.status;
  IF v_status<>'ACTIVE' OR TRUNC(p_on)>TRUNC(v_expiry) THEN
   RAISE_APPLICATION_ERROR(-20002,'Membership is suspended or expired / 会员已停用或过期');
  END IF;
 END;
 PROCEDURE checkout(p_copy_id NUMBER,p_member_id NUMBER,p_staff_id NUMBER,
                    p_borrowed_on DATE,p_loan_id OUT NUMBER) IS
  v_title NUMBER; v_limit NUMBER; v_days NUMBER; v_max NUMBER; v_count NUMBER;
  v_status BOOK_COPY.copy_status%TYPE; v_hold NUMBER; v_holder NUMBER;
 BEGIN
  SAVEPOINT circulation_call;
  valid_date(p_borrowed_on);
  SELECT title_id INTO v_title FROM BOOK_COPY WHERE copy_id=p_copy_id;
  lock_title(v_title);
  eligible_member(p_member_id,p_borrowed_on,v_limit,v_days,v_max);
  SELECT copy_status INTO v_status FROM BOOK_COPY WHERE copy_id=p_copy_id FOR UPDATE;
  IF v_status<>'AVAILABLE' THEN RAISE_APPLICATION_ERROR(-20003,'Copy is in repair or lost / 副本维修中或遗失'); END IF;
  SELECT COUNT(*) INTO v_count FROM LOAN WHERE copy_id=p_copy_id AND returned_on IS NULL;
  IF v_count>0 THEN RAISE_APPLICATION_ERROR(-20004,'Copy already has an active loan / 副本已有未归还借阅'); END IF;
  SELECT COUNT(*) INTO v_count FROM LOAN WHERE member_id=p_member_id AND returned_on IS NULL;
  IF v_count>=v_limit THEN RAISE_APPLICATION_ERROR(-20005,'Member loan quota reached / 已达会员借阅名额上限'); END IF;
  BEGIN
   SELECT reservation_id,member_id INTO v_hold,v_holder FROM
    (SELECT reservation_id,member_id FROM RESERVATION
     WHERE title_id=v_title AND reservation_status='ACTIVE'
     ORDER BY reserved_on,reservation_id) WHERE ROWNUM=1;
  EXCEPTION WHEN NO_DATA_FOUND THEN v_hold:=NULL; v_holder:=NULL; END;
  IF v_hold IS NOT NULL AND v_holder<>p_member_id THEN
   RAISE_APPLICATION_ERROR(-20006,'Earliest active reservation has priority / 最早有效预约者优先');
  END IF;
  IF v_hold IS NOT NULL THEN
   SELECT COUNT(*) INTO v_count FROM RESERVATION
    WHERE reservation_id=v_hold AND reserved_on>p_borrowed_on;
   IF v_count>0 THEN RAISE_APPLICATION_ERROR(-20013,'Checkout precedes reservation / 借出时间早于预约时间'); END IF;
  END IF;
  INSERT INTO LOAN(copy_id,member_id,staff_id,borrowed_on,due_on)
   VALUES(p_copy_id,p_member_id,p_staff_id,p_borrowed_on,p_borrowed_on+v_days)
   RETURNING loan_id INTO p_loan_id;
  IF v_hold IS NOT NULL THEN
   UPDATE RESERVATION SET reservation_status='FULFILLED',closed_on=p_borrowed_on
    WHERE reservation_id=v_hold;
  END IF;
 EXCEPTION WHEN NO_DATA_FOUND THEN
  ROLLBACK TO circulation_call;
  RAISE_APPLICATION_ERROR(-20001,'Copy, title or member does not exist / 副本书目或会员不存在');
 WHEN OTHERS THEN ROLLBACK TO circulation_call; RAISE;
 END;
 PROCEDURE return_loan(p_loan_id NUMBER,p_returned_on DATE DEFAULT SYSDATE) IS
  v_title NUMBER; v_member NUMBER; v_copy NUMBER; v_copy_lock NUMBER;
  v_borrowed DATE; v_returned DATE; v_latest_renewal DATE;
 BEGIN
  SAVEPOINT circulation_call;
  valid_date(p_returned_on);
  SELECT c.title_id,l.member_id,l.copy_id INTO v_title,v_member,v_copy
   FROM LOAN l JOIN BOOK_COPY c ON c.copy_id=l.copy_id WHERE l.loan_id=p_loan_id;
  lock_title(v_title); lock_member(v_member);
  SELECT copy_id INTO v_copy_lock FROM BOOK_COPY WHERE copy_id=v_copy FOR UPDATE;
  SELECT borrowed_on,returned_on INTO v_borrowed,v_returned FROM LOAN
   WHERE loan_id=p_loan_id FOR UPDATE;
  IF v_returned IS NOT NULL THEN RAISE_APPLICATION_ERROR(-20007,'Loan has already been returned / 借阅已归还'); END IF;
  SELECT MAX(renewed_on) INTO v_latest_renewal FROM RENEWAL WHERE loan_id=p_loan_id;
  IF p_returned_on<v_borrowed OR (v_latest_renewal IS NOT NULL AND p_returned_on<v_latest_renewal) THEN
   RAISE_APPLICATION_ERROR(-20013,'Return precedes borrowing or last renewal / 归还时间早于借出或最后续借');
  END IF;
  UPDATE LOAN SET returned_on=p_returned_on WHERE loan_id=p_loan_id;
 EXCEPTION WHEN NO_DATA_FOUND THEN
  ROLLBACK TO circulation_call; RAISE_APPLICATION_ERROR(-20001,'Loan does not exist / 借阅不存在');
 WHEN OTHERS THEN ROLLBACK TO circulation_call; RAISE;
 END;
 PROCEDURE renew_loan(p_loan_id NUMBER,p_staff_id NUMBER,p_renewed_on DATE,
                      p_renewal_id OUT NUMBER) IS
  v_title NUMBER; v_member NUMBER; v_copy NUMBER; v_copy_lock NUMBER;
  v_limit NUMBER; v_days NUMBER; v_max NUMBER; v_count NUMBER;
  v_due DATE; v_returned DATE; v_borrowed DATE; v_last DATE;
 BEGIN
  SAVEPOINT circulation_call;
  valid_date(p_renewed_on);
  SELECT c.title_id,l.member_id,l.copy_id INTO v_title,v_member,v_copy
   FROM LOAN l JOIN BOOK_COPY c ON c.copy_id=l.copy_id WHERE l.loan_id=p_loan_id;
  lock_title(v_title);
  eligible_member(v_member,p_renewed_on,v_limit,v_days,v_max);
  SELECT copy_id INTO v_copy_lock FROM BOOK_COPY WHERE copy_id=v_copy FOR UPDATE;
  SELECT due_on,returned_on,borrowed_on INTO v_due,v_returned,v_borrowed FROM LOAN
   WHERE loan_id=p_loan_id FOR UPDATE;
  IF v_returned IS NOT NULL THEN RAISE_APPLICATION_ERROR(-20007,'Returned loan cannot be renewed / 已归还借阅不可续借'); END IF;
  SELECT MAX(renewed_on) INTO v_last FROM RENEWAL WHERE loan_id=p_loan_id;
  IF p_renewed_on<v_borrowed OR (v_last IS NOT NULL AND p_renewed_on<v_last) THEN
   RAISE_APPLICATION_ERROR(-20013,'Renewal date precedes earlier loan event / 续借时间早于先前事件');
  END IF;
  IF p_renewed_on>v_due THEN RAISE_APPLICATION_ERROR(-20008,'Overdue loan cannot be renewed / 逾期借阅不可续借'); END IF;
  SELECT COUNT(*) INTO v_count FROM RENEWAL WHERE loan_id=p_loan_id;
  IF v_count>=v_max THEN RAISE_APPLICATION_ERROR(-20009,'Renewal limit reached / 已达续借次数上限'); END IF;
  SELECT COUNT(*) INTO v_count FROM RESERVATION WHERE title_id=v_title
   AND reservation_status='ACTIVE' AND member_id<>v_member;
  IF v_count>0 THEN RAISE_APPLICATION_ERROR(-20010,'Another member has reserved this title / 另一会员已预约此书目'); END IF;
  INSERT INTO RENEWAL(loan_id,staff_id,renewed_on,previous_due_on,new_due_on)
   VALUES(p_loan_id,p_staff_id,p_renewed_on,v_due,v_due+v_days)
   RETURNING renewal_id INTO p_renewal_id;
  UPDATE LOAN SET due_on=v_due+v_days WHERE loan_id=p_loan_id;
 EXCEPTION WHEN NO_DATA_FOUND THEN
  ROLLBACK TO circulation_call; RAISE_APPLICATION_ERROR(-20001,'Loan or member does not exist / 借阅或会员不存在');
 WHEN OTHERS THEN ROLLBACK TO circulation_call; RAISE;
 END;
 PROCEDURE reserve_title(p_title_id NUMBER,p_member_id NUMBER,p_reserved_on DATE,
                         p_reservation_id OUT NUMBER) IS
  v_limit NUMBER; v_days NUMBER; v_max NUMBER; v_count NUMBER;
 BEGIN
  SAVEPOINT circulation_call;
  valid_date(p_reserved_on); lock_title(p_title_id);
  eligible_member(p_member_id,p_reserved_on,v_limit,v_days,v_max);
  SELECT COUNT(*) INTO v_count FROM RESERVATION WHERE title_id=p_title_id
   AND member_id=p_member_id AND reservation_status='ACTIVE';
  IF v_count>0 THEN RAISE_APPLICATION_ERROR(-20011,'Member already has an active reservation / 会员已有该书目有效预约'); END IF;
  SELECT COUNT(*) INTO v_count FROM v_copy_availability WHERE title_id=p_title_id AND can_lend='YES';
  IF v_count>0 THEN RAISE_APPLICATION_ERROR(-20014,'A lendable copy is available; borrow it directly / 有可借副本应直接借阅'); END IF;
  INSERT INTO RESERVATION(title_id,member_id,reserved_on,reservation_status)
   VALUES(p_title_id,p_member_id,p_reserved_on,'ACTIVE')
   RETURNING reservation_id INTO p_reservation_id;
 EXCEPTION WHEN NO_DATA_FOUND THEN
  ROLLBACK TO circulation_call; RAISE_APPLICATION_ERROR(-20001,'Title or member does not exist / 书目或会员不存在');
 WHEN OTHERS THEN ROLLBACK TO circulation_call; RAISE;
 END;
 PROCEDURE cancel_reservation(p_reservation_id NUMBER,p_member_id NUMBER,p_closed_on DATE) IS
  v_title NUMBER; v_reserved DATE; v_status RESERVATION.reservation_status%TYPE;
  v_member NUMBER;
 BEGIN
  SAVEPOINT circulation_call;
  valid_date(p_closed_on);
  SELECT title_id INTO v_title FROM RESERVATION WHERE reservation_id=p_reservation_id;
  lock_title(v_title); lock_member(p_member_id);
  SELECT member_id,reservation_status,reserved_on INTO v_member,v_status,v_reserved
   FROM RESERVATION WHERE reservation_id=p_reservation_id FOR UPDATE;
  IF v_member<>p_member_id OR v_status<>'ACTIVE' THEN
   RAISE_APPLICATION_ERROR(-20012,'No active reservation belonging to this member / 没有属于此会员的有效预约');
  END IF;
  IF p_closed_on<v_reserved THEN RAISE_APPLICATION_ERROR(-20013,'Cancellation precedes reservation / 取消时间早于预约'); END IF;
  UPDATE RESERVATION SET reservation_status='CANCELLED',closed_on=p_closed_on
   WHERE reservation_id=p_reservation_id;
 EXCEPTION WHEN NO_DATA_FOUND THEN
  ROLLBACK TO circulation_call; RAISE_APPLICATION_ERROR(-20001,'Reservation or member does not exist / 预约或会员不存在');
 WHEN OTHERS THEN ROLLBACK TO circulation_call; RAISE;
 END;
END circulation_api;
/
SHOW ERRORS PACKAGE circulation_api
SHOW ERRORS PACKAGE BODY circulation_api
-- SHOW ERRORS alone does not fail SQL*Plus: explicitly assert compilation.
DECLARE v_count NUMBER; BEGIN
 SELECT COUNT(*) INTO v_count FROM USER_ERRORS WHERE name='CIRCULATION_API';
 IF v_count>0 THEN RAISE_APPLICATION_ERROR(-20990,'Package compilation failed; inspect USER_ERRORS / 包编译失败请检查USER_ERRORS'); END IF;
END;
/
