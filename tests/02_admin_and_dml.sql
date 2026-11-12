-- 所有者DML演示：INSERT新增、UPDATE修改、DELETE删除；Q4归还借阅1；全部回滚。 / Owner DML demo: INSERT, UPDATE, DELETE; Q4 returns loan1; all changes rolled back.
-- Owner-only exercise. Every demonstration mutation is ROLLED BACK.
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SAVEPOINT dml_demo;
-- INSERT: new unused publisher. UPDATE: edit its label. DELETE: remove it.
INSERT INTO PUBLISHER(publisher_id,publisher_name) VALUES (800,'Demo temporary publisher');
UPDATE PUBLISHER SET publisher_name='Demo corrected publisher' WHERE publisher_id=800;
SELECT publisher_id,publisher_name FROM PUBLISHER WHERE publisher_id=800;
DELETE FROM PUBLISHER WHERE publisher_id=800;
-- Return one currently active loan through the API.
BEGIN circulation_api.return_loan(1,DATE '2026-10-29'); END;
/
SELECT loan_id,copy_id,returned_on FROM LOAN WHERE loan_id=1;
SELECT copy_id,can_lend FROM v_copy_availability WHERE copy_id=1;
ROLLBACK TO dml_demo;
-- Reader can verify loan1 is open again. Never COMMIT this rehearsal.
SELECT loan_id,returned_on FROM LOAN WHERE loan_id=1;

-- 管理员维护示例：只在独立演示 schema运行，修改全部回滚。 / Owner maintenance examples; dedicated demo schema only, all changes roll back.
SET ECHO ON
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SAVEPOINT admin_demo;
-- 新增、修改、删除未被引用的会员。 / Add, edit and delete an unreferenced member.
INSERT INTO LIB_MEMBER(member_id,matric_no,full_name,email,member_type_id,expires_on,status)
VALUES(800,'ADMIN-DEMO','Demo new member','admin_demo@example.invalid',1,DATE '2027-12-31','ACTIVE');
UPDATE LIB_MEMBER SET status='SUSPENDED' WHERE member_id=800;
SELECT member_id,matric_no,status FROM LIB_MEMBER WHERE member_id=800;
DELETE FROM LIB_MEMBER WHERE member_id=800;
-- 维护书目、作者关联与副本。 / Maintain catalog, authorship and copy.
INSERT INTO PUBLISHER VALUES(800,'Demo catalog publisher');
INSERT INTO AUTHOR VALUES(800,'Demo catalog author');
INSERT INTO BOOK_TITLE VALUES(800,NULL,'Demo catalog title',800,2026);
INSERT INTO TITLE_AUTHOR VALUES(800,800);
INSERT INTO BOOK_COPY VALUES(800,'ADMIN-C800',800,'TEST-SHELF','AVAILABLE');
UPDATE BOOK_COPY SET copy_status='REPAIR' WHERE copy_id=800;
SELECT t.title_name,a.author_name,c.barcode,c.copy_status
FROM BOOK_TITLE t JOIN TITLE_AUTHOR ta ON ta.title_id=t.title_id
JOIN AUTHOR a ON a.author_id=ta.author_id JOIN BOOK_COPY c ON c.title_id=t.title_id
WHERE t.title_id=800;
-- 外键要求从子表到父表删除。 / Foreign keys require child-first deletion.
DELETE FROM BOOK_COPY WHERE copy_id=800;
DELETE FROM TITLE_AUTHOR WHERE title_id=800;
DELETE FROM BOOK_TITLE WHERE title_id=800;
DELETE FROM AUTHOR WHERE author_id=800;
DELETE FROM PUBLISHER WHERE publisher_id=800;
-- 按关键字搜索书目。 / Search titles by keyword.
SELECT title_id,title_name,isbn FROM BOOK_TITLE WHERE LOWER(title_name) LIKE '%database%';
ROLLBACK TO admin_demo;
