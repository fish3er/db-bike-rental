-- ============================================================================
-- System wypożyczalni rowerów miejskich
-- Skrypt 05 - Transakcje i poziomy izolacji
-- System zarządzania bazą danych: PostgreSQL
--
-- Demonstruje mechanizmy transakcyjne PostgreSQL:
--   - jawne sterowanie transakcją (BEGIN / COMMIT / ROLLBACK)
--   - punkty zachowawcze (SAVEPOINT, ROLLBACK TO SAVEPOINT)
--   - poziomy izolacji (READ COMMITTED, REPEATABLE READ, SERIALIZABLE)
--   - blokady pessymistyczne (SELECT ... FOR UPDATE)
--   - bloki EXCEPTION w PL/pgSQL (niejawne savepointy)
--
-- Część scenariuszy (2, 3, 4) demonstruje ANOMALIE przy zbyt słabym
-- poziomie izolacji oraz ich rozwiązanie. Te scenariusze wymagają DWÓCH
-- równoległych sesji psql (oznaczonych jako -- SESJA A i -- SESJA B);
-- kolejność wykonania krok po kroku (1A, 2B, 3A, ...) zaznaczona w
-- komentarzach.
--
-- UWAGA: PostgreSQL nie implementuje READ UNCOMMITTED - traktuje go po
-- cichu jak READ COMMITTED (dirty reads nie są możliwe w żadnym poziomie).
-- Domyślnym poziomem dla nowej transakcji jest READ COMMITTED.
--
-- Uruchamiać PO 01_ddl.sql, 02_dane.sql, 04_funkcje_triggery.sql.
-- Skrypty wykonywalne bezpośrednio (sekcja 1) NIE modyfikują stanu
-- trwale - kończą się ROLLBACK lub przywracają wartości.
-- ============================================================================


-- ############################################################################
-- SEKCJA 1: Podstawowe konstrukcje transakcyjne (jedna sesja, runnable)
-- ############################################################################

-- ----------------------------------------------------------------------------
-- Przykład 1.1: Jawna transakcja z ROLLBACK
-- Pracownik zaczyna aktualizację przebiegu, ale orientuje się, że pomylił
-- rower. ROLLBACK przywraca stan sprzed BEGIN.
-- ----------------------------------------------------------------------------

-- Stan wyjściowy:
SELECT id_rower, nr_seryjny, przebieg_km FROM rower WHERE id_rower = 1;

BEGIN;
    UPDATE rower SET przebieg_km = przebieg_km + 999 WHERE id_rower = 1;

    -- Wewnątrz transakcji zmiana widoczna (own writes):
    SELECT id_rower, nr_seryjny, przebieg_km FROM rower WHERE id_rower = 1;
ROLLBACK;

-- Po ROLLBACK przebieg wrócił do stanu sprzed BEGIN:
SELECT id_rower, nr_seryjny, przebieg_km FROM rower WHERE id_rower = 1;


-- ----------------------------------------------------------------------------
-- Przykład 1.2: SAVEPOINT i ROLLBACK TO SAVEPOINT
-- Wielokrokowa aktualizacja, w której wycofujemy fragment bez utraty
-- całej transakcji.
-- W zwykłym SQL po błędzie polecenia transakcja przechodzi w stan "aborted"
-- i odrzuca kolejne polecenia, dopóki nie wydamy ROLLBACK (lub ROLLBACK TO
-- jakiegoś wcześniejszego savepointa). Ten przykład pokazuje świadome
-- użycie SAVEPOINT bez wywoływania błędu, by oddzielić logiczne fazy.
-- ----------------------------------------------------------------------------

BEGIN;
    UPDATE rower SET przebieg_km = przebieg_km + 10 WHERE id_rower = 1;

    SAVEPOINT po_kroku_1;

    UPDATE rower SET przebieg_km = przebieg_km + 20 WHERE id_rower = 2;

    -- Decydujemy, że krok 2 jednak nie powinien się wykonać:
    ROLLBACK TO SAVEPOINT po_kroku_1;

    -- Krok 3 idzie dalej - efekt kroku 1 zachowany, krok 2 wycofany.
    UPDATE rower SET przebieg_km = przebieg_km + 30 WHERE id_rower = 3;
COMMIT;

-- Weryfikacja: rower 1 (+10), rower 2 (bez zmian), rower 3 (+30).
SELECT id_rower, nr_seryjny, przebieg_km
  FROM rower WHERE id_rower IN (1, 2, 3) ORDER BY id_rower;

