-- ============================================================================
-- System wypożyczalni rowerów miejskich
-- Skrypt 04 - Funkcje, procedury i wyzwalacze PL/pgSQL
-- System zarządzania bazą danych: PostgreSQL
--
-- Implementuje proceduralnie reguły biznesowe RB1, RB3, RB4, RB5 oraz
-- operacje atomowe (wypożyczenie, zwrot, naliczenie opłaty). Triggery
-- uzupełniają deklaratywne ograniczenia z 01_ddl.sql tam, gdzie sam CHECK
-- nie wystarcza (zależności między wieloma tabelami, kaskadowa zmiana stanu).
--
-- Uruchamiać PO 01_ddl.sql. Niezależne od 02_dane.sql – można uruchamiać
-- w dowolnej kolejności względem danych testowych.
-- ============================================================================

-- Czyszczenie obiektów przy ponownym uruchomieniu (kolejność: triggery → funkcje).
DROP TRIGGER IF EXISTS trg_dok_sync_status        ON dok;
DROP TRIGGER IF EXISTS trg_blokuj_zablokowanego   ON wypozyczenie;
DROP TRIGGER IF EXISTS trg_status_roweru          ON wypozyczenie;
DROP TRIGGER IF EXISTS trg_blokuj_z_zaleglosciami ON platnosc;

DROP FUNCTION IF EXISTS fn_dok_sync_status()        CASCADE;
DROP FUNCTION IF EXISTS fn_blokuj_zablokowanego()   CASCADE;
DROP FUNCTION IF EXISTS fn_status_roweru()          CASCADE;
DROP FUNCTION IF EXISTS fn_blokuj_z_zaleglosciami() CASCADE;
DROP FUNCTION IF EXISTS oblicz_oplate(INTEGER)      CASCADE;
DROP PROCEDURE IF EXISTS wypozycz_rower(INTEGER, INTEGER, INTEGER);
DROP PROCEDURE IF EXISTS zwroc_rower(INTEGER, INTEGER);

-- ############################################################################
-- CZĘŚĆ A: WYZWALACZE (TRIGGERS)
-- ############################################################################

-- ----------------------------------------------------------------------------
-- Trigger 1: trg_dok_sync_status
-- Cel: automatyzuje regułę RB3 - utrzymuje spójność dok.status ↔ dok.id_rower.
-- Deklaratywny CHECK chk_dok_spojnosc w 01_ddl.sql tylko WERYFIKUJE spójność;
-- ten trigger ją WYMUSZA, ustawiając status automatycznie przy każdej
-- modyfikacji id_rower. Dzięki temu aplikacja nie musi pamiętać o jednoczesnej
-- aktualizacji obu pól.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_dok_sync_status()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.id_rower IS NULL THEN
        NEW.status := 'wolny';
    ELSE
        NEW.status := 'zajety';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_dok_sync_status
    BEFORE INSERT OR UPDATE OF id_rower ON dok
    FOR EACH ROW
    EXECUTE FUNCTION fn_dok_sync_status();

COMMENT ON FUNCTION fn_dok_sync_status() IS
'RB3: wymusza spójność dok.status z dok.id_rower (NULL → wolny, rower → zajety).';

-- ----------------------------------------------------------------------------
-- Trigger 2: trg_blokuj_zablokowanego
-- Cel: implementuje regułę RB4 - uniemożliwia wypożyczenie klientowi
-- z flagą zablokowany = TRUE. Zwraca błąd na poziomie bazy, więc ochrona
-- jest niezależna od aplikacji i działa nawet przy ręcznym INSERT.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_blokuj_zablokowanego()
RETURNS TRIGGER AS $$
DECLARE
    v_zablokowany BOOLEAN;
BEGIN
    SELECT zablokowany
      INTO v_zablokowany
      FROM klient
     WHERE id_klient = NEW.id_klient;

    IF v_zablokowany THEN
        RAISE EXCEPTION
            'Klient % jest zablokowany i nie może wypożyczać rowerów (RB4).',
            NEW.id_klient
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_blokuj_zablokowanego
    BEFORE INSERT ON wypozyczenie
    FOR EACH ROW
    EXECUTE FUNCTION fn_blokuj_zablokowanego();

