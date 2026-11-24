-- ICT371 Advanced Database - Mulungushi University
-- Student: Augustine lukaki (202306775)
-- Question 4: Clinic Appointment Scheduling
-- PostgreSQL / PL/pgSQL

-- The trigger prevents two non-cancelled appointments from occupying the same doctor, date
-- and slot. A partial unique index is an additional strong database-level safeguard.

-- ============================================================
-- 4(a) Tables and seed data
-- The six appointments use valid slots and do not clash.

CREATE TABLE patients (
 patient_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 full_name VARCHAR(120) NOT NULL
);
CREATE TABLE doctors (
 doctor_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 full_name VARCHAR(120) NOT NULL
);
CREATE TABLE appointments (
 appointment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 patient_id BIGINT NOT NULL REFERENCES patients(patient_id),
 doctor_id BIGINT NOT NULL REFERENCES doctors(doctor_id),
 appointment_day DATE NOT NULL,slot_time TIME NOT NULL,
 status VARCHAR(10) NOT NULL CHECK(status IN ('BOOKED','ATTENDED','CANCELLED')),
 CHECK(slot_time IN (TIME '09:00',TIME '10:00',TIME '11:00',TIME '12:00'))
);
CREATE TABLE clinic_summary (
 summary_date DATE PRIMARY KEY,booked_count BIGINT NOT NULL,
 attended_count BIGINT NOT NULL,cancelled_count BIGINT NOT NULL
);
INSERT INTO patients(full_name) VALUES ('Amina'),('Brian'),('Chanda');
INSERT INTO doctors(full_name) VALUES ('Dr Banda'),('Dr Phiri'),('Dr Zulu');
INSERT INTO appointments(patient_id,doctor_id,appointment_day,slot_time,status) VALUES
 (1,1,CURRENT_DATE,TIME '09:00','BOOKED'),
 (2,1,CURRENT_DATE,TIME '10:00','ATTENDED'),
 (3,2,CURRENT_DATE,TIME '09:00','BOOKED'),
 (1,2,CURRENT_DATE,TIME '11:00','CANCELLED'),
 (2,3,CURRENT_DATE,TIME '12:00','BOOKED'),
 (3,3,CURRENT_DATE+1,TIME '09:00','BOOKED');

-- ============================================================
-- 4(b) Daily-load function
-- Counts BOOKED and ATTENDED appointments, excluding CANCELLED.

CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id BIGINT,p_day DATE)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_count BIGINT;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM doctors WHERE doctor_id=p_doctor_id) THEN
  RAISE EXCEPTION 'Unknown doctor';
 END IF;
 SELECT COUNT(*) INTO v_count FROM appointments
 WHERE doctor_id=p_doctor_id AND appointment_day=p_day
 AND status<>'CANCELLED';
 RETURN v_count;
END; $$;

-- ============================================================
-- 4(c) Booking procedure
-- Validates both foreign keys, future/current date and supported slot.

CREATE OR REPLACE PROCEDURE pr_book_appointment(
 p_patient_id BIGINT,p_doctor_id BIGINT,p_day DATE,p_slot TIME
) LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM patients WHERE patient_id=p_patient_id)
 OR NOT EXISTS(SELECT 1 FROM doctors WHERE doctor_id=p_doctor_id) THEN
  RAISE EXCEPTION 'Unknown patient or doctor';
 END IF;
 IF p_day IS NULL OR p_day<CURRENT_DATE THEN RAISE EXCEPTION 'Appointment date is in the past'; END IF;
 IF p_slot NOT IN (TIME '09:00',TIME '10:00',TIME '11:00',TIME '12:00') THEN
  RAISE EXCEPTION 'Unsupported appointment slot';
 END IF;
 INSERT INTO appointments(patient_id,doctor_id,appointment_day,slot_time,status)
 VALUES(p_patient_id,p_doctor_id,p_day,p_slot,'BOOKED');
END; $$;

-- ============================================================
-- 4(d) Clash trigger
-- The query excludes the current row on UPDATE. The partial unique index also protects
-- against concurrent conflicting writes.

CREATE OR REPLACE FUNCTION fn_check_appointment_clash()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.status<>'CANCELLED' AND EXISTS(
   SELECT 1 FROM appointments a
   WHERE a.doctor_id=NEW.doctor_id
      AND a.appointment_day=NEW.appointment_day
      AND a.slot_time=NEW.slot_time
      AND a.status<>'CANCELLED'
      AND a.appointment_id IS DISTINCT FROM NEW.appointment_id
 ) THEN RAISE EXCEPTION 'Doctor already has a non-cancelled appointment in this slot'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments FOR EACH ROW
EXECUTE FUNCTION fn_check_appointment_clash();
CREATE UNIQUE INDEX uq_active_doctor_slot
ON appointments(doctor_id,appointment_day,slot_time)
WHERE status<>'CANCELLED';

-- ============================================================
-- 4(e) Today's appointments view
-- Only today's BOOKED appointments and the requested names/slot are exposed.

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,d.full_name AS doctor_name,a.slot_time
FROM appointments a JOIN patients p USING(patient_id)
JOIN doctors d USING(doctor_id)
WHERE a.appointment_day=CURRENT_DATE AND a.status='BOOKED';

-- ============================================================
-- 4(f) Index
-- This non-unique index supports day and doctor filtering. The partial unique index above
-- serves a different integrity purpose.

CREATE INDEX idx_appointments_day_doctor
ON appointments(appointment_day,doctor_id);
EXPLAIN SELECT appointment_id,slot_time,status FROM appointments
WHERE appointment_day=CURRENT_DATE AND doctor_id=1;

-- ============================================================
-- 4(g) Daily summary and schedule
-- Counts each status and replaces the same date when rerun.

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO clinic_summary(summary_date,booked_count,attended_count,cancelled_count)
 SELECT p_day,
  COUNT(*) FILTER(WHERE status='BOOKED'),
  COUNT(*) FILTER(WHERE status='ATTENDED'),
  COUNT(*) FILTER(WHERE status='CANCELLED')
 FROM appointments WHERE appointment_day=p_day
 ON CONFLICT(summary_date) DO UPDATE SET
 booked_count=EXCLUDED.booked_count,attended_count=EXCLUDED.attended_count,
 cancelled_count=EXCLUDED.cancelled_count;
END; $$;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('daily-clinic-summary','0 1 * * *',
 $$CALL pr_refresh_clinic_summary(CURRENT_DATE-1)$$);