-- Cleanup - cofamy zmiany testowe, żeby plik był idempotentny:
BEGIN;
    UPDATE rower SET przebieg_km = przebieg_km - 10 WHERE id_rower = 1;
    UPDATE rower SET przebieg_km = przebieg_km - 30 WHERE id_rower = 3;
COMMIT;


-- ----------------------------------------------------------------------------
-- Przykład 1.3: Blok EXCEPTION w PL/pgSQL = niejawny SAVEPOINT
-- W PL/pgSQL każdy blok BEGIN...EXCEPTION...END jest pod spodem opakowany
-- w savepoint. Błąd przechwycony w EXCEPTION nie psuje całej transakcji.
-- Praktyczny przykład: batch zamykania długich wypożyczeń (cron).
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    rec      RECORD;
    v_sukces INTEGER := 0;
    v_blad   INTEGER := 0;
BEGIN
    -- Przelatujemy aktywne wypożyczenia trwające ponad 24h
    -- (przykładowy próg "porzuconych" wypożyczeń).
    FOR rec IN
        SELECT id_wypozyczenie, id_stacja_start
          FROM wypozyczenie
         WHERE czas_koniec IS NULL
           AND czas_start  < now() - INTERVAL '24 hours'
    LOOP
        BEGIN
            -- Każda iteracja w niejawnym savepoincie - błąd w jednej
            -- nie psuje pozostałych.
            CALL zwroc_rower(rec.id_wypozyczenie, rec.id_stacja_start);
            v_sukces := v_sukces + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Wypożyczenie %: nie udało się zamknąć (%).',
                rec.id_wypozyczenie, SQLERRM;
            v_blad := v_blad + 1;
        END;
    END LOOP;

    RAISE NOTICE 'Batch zakończony: % zamkniętych, % błędów.', v_sukces, v_blad;
END;
$$;


-- ############################################################################
-- SEKCJA 2: Ustawianie poziomu izolacji
-- Składnia: BEGIN ISOLATION LEVEL ... lub SET TRANSACTION ISOLATION LEVEL ...
-- ############################################################################

-- READ COMMITTED (domyślny w PG):
--   Każde polecenie widzi snapshot zatwierdzony w momencie startu polecenia.
--   Dwa SELECT w jednej transakcji mogą zwrócić różne wyniki (non-repeatable).
BEGIN ISOLATION LEVEL READ COMMITTED;
    SELECT current_setting('transaction_isolation') AS poziom;
COMMIT;

-- REPEATABLE READ:
--   Snapshot ustalany przy pierwszym poleceniu transakcji; wszystkie
--   kolejne SELECT widzą ten sam stan. Chroni przed non-repeatable read
--   i (w PG) przed phantom read na poziomie odczytów - ale NIE przed
--   write skew.
BEGIN ISOLATION LEVEL REPEATABLE READ;
    SELECT current_setting('transaction_isolation') AS poziom;
COMMIT;

-- SERIALIZABLE:
--   Najwyższy poziom. PG używa Serializable Snapshot Isolation (SSI):
--   pozwala transakcjom działać równolegle, ale przy COMMIT wykrywa
--   konflikty serializacji i odrzuca część transakcji błędem SQLSTATE
--   40001 (serialization_failure). Aplikacja musi obsłużyć retry.
BEGIN ISOLATION LEVEL SERIALIZABLE;
    SELECT current_setting('transaction_isolation') AS poziom;
COMMIT;


-- ############################################################################
-- SEKCJA 3: Anomalie i scenariusze (DWIE SESJE psql)
--
-- Każdy scenariusz pokazuje:
--   (a) jak wygląda anomalia przy zbyt słabym poziomie izolacji,
--   (b) jak ją wyeliminować (silniejsza izolacja lub jawna blokada).
-- Kolejność kroków oznaczona literami A/B i numerami: 1A → 2B → 3A → ...
-- ############################################################################


-- ----------------------------------------------------------------------------
-- SCENARIUSZ 3.1: Wyścig (race condition) na jednym rowerze
-- Domena: dwóch klientów jednocześnie próbuje wypożyczyć rower o id = 1.
-- Bez ochrony może powstać "podwójne wypożyczenie" tego samego roweru.
-- ----------------------------------------------------------------------------

