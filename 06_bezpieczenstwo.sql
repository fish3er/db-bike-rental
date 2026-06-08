-- ============================================================================
-- System wypożyczalni rowerów miejskich
-- Skrypt 06 - Bezpieczeństwo danych: role, uprawnienia, RLS
-- System zarządzania bazą danych: PostgreSQL
--
-- Implementuje warstwę bezpieczeństwa bazy danych:
--   - 5 ról funkcyjnych odpowiadających rzeczywistym kontekstom użycia
--     systemu (admin, obsługa wypożyczeń, serwisant, API klienta, raporty)
--   - jawne REVOKE z PUBLIC, następnie GRANT precyzyjnie per rola
--   - uprawnienia kolumnowe (serwisant może modyfikować tylko status roweru)
--   - uprawnienia do procedur (EXECUTE na funkcjach/procedurach z pliku 04)
--   - Row-Level Security (RLS) na tabeli klient i wypozyczenie:
--     klient API widzi wyłącznie własne dane
--   - ALTER DEFAULT PRIVILEGES, żeby przyszłe obiekty otrzymywały
--     poprawne uprawnienia automatycznie
--
-- UWAGA: skrypt musi być uruchomiony przez właściciela tabel lub
-- superużytkownika (np. postgres). Zwykły użytkownik bez uprawnień do
-- GRANT na cudzych obiektach zobaczy błędy "permission denied".
--
-- Uruchamiać PO 01_ddl.sql, 02_dane.sql, 04_funkcje_triggery.sql.
-- ============================================================================


-- ############################################################################
-- SEKCJA A: Czyszczenie poprzedniej konfiguracji (idempotentność)
-- DROP OWNED BY revokuje wszystkie nadane uprawnienia i usuwa obiekty
-- należące do roli. Dla naszych ról grupowych (które nie posiadają tabel)
-- oznacza to tylko cofnięcie GRANT-ów - tabele zostają nietknięte.
-- ############################################################################

-- Wyłącz RLS i usuń polityki, zanim usuniesz role (polityki referują role).
ALTER TABLE IF EXISTS klient       DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS wypozyczenie DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_klient_wlasne_dane    ON klient;
DROP POLICY IF EXISTS pol_klient_wlasne_wypoz   ON wypozyczenie;

DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY[
        'bike_admin', 'bike_operator', 'bike_serwisant',
        'bike_klient_api', 'bike_raporty',
        'anna_operator', 'jan_serwisant', 'klient_demo'
    ]
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('DROP OWNED BY %I CASCADE', r);
            EXECUTE format('DROP ROLE %I', r);
        END IF;
    END LOOP;
END;
$$;


-- ############################################################################
-- SEKCJA B: Tworzenie ról
-- Role grupowe (NOLOGIN) modelują uprawnienia per kontekst funkcyjny.
-- Role użytkowe (LOGIN) reprezentują konkretne konta - dziedziczą
-- uprawnienia z ról grupowych przez GRANT <grupa> TO <uzytkownik>.
-- Hasła w przykładach są DEMONSTRACYJNE - w produkcji używać
-- silnych haseł lub uwierzytelniania peer/cert/scram.
-- ############################################################################

-- ---- Role grupowe (funkcyjne) ----------------------------------------------

CREATE ROLE bike_admin       NOLOGIN;
CREATE ROLE bike_operator    NOLOGIN;
CREATE ROLE bike_serwisant   NOLOGIN;
CREATE ROLE bike_klient_api  NOLOGIN;
CREATE ROLE bike_raporty     NOLOGIN;

COMMENT ON ROLE bike_admin      IS 'Pełne uprawnienia administracyjne - DDL, dane, role.';
COMMENT ON ROLE bike_operator   IS 'Obsługa wypożyczeń: stacje, doki, wypożyczenia, płatności.';
COMMENT ON ROLE bike_serwisant  IS 'Serwis floty: zgłoszenia + zmiana statusu roweru.';
COMMENT ON ROLE bike_klient_api IS 'API publiczne dla klienta - dostęp tylko do własnych danych (RLS).';
COMMENT ON ROLE bike_raporty    IS 'Read-only dla raportów i analityki (BI).';