COMMENT ON FUNCTION fn_blokuj_zablokowanego() IS
'RB4: blokuje INSERT wypożyczenia dla klienta z zablokowany = TRUE.';

-- ----------------------------------------------------------------------------
-- Trigger 3: trg_status_roweru
-- Cel: utrzymuje rower.status spójny z aktualnymi wypożyczeniami (RB1).
-- - INSERT wypożyczenia (rozpoczęcie) → status 'wypozyczony'
-- - UPDATE z czas_koniec ustawionym (zwrot) → status 'dostepny'
-- Status 'serwis' jest świadomie pomijany - rower w serwisie nie powinien
-- mieć aktywnego wypożyczenia, ale jeśli się to zdarzy, status serwisowy
-- ma pierwszeństwo i nie jest nadpisywany przez ten trigger.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_status_roweru()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE rower
           SET status = 'wypozyczony'
         WHERE id_rower = NEW.id_rower
           AND status   = 'dostepny';

    ELSIF TG_OP = 'UPDATE'
          AND OLD.czas_koniec IS NULL
          AND NEW.czas_koniec IS NOT NULL THEN
        UPDATE rower
           SET status = 'dostepny'
         WHERE id_rower = NEW.id_rower
           AND status   = 'wypozyczony';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_status_roweru
    AFTER INSERT OR UPDATE ON wypozyczenie
    FOR EACH ROW
    EXECUTE FUNCTION fn_status_roweru();

COMMENT ON FUNCTION fn_status_roweru() IS
'RB1: synchronizuje rower.status ze stanem wypożyczenia (dostepny ↔ wypozyczony).';

-- ----------------------------------------------------------------------------
-- Trigger 4: trg_blokuj_z_zaleglosciami
-- Cel: implementuje regułę RB5 - automatycznie ustawia klient.zablokowany
-- = TRUE, gdy pojawi się płatność ze statusem 'zalegla'. Odwrotnie - gdy
-- wszystkie zaległości zostaną opłacone, blokada jest zdejmowana.
-- Reaguje na INSERT, UPDATE i DELETE w tabeli platnosc.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_blokuj_z_zaleglosciami()
RETURNS TRIGGER AS $$
DECLARE
    v_klient        INTEGER;
    v_ma_zaleglosci BOOLEAN;
BEGIN
    -- Klient pochodzi z nowego (INSERT/UPDATE) lub starego rekordu (DELETE).
    v_klient := COALESCE(NEW.id_klient, OLD.id_klient);

    SELECT EXISTS (
        SELECT 1 FROM platnosc
         WHERE id_klient = v_klient
           AND status    = 'zalegla'
    )
    INTO v_ma_zaleglosci;

    -- Aktualizuj tylko jeśli flaga rzeczywiście się zmienia (unikaj pustych UPDATE).
    UPDATE klient
       SET zablokowany = v_ma_zaleglosci
     WHERE id_klient   = v_klient
       AND zablokowany IS DISTINCT FROM v_ma_zaleglosci;

    RETURN NULL;  -- AFTER trigger - wartość zwracana ignorowana.
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_blokuj_z_zaleglosciami
    AFTER INSERT OR UPDATE OR DELETE ON platnosc
    FOR EACH ROW
    EXECUTE FUNCTION fn_blokuj_z_zaleglosciami();

COMMENT ON FUNCTION fn_blokuj_z_zaleglosciami() IS
'RB5: synchronizuje klient.zablokowany z istnieniem płatności o statusie zalegla.';

-- ############################################################################
-- CZĘŚĆ B: FUNKCJE I PROCEDURY
-- ############################################################################