-- WARIANT BŁĘDNY: SELECT bez FOR UPDATE, READ COMMITTED.
-- ............................................................................
-- -- SESJA A (krok 1A):
--    BEGIN ISOLATION LEVEL READ COMMITTED;
--    SELECT status FROM rower WHERE id_rower = 1;
--    -- widzi 'dostepny'
--
-- -- SESJA B (krok 2B):
--    BEGIN ISOLATION LEVEL READ COMMITTED;
--    SELECT status FROM rower WHERE id_rower = 1;
--    -- też widzi 'dostepny' (zmiana A jeszcze nie zatwierdzona)
--
-- -- SESJA A (krok 3A):
--    INSERT INTO wypozyczenie (id_klient, id_rower, id_stacja_start)
--      VALUES (1, 1, 1);
--    COMMIT;
--
-- -- SESJA B (krok 4B):
--    INSERT INTO wypozyczenie (id_klient, id_rower, id_stacja_start)
--      VALUES (2, 1, 1);
--    COMMIT;
--
-- WYNIK: dwa równoczesne wypożyczenia tego samego roweru. Trigger
-- trg_status_roweru po pierwszym INSERT zmienia status na 'wypozyczony',
-- ale drugi INSERT już został przepuszczony przez BEFORE trigger
-- trg_blokuj_zablokowanego (który kontroluje tylko klienta, nie stan
-- roweru). Niespójność danych.

-- WARIANT POPRAWNY: SELECT ... FOR UPDATE (blokada pessymistyczna).
-- ............................................................................
-- -- SESJA A (krok 1A):
--    BEGIN;
--    SELECT status FROM rower WHERE id_rower = 1 FOR UPDATE;
--    -- 'dostepny' + blokada wiersza dla innych transakcji
--
-- -- SESJA B (krok 2B):
--    BEGIN;
--    SELECT status FROM rower WHERE id_rower = 1 FOR UPDATE;
--    -- ZAWIESZA SIĘ - czeka na zwolnienie blokady przez A
--
-- -- SESJA A (krok 3A):
--    INSERT INTO wypozyczenie ... ; COMMIT;
--
-- -- SESJA B (kontynuuje krok 2B po COMMIT z A):
--    -- SELECT zwraca już 'wypozyczony', aplikacja rzuca błąd
--
-- W praktyce ten mechanizm jest wbudowany w procedurę wypozycz_rower()
-- z pliku 04 - SELECT status FROM rower ... FOR UPDATE. Wystarczy:
--
--   -- SESJA A:  CALL wypozycz_rower(1, 1, 1);
--   -- SESJA B:  CALL wypozycz_rower(2, 1, 1);
--                -> EXCEPTION: "Rower 1 nie jest dostępny (aktualny status: wypozyczony)."


-- ----------------------------------------------------------------------------
-- SCENARIUSZ 3.2: Non-repeatable read przy raporcie rozliczeniowym
-- Domena: koordynator generuje raport "suma opłaconych + suma zaległych"
-- jako dwa kolejne SELECT. W trakcie raportu klient opłaca jedną zaległą
-- płatność. Przy READ COMMITTED ta sama kwota może zostać policzona po
-- obu stronach raportu - liczby się nie zgadzają.
-- ----------------------------------------------------------------------------

-- WARIANT BŁĘDNY: READ COMMITTED.
-- ............................................................................
-- -- SESJA A (1A):  BEGIN ISOLATION LEVEL READ COMMITTED;
-- -- SESJA A (2A):  SELECT sum(kwota) FROM platnosc WHERE status='zalegla';
--                   -- np. wynik X
-- -- SESJA B (3B):  UPDATE platnosc SET status='oplacona'
--                     WHERE id_platnosc = (jakiś rekord 'zalegla');
--                   COMMIT;
-- -- SESJA A (4A):  SELECT sum(kwota) FROM platnosc WHERE status='oplacona';
--                   -- widzi zmianę z 3B - raport NIESPÓJNY
-- -- SESJA A (5A):  COMMIT;

-- WARIANT POPRAWNY: REPEATABLE READ.
-- ............................................................................
-- Te same kroki, ale: BEGIN ISOLATION LEVEL REPEATABLE READ;
-- Snapshot z momentu pierwszego SELECT - zmiana sesji B w kroku 3B
-- pozostaje niewidoczna dla A aż do COMMIT/ROLLBACK transakcji A.

-- Przykład spójnego raportu (jedna sesja, runnable):
BEGIN ISOLATION LEVEL REPEATABLE READ;
    SELECT
        sum(suma_oplacona)   AS przychod_calkowity,
        sum(suma_zalegla)    AS naleznosci,
        count(*)             AS liczba_klientow
      FROM rozliczenia_klientow;

    -- Tu w innej sesji mogą trwać UPDATE'y - dzięki snapshotowi widzimy
    -- spójny obraz finansów z momentu rozpoczęcia transakcji.

    SELECT klient, suma_zalegla
      FROM rozliczenia_klientow
     WHERE suma_zalegla > 0
     ORDER BY suma_zalegla DESC;