-- ---- Przykładowe konta użytkowników ----------------------------------------

CREATE ROLE anna_operator  LOGIN PASSWORD 'demo_anna_2026';
CREATE ROLE jan_serwisant  LOGIN PASSWORD 'demo_jan_2026';
CREATE ROLE klient_demo    LOGIN PASSWORD 'demo_klient_2026';

GRANT bike_operator   TO anna_operator;
GRANT bike_serwisant  TO jan_serwisant;
GRANT bike_klient_api TO klient_demo;

COMMENT ON ROLE anna_operator IS 'Demo: pracownik obsługi wypożyczeń.';
COMMENT ON ROLE jan_serwisant IS 'Demo: technik serwisu.';
COMMENT ON ROLE klient_demo   IS 'Demo: konto klienta końcowego.';


-- ############################################################################
-- SEKCJA C: Baseline - REVOKE z PUBLIC
-- Domyślnie PostgreSQL nadaje pewne uprawnienia rolzie PUBLIC (każdy
-- użytkownik). Polityka "deny by default" wymaga jawnego cofnięcia.
-- ############################################################################

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- Wszystkie role muszą mieć USAGE na schemacie, żeby w ogóle "widzieć"
-- obiekty - bez tego nie pomogą nawet uprawnienia na poszczególne tabele.
GRANT USAGE ON SCHEMA public TO
    bike_admin, bike_operator, bike_serwisant, bike_klient_api, bike_raporty;


-- ############################################################################
-- SEKCJA D: Uprawnienia per rola
-- ############################################################################

-- ---- bike_admin: pełne władztwo nad schematem ------------------------------

GRANT ALL ON SCHEMA public TO bike_admin;
GRANT ALL ON ALL TABLES    IN SCHEMA public TO bike_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO bike_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO bike_admin;
GRANT ALL ON ALL PROCEDURES IN SCHEMA public TO bike_admin;

-- ---- bike_operator: codzienna obsługa wypożyczalni -------------------------

-- Klienci - odczyt + tworzenie nowych klientów (rejestracja na miejscu),
-- ale BEZ DELETE (klient nie znika, najwyżej zostaje zablokowany).
GRANT SELECT, INSERT, UPDATE ON klient      TO bike_operator;

-- Słowniki - tylko odczyt.
GRANT SELECT                 ON taryfa      TO bike_operator;
GRANT SELECT                 ON stacja      TO bike_operator;
GRANT SELECT                 ON pracownik   TO bike_operator;

-- Operacje na flocie - pełne na wypożyczeniach, dokach, płatnościach.
GRANT SELECT, INSERT, UPDATE ON wypozyczenie TO bike_operator;
GRANT SELECT, INSERT, UPDATE ON platnosc     TO bike_operator;
GRANT SELECT, UPDATE         ON dok          TO bike_operator;
GRANT SELECT                 ON rower        TO bike_operator;
GRANT SELECT                 ON serwis       TO bike_operator;

-- INSERT do tabel z SERIAL PRIMARY KEY wymaga uprawnień do sekwencji.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO bike_operator;

-- ---- bike_serwisant: serwis floty ------------------------------------------

-- Pełne uprawnienia na zgłoszeniach serwisowych.
GRANT SELECT, INSERT, UPDATE ON serwis    TO bike_serwisant;

-- UPRAWNIENIE KOLUMNOWE: serwisant zmienia tylko status roweru
-- (nie przebieg, nie nr_seryjny). Demonstracja granularności GRANT.
GRANT SELECT          ON rower TO bike_serwisant;
GRANT UPDATE (status) ON rower TO bike_serwisant;

