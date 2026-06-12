-- Przykład 1.1: Jawna transakcja z ROLLBACK
-- Stan wyjściowy:
SELECT id_rower, nr_seryjny, przebieg_km FROM rower WHERE id_rower = 1;

BEGIN;
    UPDATE rower SET przebieg_km = przebieg_km + 999 WHERE id_rower = 1;

    -- Wewnątrz transakcji zmiana widoczna (own writes):
    SELECT id_rower, nr_seryjny, przebieg_km FROM rower WHERE id_rower = 1;
ROLLBACK;

-- Po ROLLBACK przebieg wrócił do stanu sprzed BEGIN:
SELECT id_rower, nr_seryjny, przebieg_km FROM rower WHERE id_rower = 1;


-- Przykład 1.2: SAVEPOINT i ROLLBACK TO SAVEPOINT
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


-- Przykład 1.3: Blok EXCEPTION w PL/pgSQL = niejawny SAVEPOINT
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


-- Ustawianie poziomu izolacji
BEGIN ISOLATION LEVEL READ COMMITTED;
    SELECT current_setting('transaction_isolation') AS poziom;
COMMIT;

-- REPEATABLE READ:
BEGIN ISOLATION LEVEL REPEATABLE READ;
    SELECT current_setting('transaction_isolation') AS poziom;
COMMIT;

-- SERIALIZABLE:
BEGIN ISOLATION LEVEL SERIALIZABLE;
    SELECT current_setting('transaction_isolation') AS poziom;
COMMIT;


-- SCENARIUSZ 3.1: Wyścig (race condition) na jednym rowerze

-- WARIANT BŁĘDNY: SELECT bez FOR UPDATE, READ COMMITTED.
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

-- WARIANT POPRAWNY: SELECT ... FOR UPDATE (blokada pesymistyczna)
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


-- SCENARIUSZ 3.2: Non-repeatable read przy raporcie rozliczeniowym

-- WARIANT BŁĘDNY: READ COMMITTED.
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


-- SCENARIUSZ 3.3: Write skew - "ostatni rower" na stacji

-- WARIANT BŁĘDNY: REPEATABLE READ.
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


-- Implementacja retry dla SERIALIZABLE
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
