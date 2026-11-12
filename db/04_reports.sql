-- Q1活跃/逾期；Q2 COUNT/SUM借阅统计；Q3嵌套查询未满足需求；附可借性与续借历史。 / Q1 active/overdue; Q2 COUNT/SUM popularity; Q3 nested unmet demand; availability/history.
-- Q1: CURRENT outstanding loans; evaluate overdue days at fixed demo date.
-- 当前未归还记录，以固定演示日计算逾期天数；不重建历史时点。
-- v_active_loans uses SYSDATE. Q1 does not reconstruct historical outstanding state.
SELECT l.loan_id,m.matric_no,t.title_name,c.barcode,l.due_on,
       GREATEST(DATE '2026-10-29'-TRUNC(l.due_on),0) AS days_overdue
FROM LOAN l JOIN LIB_MEMBER m ON m.member_id=l.member_id
JOIN BOOK_COPY c ON c.copy_id=l.copy_id JOIN BOOK_TITLE t ON t.title_id=c.title_id
WHERE l.returned_on IS NULL ORDER BY l.due_on,l.loan_id;
-- Q2: title demand, including titles with zero loans. Avoid fan-out.
SELECT t.title_id,t.title_name,COUNT(l.loan_id) AS total_loans,
       SUM(CASE WHEN l.loan_id IS NOT NULL AND l.returned_on IS NULL THEN 1 ELSE 0 END) AS active_loans
FROM BOOK_TITLE t LEFT JOIN BOOK_COPY c ON c.title_id=t.title_id
LEFT JOIN LOAN l ON l.copy_id=c.copy_id
GROUP BY t.title_id,t.title_name ORDER BY total_loans DESC,t.title_id;
-- Q3: unfulfilled demand using a nested NOT EXISTS availability query.
SELECT t.title_id,t.title_name,COUNT(*) AS waiting_members
FROM RESERVATION r JOIN BOOK_TITLE t ON t.title_id=r.title_id
WHERE r.reservation_status='ACTIVE' AND NOT EXISTS
 (SELECT 1 FROM BOOK_COPY c WHERE c.title_id=t.title_id AND c.copy_status='AVAILABLE'
  AND NOT EXISTS (SELECT 1 FROM LOAN l WHERE l.copy_id=c.copy_id AND l.returned_on IS NULL))
GROUP BY t.title_id,t.title_name ORDER BY waiting_members DESC,t.title_id;
-- copies currently lendable, derived from status and active loans.
SELECT t.title_name,c.barcode,c.shelf_code FROM v_copy_availability c
JOIN BOOK_TITLE t ON t.title_id=c.title_id WHERE c.can_lend='YES' ORDER BY t.title_id,c.copy_id;
-- renewal history with the responsible staff member.
SELECT r.renewal_id,r.loan_id,s.staff_name,r.renewed_on,r.previous_due_on,r.new_due_on
FROM RENEWAL r JOIN STAFF s ON s.staff_id=r.staff_id ORDER BY r.renewal_id;