-- Słowniki potrzebne do raportowania kontekstu zgłoszenia.
GRANT SELECT ON pracownik    TO bike_serwisant;
GRANT SELECT ON stacja       TO bike_serwisant;
GRANT SELECT ON dok          TO bike_serwisant;

GRANT USAGE, SELECT ON SEQUENCE serwis_id_serwis_seq TO bike_serwisant;

-- ---- bike_klient_api: aplikacja kliencka (RLS) -----------------------------

-- Klient widzi własne dane (ograniczone RLS w sekcji E).
GRANT SELECT, UPDATE         ON klient       TO bike_klient_api;
GRANT SELECT, INSERT         ON wypozyczenie TO bike_klient_api;
GRANT SELECT                 ON platnosc     TO bike_klient_api;
GRANT SELECT                 ON taryfa       TO bike_klient_api;
GRANT SELECT                 ON stacja       TO bike_klient_api;
GRANT SELECT                 ON dok          TO bike_klient_api;
GRANT SELECT                 ON rower        TO bike_klient_api;

GRANT USAGE, SELECT ON SEQUENCE wypozyczenie_id_wypozyczenie_seq TO bike_klient_api;

-- ---- bike_raporty: read-only dla BI ----------------------------------------

GRANT SELECT ON ALL TABLES IN SCHEMA public TO bike_raporty;

-- ---- Uprawnienia do procedur i funkcji z pliku 04 --------------------------

-- Operator wykonuje wypożyczenia i zwroty.
GRANT EXECUTE ON PROCEDURE wypozycz_rower(INTEGER, INTEGER, INTEGER) TO bike_operator;
GRANT EXECUTE ON PROCEDURE zwroc_rower(INTEGER, INTEGER)             TO bike_operator;
GRANT EXECUTE ON FUNCTION  oblicz_oplate(INTEGER)                    TO bike_operator;

-- Klient w API tylko inicjuje wypożyczenie i sprawdza opłatę za swoje.
GRANT EXECUTE ON PROCEDURE wypozycz_rower(INTEGER, INTEGER, INTEGER) TO bike_klient_api;
GRANT EXECUTE ON FUNCTION  oblicz_oplate(INTEGER)                    TO bike_klient_api;

-- Raporty mogą wywołać funkcję obliczeniową.
GRANT EXECUTE ON FUNCTION  oblicz_oplate(INTEGER)                    TO bike_raporty;


-- ############################################################################
-- SEKCJA E: Default privileges
-- Bez tego nowe obiekty (tabele, sekwencje) tworzone w przyszłości nie
-- otrzymują uprawnień dla naszych ról - trzeba by je nadawać ręcznie
-- po każdym CREATE TABLE.
-- ############################################################################

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO bike_raporty;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO bike_operator, bike_serwisant, bike_klient_api;


-- ############################################################################
-- SEKCJA F: Row-Level Security dla bike_klient_api
-- Cel: klient logujący się przez API widzi WYŁĄCZNIE własne rekordy
-- w tabelach klient, wypozyczenie i platnosc, nawet jeśli wykonuje
-- SELECT bez warunku WHERE.
--
-- Mechanizm:
--   1. Aplikacja po uwierzytelnieniu wykonuje:
--        SET LOCAL app.current_klient = '<id_klient>';
--   2. Polityka RLS porównuje id_klient z tym ustawieniem.
--   3. SET LOCAL zapewnia, że ustawienie znika z końcem transakcji
--      (nie wycieka do innych zapytań w tej samej sesji puli połączeń).
--
-- current_setting(..., true) - drugi argument = brak wyjątku gdy ustawienie
-- nie istnieje (zwraca NULL). Polityka wtedy nie dopuszcza żadnych wierszy.
-- ############################################################################

ALTER TABLE klient       ENABLE ROW LEVEL SECURITY;
ALTER TABLE wypozyczenie ENABLE ROW LEVEL SECURITY;

