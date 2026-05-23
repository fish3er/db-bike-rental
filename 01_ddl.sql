-- ============================================================================
--  System wypożyczalni rowerów miejskich
--  Skrypt 01 - DDL (Data Definition Language)
--  System zarządzania bazą danych: PostgreSQL
--
--  Tworzy pełny schemat bazy: tabele, ograniczenia integralnościowe oraz indeksy.
--  Schemat zgodny z 3NF. Kolejność tworzenia tabel uwzględnia zależności
--  kluczy obcych.
-- ============================================================================

-- Czyszczenie schematu przy ponownym uruchomieniu (kolejność odwrotna do zależności).
DROP TABLE IF EXISTS serwis        CASCADE;
DROP TABLE IF EXISTS platnosc      CASCADE;
DROP TABLE IF EXISTS wypozyczenie  CASCADE;
DROP TABLE IF EXISTS dok           CASCADE;
DROP TABLE IF EXISTS rower         CASCADE;
DROP TABLE IF EXISTS stacja        CASCADE;
DROP TABLE IF EXISTS klient        CASCADE;
DROP TABLE IF EXISTS taryfa        CASCADE;
DROP TABLE IF EXISTS pracownik     CASCADE;

-- ----------------------------------------------------------------------------
--  Tabela: taryfa
--  Cennik. Wydzielona osobno, aby uniknąć zależności przechodniej w tabeli
--  klient (id_klient -> nazwa_taryfy -> stawka). Zapewnia zgodność z 3NF.
-- ----------------------------------------------------------------------------
CREATE TABLE taryfa (
    id_taryfa          SERIAL        PRIMARY KEY,
    nazwa              VARCHAR(50)   NOT NULL UNIQUE,
    oplata_poczatkowa  NUMERIC(6,2)  NOT NULL DEFAULT 0
                       CONSTRAINT chk_taryfa_oplata CHECK (oplata_poczatkowa >= 0),
    stawka_minuta      NUMERIC(6,2)  NOT NULL
                       CONSTRAINT chk_taryfa_stawka CHECK (stawka_minuta >= 0)
);

COMMENT ON TABLE  taryfa IS 'Cennik: opłata początkowa i stawka za minutę wypożyczenia.';
COMMENT ON COLUMN taryfa.stawka_minuta IS 'Stawka naliczana za każdą rozpoczętą minutę.';

-- ----------------------------------------------------------------------------
--  Tabela: klient
--  Użytkownik wypożyczający rowery. Wskazuje taryfę przez klucz obcy.
-- ----------------------------------------------------------------------------
CREATE TABLE klient (
    id_klient    SERIAL        PRIMARY KEY,
    email        VARCHAR(120)  NOT NULL UNIQUE,
    imie         VARCHAR(50)   NOT NULL,
    nazwisko     VARCHAR(50)   NOT NULL,
    id_taryfa    INTEGER       NOT NULL
                 REFERENCES taryfa(id_taryfa) ON UPDATE CASCADE ON DELETE RESTRICT,
    zablokowany  BOOLEAN       NOT NULL DEFAULT FALSE,
    CONSTRAINT chk_klient_email CHECK (POSITION('@' IN email) > 1)
);

COMMENT ON TABLE  klient IS 'Klienci wypożyczalni wraz z przypisaną taryfą.';
COMMENT ON COLUMN klient.zablokowany IS 'TRUE blokuje możliwość wypożyczenia (np. zaległości).';

-- ----------------------------------------------------------------------------
--  Tabela: stacja
--  Fizyczna lokalizacja z określoną pojemnością i współrzędnymi.
-- ----------------------------------------------------------------------------
CREATE TABLE stacja (
    id_stacja  SERIAL         PRIMARY KEY,
    nazwa      VARCHAR(100)   NOT NULL,
    pojemnosc  INTEGER        NOT NULL
               CONSTRAINT chk_stacja_pojemnosc CHECK (pojemnosc > 0),
    szer_geo   NUMERIC(9,6)   NOT NULL
               CONSTRAINT chk_stacja_szer CHECK (szer_geo BETWEEN -90  AND 90),
    dlug_geo   NUMERIC(9,6)   NOT NULL
               CONSTRAINT chk_stacja_dlug CHECK (dlug_geo BETWEEN -180 AND 180)
);