-- ----------------------------------------------------------------------------
-- Funkcja: oblicz_oplate(p_wypozyczenie)
-- Zwraca kwotę należną za wypożyczenie zgodnie z taryfą klienta.
-- Formuła: opłata_początkowa + CEIL(minuty) * stawka_minuta
-- Dla wypożyczeń aktywnych (czas_koniec IS NULL) liczy opłatę "na teraz".
-- Oznaczona jako STABLE - czyta dane, ale nie modyfikuje stanu bazy
-- (optymalizator może cache'ować wynik w obrębie jednego zapytania).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION oblicz_oplate(p_wypozyczenie INTEGER)
RETURNS NUMERIC(8,2) AS $$
DECLARE
    v_minuty            NUMERIC;
    v_oplata_poczatkowa NUMERIC(6,2);
    v_stawka_minuta     NUMERIC(6,2);
BEGIN
    SELECT
        EXTRACT(EPOCH FROM (COALESCE(w.czas_koniec, now()) - w.czas_start)) / 60.0,
        t.oplata_poczatkowa,
        t.stawka_minuta
      INTO v_minuty, v_oplata_poczatkowa, v_stawka_minuta
      FROM wypozyczenie w
      JOIN klient k ON k.id_klient = w.id_klient
      JOIN taryfa t ON t.id_taryfa = k.id_taryfa
     WHERE w.id_wypozyczenie = p_wypozyczenie;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Nie znaleziono wypożyczenia o id = %.', p_wypozyczenie;
    END IF;

    RETURN ROUND(v_oplata_poczatkowa + CEIL(v_minuty) * v_stawka_minuta, 2);
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION oblicz_oplate(INTEGER) IS
'Oblicza opłatę za wypożyczenie wg taryfy klienta: opłata startowa + minuty * stawka.';

-- ----------------------------------------------------------------------------
-- Procedura: wypozycz_rower(p_klient, p_rower, p_stacja)
-- Atomowa operacja rozpoczęcia wypożyczenia:
--   1. SELECT FOR UPDATE na rowerze (blokada pessymistyczna - zapobiega
--      wyścigowi dwóch klientów próbujących wypożyczyć ten sam rower).
--   2. Weryfikacja dostępności (status = 'dostepny').
--   3. INSERT do tabeli wypozyczenie - tu odpalają się triggery RB4 i RB1.
--   4. Zwolnienie doku, w którym rower stał (trigger trg_dok_sync_status
--      automatycznie ustawi dok.status = 'wolny').
-- Procedura wykonuje się w pojedynczej transakcji niejawnej; błąd w dowolnym
-- kroku powoduje rollback całości.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE wypozycz_rower(
    p_klient INTEGER,
    p_rower  INTEGER,
    p_stacja INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    -- Pessymistyczna blokada na wierszu roweru.
    SELECT status
      INTO v_status
      FROM rower
     WHERE id_rower = p_rower
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rower % nie istnieje.', p_rower;
    END IF;

    IF v_status <> 'dostepny' THEN
        RAISE EXCEPTION 'Rower % nie jest dostępny (aktualny status: %).',
            p_rower, v_status;
    END IF;

    -- INSERT odpali trg_blokuj_zablokowanego (RB4) oraz trg_status_roweru (RB1).
    INSERT INTO wypozyczenie (id_klient, id_rower, id_stacja_start)
    VALUES (p_klient, p_rower, p_stacja);

    -- Zwolnienie doku - trigger trg_dok_sync_status zaktualizuje status doku.
    UPDATE dok
       SET id_rower = NULL
     WHERE id_rower = p_rower;
END;
$$;

COMMENT ON PROCEDURE wypozycz_rower(INTEGER, INTEGER, INTEGER) IS
'Atomowe rozpoczęcie wypożyczenia: walidacja + INSERT + zwolnienie doku.';

-- ----------------------------------------------------------------------------
-- Procedura: zwroc_rower(p_wypozyczenie, p_stacja_zwrotu)
-- Atomowa operacja zwrotu:
--   1. SELECT FOR UPDATE na wypożyczeniu (blokada przed równoległym zwrotem).
--   2. Zamknięcie wypożyczenia (czas_koniec, id_stacja_koniec)
--      → trigger trg_status_roweru przywraca rower do statusu 'dostepny'.
--   3. Próba zadokowania roweru w pierwszym wolnym doku stacji zwrotu.
--      Jeśli brak wolnego doku - WARNING (rower zostaje "luzem", obsługa
--      stacji musi go ręcznie zadokować). Wypożyczenie i tak jest zamknięte.
--   4. Naliczenie opłaty przez oblicz_oplate(); płatność ze statusem 'zalegla'
--      → trigger trg_blokuj_z_zaleglosciami zablokuje klienta (RB5).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE zwroc_rower(
    p_wypozyczenie  INTEGER,
    p_stacja_zwrotu INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_rower  INTEGER;
    v_klient INTEGER;
    v_dok    INTEGER;
    v_kwota  NUMERIC(8,2);
BEGIN
    -- Blokada wypożyczenia.
    SELECT id_rower, id_klient
      INTO v_rower, v_klient
      FROM wypozyczenie
     WHERE id_wypozyczenie = p_wypozyczenie
       AND czas_koniec     IS NULL
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wypożyczenie % nie istnieje lub jest już zakończone.',
            p_wypozyczenie;
    END IF;

    -- Zamknięcie wypożyczenia.
    UPDATE wypozyczenie
       SET czas_koniec      = now(),
           id_stacja_koniec = p_stacja_zwrotu
     WHERE id_wypozyczenie  = p_wypozyczenie;

    -- Szukamy wolnego doku na stacji zwrotu (FOR UPDATE chroni przed
    -- jednoczesnym zajęciem tego samego doku przez innego zwracającego).
    SELECT id_dok
      INTO v_dok
      FROM dok
     WHERE id_stacja = p_stacja_zwrotu
       AND id_rower  IS NULL
     LIMIT 1
     FOR UPDATE;

    IF FOUND THEN
        UPDATE dok SET id_rower = v_rower WHERE id_dok = v_dok;
    ELSE
        RAISE WARNING
            'Brak wolnego doku na stacji % - rower % zostaje poza dokiem.',
            p_stacja_zwrotu, v_rower;
    END IF;

    -- Naliczenie opłaty.
    v_kwota := oblicz_oplate(p_wypozyczenie);
    INSERT INTO platnosc (id_klient, id_wypozyczenie, kwota, status)
    VALUES (v_klient, p_wypozyczenie, v_kwota, 'zalegla');
END;
$$;

COMMENT ON PROCEDURE zwroc_rower(INTEGER, INTEGER) IS
'Atomowy zwrot roweru: zamknięcie wypożyczenia + dokowanie + naliczenie opłaty.';

-- ============================================================================
-- TESTY MANUALNE
-- Odkomentować po załadowaniu 02_dane.sql w celu weryfikacji.
-- ============================================================================

-- -- Test 1: poprawne wypożyczenie (klient 1, rower dostępny, stacja 1)
-- CALL wypozycz_rower(1, 1, 1);
-- SELECT id_wypozyczenie, id_klient, id_rower, czas_start FROM wypozyczenie
--   ORDER BY id_wypozyczenie DESC LIMIT 1;

-- -- Test 2: próba wypożyczenia przez klienta zablokowanego (Zofia, id 8)
-- --         -> powinno rzucić wyjątkiem 'check_violation' z RB4
-- CALL wypozycz_rower(8, 3, 1);

-- -- Test 3: próba wypożyczenia roweru już wypożyczonego (rower 8 jest aktywny)
-- --         -> powinno rzucić wyjątkiem 'Rower 8 nie jest dostępny'
-- CALL wypozycz_rower(1, 8, 1);

-- -- Test 4: obliczenie opłaty dla istniejącego wypożyczenia
-- SELECT id_wypozyczenie, oblicz_oplate(id_wypozyczenie) AS naleznosc
--   FROM wypozyczenie WHERE czas_koniec IS NOT NULL ORDER BY id_wypozyczenie LIMIT 5;

-- -- Test 5: zwrot aktywnego wypożyczenia
-- CALL zwroc_rower(19, 2);  -- wypożyczenie 19 zwracane na stację 2

-- -- Test 6: weryfikacja automatycznej blokady klienta po pojawieniu się zaległości
-- INSERT INTO platnosc (id_klient, kwota, status) VALUES (1, 50.00, 'zalegla');
-- SELECT id_klient, imie, nazwisko, zablokowany FROM klient WHERE id_klient = 1;
-- -- Powinno: zablokowany = TRUE

-- -- Po opłaceniu blokada powinna zostać zdjęta:
-- UPDATE platnosc SET status = 'oplacona'
--   WHERE id_klient = 1 AND status = 'zalegla';
-- SELECT id_klient, zablokowany FROM klient WHERE id_klient = 1;
-- -- Powinno: zablokowany = FALSE (o ile nie ma innych zaległości)

-- ============================================================================
-- Koniec skryptu funkcji, procedur i wyzwalaczy.
-- ============================================================================