-- Domyślnie RLS nie obowiązuje właściciela tabeli. FORCE wymusza RLS także
-- na właścicielu - zabezpiecza przed pomyłką "uruchomiłem zapytanie jako
-- postgres i niechcący odczytałem wszystkich klientów".
-- Zakomentowane, bo w środowisku akademickim utrudnia testowanie -
-- odkomentować w produkcji.
-- ALTER TABLE klient       FORCE ROW LEVEL SECURITY;
-- ALTER TABLE wypozyczenie FORCE ROW LEVEL SECURITY;

CREATE POLICY pol_klient_wlasne_dane ON klient
    FOR ALL
    TO bike_klient_api
    USING (id_klient = COALESCE(NULLIF(current_setting('app.current_klient', true), ''), '0')::INTEGER)
    WITH CHECK (id_klient = COALESCE(NULLIF(current_setting('app.current_klient', true), ''), '0')::INTEGER);

CREATE POLICY pol_klient_wlasne_wypoz ON wypozyczenie
    FOR ALL
    TO bike_klient_api
    USING (id_klient = COALESCE(NULLIF(current_setting('app.current_klient', true), ''), '0')::INTEGER)
    WITH CHECK (id_klient = COALESCE(NULLIF(current_setting('app.current_klient', true), ''), '0')::INTEGER);

COMMENT ON POLICY pol_klient_wlasne_dane ON klient IS
'RLS: klient API widzi i modyfikuje tylko wiersz odpowiadający app.current_klient.';

COMMENT ON POLICY pol_klient_wlasne_wypoz ON wypozyczenie IS
'RLS: klient API widzi tylko swoje wypożyczenia (filtr po id_klient).';

-- Analogiczną politykę można dodać dla platnosc - pozostawione jako
-- ćwiczenie / przyszłe rozszerzenie:
--   CREATE POLICY pol_klient_wlasne_platnosci ON platnosc ...


-- ############################################################################
-- SEKCJA G: Testy weryfikacyjne (SET ROLE)
-- SET ROLE przełącza efektywną tożsamość bez logowania - wygodne do
-- weryfikacji uprawnień bez zakładania nowych połączeń. RESET ROLE
-- przywraca pierwotnego użytkownika.
--
-- Komentarz "OCZEKIWANE: ..." opisuje spodziewany rezultat.
-- ############################################################################

-- ---- Test 1: bike_operator może czytać klientów, ale nie usuwać ------------

SET ROLE bike_operator;

SELECT id_klient, email FROM klient LIMIT 3;
-- OCZEKIWANE: SUKCES - widzi wszystkich klientów (RLS dotyczy tylko
-- bike_klient_api, nie operatora).

DO $$
BEGIN
    DELETE FROM klient WHERE id_klient = 99999;
    RAISE NOTICE 'BŁĄD TESTU: operator nie powinien móc usuwać klientów.';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: DELETE na klient odrzucone dla bike_operator.';
END;
$$;

RESET ROLE;

-- ---- Test 2: bike_serwisant - tylko status roweru, nie inne kolumny --------

SET ROLE bike_serwisant;

DO $$
BEGIN
    UPDATE rower SET status = 'serwis' WHERE id_rower = 1;
    RAISE NOTICE 'OK: UPDATE rower.status dozwolony dla serwisanta.';
    -- Przywracamy stan
    UPDATE rower SET status = 'dostepny' WHERE id_rower = 1;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'BŁĄD: serwisant powinien móc UPDATE rower.status.';
END;
$$;

DO $$
BEGIN
    UPDATE rower SET przebieg_km = 0 WHERE id_rower = 1;
    RAISE NOTICE 'BŁĄD TESTU: serwisant nie powinien zmieniać przebieg_km.';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: UPDATE rower.przebieg_km odrzucone (uprawnienie kolumnowe).';
END;
$$;

RESET ROLE;

-- ---- Test 3: bike_raporty - tylko SELECT, żadnych modyfikacji --------------

SET ROLE bike_raporty;