COMMENT ON TABLE stacja IS 'Stacje dokujące w sieci wypożyczalni.';

-- ----------------------------------------------------------------------------
--  Tabela: rower
--  Pojazd udostępniany klientom. Status kontrolowany słownikowym CHECK.
-- ----------------------------------------------------------------------------
CREATE TABLE rower (
    id_rower     SERIAL       PRIMARY KEY,
    nr_seryjny   VARCHAR(40)  NOT NULL UNIQUE,
    status       VARCHAR(20)  NOT NULL DEFAULT 'dostepny'
                 CONSTRAINT chk_rower_status
                 CHECK (status IN ('dostepny', 'wypozyczony', 'serwis')),
    przebieg_km  INTEGER      NOT NULL DEFAULT 0
                 CONSTRAINT chk_rower_przebieg CHECK (przebieg_km >= 0)
);

COMMENT ON TABLE  rower IS 'Flota rowerów wraz ze stanem i przebiegiem.';
COMMENT ON COLUMN rower.status IS 'Stan roweru: dostepny / wypozyczony / serwis (reguła RB1).';

-- ----------------------------------------------------------------------------
--  Tabela: dok
--  Pojedyncze stanowisko dokujące. Mieści co najwyżej jeden rower.
--  UNIQUE na id_rower wymusza, że rower nie jest zadokowany w dwóch miejscach
--  jednocześnie (reguła RB2). NULL oznacza dok pusty.
-- ----------------------------------------------------------------------------
CREATE TABLE dok (
    id_dok     SERIAL       PRIMARY KEY,
    id_stacja  INTEGER      NOT NULL
               REFERENCES stacja(id_stacja) ON UPDATE CASCADE ON DELETE CASCADE,
    id_rower   INTEGER      UNIQUE
               REFERENCES rower(id_rower) ON UPDATE CASCADE ON DELETE SET NULL,
    status     VARCHAR(20)  NOT NULL DEFAULT 'wolny'
               CONSTRAINT chk_dok_status CHECK (status IN ('wolny', 'zajety')),
    -- Spójność: dok zajęty <=> przypisany rower; dok wolny <=> brak roweru.
    CONSTRAINT chk_dok_spojnosc CHECK (
        (status = 'zajety' AND id_rower IS NOT NULL) OR
        (status = 'wolny'  AND id_rower IS NULL)
    )
);

COMMENT ON TABLE  dok IS 'Stanowiska dokujące w obrębie stacji (RB2).';
COMMENT ON COLUMN dok.id_rower IS 'Rower aktualnie zadokowany; NULL = dok pusty. UNIQUE wymusza RB2.';

-- ----------------------------------------------------------------------------
--  Tabela: wypozyczenie
--  Zdarzenie wypożyczenia. Dwie stacje: startowa i (opcjonalnie) zwrotu,
--  co umożliwia wypożyczenia jednokierunkowe.
-- ----------------------------------------------------------------------------
CREATE TABLE wypozyczenie (
    id_wypozyczenie   SERIAL      PRIMARY KEY,
    id_klient         INTEGER     NOT NULL
                      REFERENCES klient(id_klient) ON UPDATE CASCADE ON DELETE RESTRICT,
    id_rower          INTEGER     NOT NULL
                      REFERENCES rower(id_rower)  ON UPDATE CASCADE ON DELETE RESTRICT,
    id_stacja_start   INTEGER     NOT NULL
                      REFERENCES stacja(id_stacja) ON UPDATE CASCADE ON DELETE RESTRICT,
    id_stacja_koniec  INTEGER
                      REFERENCES stacja(id_stacja) ON UPDATE CASCADE ON DELETE RESTRICT,
    czas_start        TIMESTAMP   NOT NULL DEFAULT now(),
    czas_koniec       TIMESTAMP,
    CONSTRAINT chk_wyp_czas CHECK (czas_koniec IS NULL OR czas_koniec >= czas_start)
);

COMMENT ON TABLE  wypozyczenie IS 'Wypożyczenia rowerów; zwrot możliwy na innej stacji.';
COMMENT ON COLUMN wypozyczenie.czas_koniec IS 'NULL = wypożyczenie aktywne (rower w trasie).';