COMMIT;


-- ----------------------------------------------------------------------------
-- SCENARIUSZ 3.3: Write skew - "ostatni rower" na stacji
-- Domena: polityka biznesowa zabrania wypożyczenia ostatniego roweru na
-- stacji (rezerwa dla obsługi). Dwóch klientów jednocześnie sprawdza
-- liczbę dostępnych rowerów: oboje widzą "2", oboje uznają że mogą
-- wypożyczyć (zostanie 1). Po commit obu - zostaje 0, polityka złamana.
-- REPEATABLE READ nie wystarcza, bo każda sesja widzi spójny *swój*
-- snapshot, ale nie widzi modyfikacji drugiej. Dopiero SERIALIZABLE
-- wykrywa konflikt.
-- ----------------------------------------------------------------------------

-- WARIANT BŁĘDNY: REPEATABLE READ.
-- ............................................................................
-- -- SESJA A (1A):  BEGIN ISOLATION LEVEL REPEATABLE READ;
-- -- SESJA B (1B):  BEGIN ISOLATION LEVEL REPEATABLE READ;
-- -- SESJA A (2A):  SELECT count(*) FROM dok
--                     WHERE id_stacja=1 AND id_rower IS NOT NULL;  -- 2
-- -- SESJA B (2B):  SELECT count(*) FROM dok
--                     WHERE id_stacja=1 AND id_rower IS NOT NULL;  -- 2
-- -- SESJA A (3A):  -- decyzja: 2 > 1, wypożycza
--                   CALL wypozycz_rower(1, jakis_rower_A, 1);
--                   COMMIT;
-- -- SESJA B (3B):  -- decyzja na podstawie SWOJEGO snapshotu: 2 > 1
--                   CALL wypozycz_rower(2, jakis_rower_B, 1);
--                   COMMIT;  -- też się powiódł!
-- WYNIK: pozostało 0 rowerów - polityka złamana mimo "poprawnej"
-- weryfikacji w obu sesjach.

-- WARIANT POPRAWNY: SERIALIZABLE.
-- ............................................................................
-- Te same kroki, ale BEGIN ISOLATION LEVEL SERIALIZABLE w obu sesjach.
-- Przy COMMIT drugiej sesji PG wykryje, że obie transakcje czytały te
-- same wiersze (predykat z count(*)) i obie zapisywały zmiany zależne
-- od tego odczytu. Druga sesja dostanie:
--
--   ERROR:  could not serialize access due to read/write dependencies
--   SQLSTATE: 40001
--
-- Aplikacja powinna złapać 40001 i powtórzyć transakcję (retry).
-- Po retry SESJA B zobaczy już prawdziwy stan (count = 1) i odmówi
-- wypożyczenia zgodnie z polityką.


-- ############################################################################
-- SEKCJA 4: Implementacja retry dla SERIALIZABLE
-- Wzorzec do użycia w aplikacji klienckiej - tutaj demonstracja po
-- stronie bazy (procedura PL/pgSQL).
-- ############################################################################

CREATE OR REPLACE PROCEDURE wypozycz_z_retry(
    p_klient    INTEGER,
    p_rower     INTEGER,
    p_stacja    INTEGER,
    p_max_prob  INTEGER DEFAULT 3
)
LANGUAGE plpgsql AS $$
DECLARE
    v_proba INTEGER := 0;
BEGIN
    LOOP
        BEGIN
            v_proba := v_proba + 1;
            CALL wypozycz_rower(p_klient, p_rower, p_stacja);
            RAISE NOTICE 'Wypożyczenie się powiodło (próba %).', v_proba;
            EXIT;
        EXCEPTION
            WHEN serialization_failure THEN
                IF v_proba >= p_max_prob THEN
                    RAISE EXCEPTION
                        'Nie udało się wypożyczyć po % próbach (konflikt serializacji).',
                        v_proba;
                END IF;
                RAISE NOTICE 'Konflikt serializacji - retry % z %.',
                    v_proba, p_max_prob;
                -- Krótki backoff, żeby nie wpaść w pętlę natychmiastowych retry.
                PERFORM pg_sleep(0.05 * v_proba);
        END;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE wypozycz_z_retry(INTEGER, INTEGER, INTEGER, INTEGER) IS
'Wrapper na wypozycz_rower z retry przy serialization_failure (SQLSTATE 40001).';


-- ============================================================================
-- Koniec skryptu transakcji i poziomów izolacji.
-- ============================================================================