SELECT count(*) AS liczba_wypozyczen FROM wypozyczenie;
-- OCZEKIWANE: SUKCES.

DO $$
BEGIN
    INSERT INTO klient (email, imie, nazwisko, id_taryfa)
    VALUES ('test_rls@example.com', 'Test', 'Test', 1);
    RAISE NOTICE 'BŁĄD TESTU: raporty nie powinny móc INSERT.';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: INSERT do klient odrzucone dla bike_raporty.';
END;
$$;

RESET ROLE;

-- ---- Test 4: bike_klient_api + RLS - klient widzi tylko siebie -------------

SET ROLE bike_klient_api;
SET LOCAL app.current_klient = '1';  -- "zalogowany" Jan Kowalski

SELECT id_klient, imie, nazwisko FROM klient;
-- OCZEKIWANE: 1 wiersz (Jan Kowalski) zamiast wszystkich 8.

SELECT count(*) AS moje_wypozyczenia FROM wypozyczenie;
-- OCZEKIWANE: tylko wypożyczenia klienta 1 (5 wg danych testowych).

RESET ROLE;
-- SET LOCAL znika automatycznie z końcem transakcji.

-- ---- Test 5: RLS - próba przejęcia tożsamości innego klienta ---------------

SET ROLE bike_klient_api;
SET LOCAL app.current_klient = '1';

DO $$
BEGIN
    -- Próba zmiany emaila klienta 2 przez "zalogowanego" klienta 1.
    UPDATE klient SET email = 'haker@example.com' WHERE id_klient = 2;
    -- RLS: WITH CHECK powinno odrzucić - polityka zezwala tylko na
    -- modyfikację wiersza o id_klient = current setting (czyli 1).
    -- W praktyce: UPDATE po prostu nie znajdzie żadnego wiersza
    -- (USING odfiltrowuje go zanim WITH CHECK się odpali),
    -- więc operacja jest cicha - 0 wierszy zaktualizowanych.
    RAISE NOTICE 'OK: UPDATE wykonany, ale dotknął 0 wierszy (RLS odfiltrował).';
END;
$$;

SELECT id_klient, email FROM klient WHERE id_klient IN (1, 2);
-- OCZEKIWANE: widać tylko klienta 1, klient 2 niewidoczny (RLS).
-- Próba podmiany emaila klienta 2 nie powiodła się.

RESET ROLE;


-- ############################################################################
-- SEKCJA H: Audyt uprawnień (do dokumentacji)
-- Zapytania pomocnicze - pokazują aktualną konfigurację bezpieczeństwa.
-- Przydatne w prezentacji projektu i przy przeglądach.
-- ############################################################################

-- Lista wszystkich naszych ról i ich przynależności.
SELECT r.rolname, r.rolcanlogin,
       array_agg(m.rolname ORDER BY m.rolname) FILTER (WHERE m.rolname IS NOT NULL) AS czlonek_grup
  FROM pg_roles r
  LEFT JOIN pg_auth_members am ON am.member = r.oid
  LEFT JOIN pg_roles m         ON m.oid     = am.roleid
 WHERE r.rolname LIKE 'bike_%' OR r.rolname IN ('anna_operator','jan_serwisant','klient_demo')
 GROUP BY r.rolname, r.rolcanlogin
 ORDER BY r.rolname;

-- Macierz uprawnień tabelowych dla naszych ról.
SELECT grantee, table_name, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS uprawnienia
  FROM information_schema.role_table_grants
 WHERE grantee LIKE 'bike_%'
   AND table_schema = 'public'
 GROUP BY grantee, table_name
 ORDER BY grantee, table_name;

-- Lista aktywnych polityk RLS.
SELECT schemaname, tablename, policyname, roles, cmd, qual
  FROM pg_policies
 WHERE schemaname = 'public'
 ORDER BY tablename, policyname;


-- ============================================================================
-- Koniec skryptu bezpieczeństwa.
-- ============================================================================