-- ----------------------------------------------------------------------------
--  Tabela: platnosc
--  Rozliczenie finansowe. Powiązana z klientem oraz (opcjonalnie) z
--  konkretnym wypożyczeniem.
-- ----------------------------------------------------------------------------
CREATE TABLE platnosc (
    id_platnosc      SERIAL       PRIMARY KEY,
    id_klient        INTEGER      NOT NULL
                     REFERENCES klient(id_klient) ON UPDATE CASCADE ON DELETE RESTRICT,
    id_wypozyczenie  INTEGER
                     REFERENCES wypozyczenie(id_wypozyczenie) ON UPDATE CASCADE ON DELETE SET NULL,
    kwota            NUMERIC(8,2) NOT NULL
                     CONSTRAINT chk_platnosc_kwota CHECK (kwota >= 0),
    status           VARCHAR(20)  NOT NULL DEFAULT 'zalegla'
                     CONSTRAINT chk_platnosc_status CHECK (status IN ('oplacona', 'zalegla')),
    czas             TIMESTAMP    NOT NULL DEFAULT now()
);

COMMENT ON TABLE  platnosc IS 'Płatności klientów za wypożyczenia.';
COMMENT ON COLUMN platnosc.status IS 'oplacona / zalegla — zaległa blokuje wypożyczenia (RB5).';

-- ----------------------------------------------------------------------------
--  Tabela: pracownik
--  Osoba obsługująca zgłoszenia serwisowe.
-- ----------------------------------------------------------------------------
CREATE TABLE pracownik (
    id_pracownik  SERIAL       PRIMARY KEY,
    imie          VARCHAR(50)  NOT NULL,
    nazwisko      VARCHAR(50)  NOT NULL,
    rola          VARCHAR(40)  NOT NULL
);

COMMENT ON TABLE pracownik IS 'Pracownicy obsługujący serwis floty.';

-- ----------------------------------------------------------------------------
--  Tabela: serwis
--  Zgłoszenie i ewidencja naprawy roweru.
-- ----------------------------------------------------------------------------
CREATE TABLE serwis (
    id_serwis        SERIAL      PRIMARY KEY,
    id_rower         INTEGER     NOT NULL
                     REFERENCES rower(id_rower) ON UPDATE CASCADE ON DELETE CASCADE,
    id_pracownik     INTEGER
                     REFERENCES pracownik(id_pracownik) ON UPDATE CASCADE ON DELETE SET NULL,
    opis             TEXT        NOT NULL,
    data_zgloszenia  TIMESTAMP   NOT NULL DEFAULT now()
);

COMMENT ON TABLE  serwis IS 'Zgłoszenia serwisowe rowerów.';
COMMENT ON COLUMN serwis.id_pracownik IS 'NULL = zgłoszenie nieprzypisane do pracownika.';

-- ============================================================================
--  INDEKSY
--  Poza indeksami automatycznymi dla PRIMARY KEY i UNIQUE tworzymy indeksy
--  wspierające najczęstsze zapytania (zgodnie z sekcją 5.9 dokumentacji).
-- ============================================================================

-- Historia wypożyczeń klienta.
CREATE INDEX idx_wyp_klient        ON wypozyczenie (id_klient);

-- Wypożyczenia danego roweru.
CREATE INDEX idx_wyp_rower         ON wypozyczenie (id_rower);

-- Aktywne wypożyczenia (czas_koniec IS NULL) - indeks częściowy.
CREATE INDEX idx_wyp_aktywne       ON wypozyczenie (id_rower) WHERE czas_koniec IS NULL;

-- Zliczanie wolnych/zajętych doków na stacji.
CREATE INDEX idx_dok_stacja        ON dok (id_stacja);

-- Wykrywanie klientów z zaległościami (RB5).
CREATE INDEX idx_platnosc_zalegla  ON platnosc (id_klient, status);

-- Zgłoszenia serwisowe danego roweru.
CREATE INDEX idx_serwis_rower      ON serwis (id_rower);

-- ============================================================================
--  Koniec skryptu DDL.
-- ============================================================================
