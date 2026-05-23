-- ============================================================================
--  System wypożyczalni rowerów miejskich
--  Skrypt 03 - Widoki i zaawansowane zapytania SQL
--
--  Pokrywa wymagania na ocenę 3.5-4.0:
--    - widoki (VIEW)
--    - podzapytania (w tym skorelowane)
--    - agregacje, GROUP BY / HAVING
--    - złączenia wielotabelowe, LEFT JOIN
--    - funkcje okna (window functions)
--
--  Uruchamiać PO 01_ddl.sql i 02_dane.sql.
-- ============================================================================

-- ############################################################################
--  CZĘŚĆ A: WIDOKI
-- ############################################################################

-- ----------------------------------------------------------------------------
--  Widok 1: dostepnosc_stacji
--  Aktualna dostępność rowerów i wolnych doków na każdej stacji.
--  Kluczowy widok operacyjny - pokazuje, gdzie można wypożyczyć rower
--  i gdzie jest miejsce na zwrot.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS dostepnosc_stacji CASCADE;
CREATE VIEW dostepnosc_stacji AS
SELECT
    s.id_stacja,
    s.nazwa,
    s.pojemnosc,
    count(d.id_rower)                       AS rowery_dostepne,
    count(*) FILTER (WHERE d.id_rower IS NULL) AS doki_wolne,
    round(100.0 * count(d.id_rower) / s.pojemnosc, 1) AS zapelnienie_proc
FROM stacja s
JOIN dok d ON d.id_stacja = s.id_stacja
GROUP BY s.id_stacja, s.nazwa, s.pojemnosc
ORDER BY s.id_stacja;

COMMENT ON VIEW dostepnosc_stacji IS
    'Liczba dostępnych rowerów i wolnych doków na stację wraz z procentem zapełnienia.';

-- ----------------------------------------------------------------------------
--  Widok 2: historia_wypozyczen
--  Czytelny widok wypożyczeń z danymi klienta, roweru, stacji oraz
--  obliczonym czasem trwania. Upraszcza raportowanie.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS historia_wypozyczen CASCADE;
CREATE VIEW historia_wypozyczen AS
SELECT
    w.id_wypozyczenie,
    k.imie || ' ' || k.nazwisko        AS klient,
    r.nr_seryjny,
    ss.nazwa                            AS stacja_startu,
    sk.nazwa                            AS stacja_zwrotu,
    w.czas_start,
    w.czas_koniec,
    CASE
        WHEN w.czas_koniec IS NULL THEN NULL
        ELSE round(EXTRACT(EPOCH FROM (w.czas_koniec - w.czas_start)) / 60.0)
    END                                 AS czas_min,
    CASE WHEN w.czas_koniec IS NULL THEN 'aktywne' ELSE 'zakończone' END AS stan
FROM wypozyczenie w
JOIN klient k  ON k.id_klient  = w.id_klient
JOIN rower  r  ON r.id_rower   = w.id_rower
JOIN stacja ss ON ss.id_stacja = w.id_stacja_start
LEFT JOIN stacja sk ON sk.id_stacja = w.id_stacja_koniec;

COMMENT ON VIEW historia_wypozyczen IS
    'Wypożyczenia z czytelnymi danymi i wyliczonym czasem trwania w minutach.';

-- ----------------------------------------------------------------------------
--  Widok 3: rozliczenia_klientow
--  Podsumowanie finansowe per klient: liczba wypożyczeń, suma opłacona,
--  suma zaległa. Wykorzystuje agregację warunkową (FILTER).
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS rozliczenia_klientow CASCADE;
-- UWAGA: liczbę wypożyczeń i sumy płatności agregujemy w ODDZIELNYCH
-- podzapytaniach. Gdyby oba złączyć bezpośrednio do tabeli klient dwoma
-- LEFT JOIN-ami, powstałby iloczyn kartezjański (N wypożyczeń × M płatności),
-- co zawyżyłoby sumy. Oddzielne agregaty eliminują to zwielokrotnienie.
CREATE VIEW rozliczenia_klientow AS
SELECT
    k.id_klient,
    k.imie || ' ' || k.nazwisko             AS klient,
    t.nazwa                                 AS taryfa,
    COALESCE(w.liczba_wypozyczen, 0)        AS liczba_wypozyczen,
    COALESCE(p.suma_oplacona, 0)            AS suma_oplacona,
    COALESCE(p.suma_zalegla, 0)             AS suma_zalegla
FROM klient k
JOIN taryfa t ON t.id_taryfa = k.id_taryfa
LEFT JOIN (
    SELECT id_klient, count(*) AS liczba_wypozyczen
    FROM wypozyczenie
    GROUP BY id_klient
) w ON w.id_klient = k.id_klient
LEFT JOIN (
    SELECT id_klient,
           sum(kwota) FILTER (WHERE status = 'oplacona') AS suma_oplacona,
           sum(kwota) FILTER (WHERE status = 'zalegla')  AS suma_zalegla
    FROM platnosc
    GROUP BY id_klient
) p ON p.id_klient = k.id_klient
ORDER BY k.id_klient;

COMMENT ON VIEW rozliczenia_klientow IS
    'Podsumowanie finansowe klientów: liczba wypożyczeń oraz kwoty opłacone i zaległe.';

-- ----------------------------------------------------------------------------
--  Widok 4: rowery_do_serwisu
--  Rowery w serwisie wraz z najnowszym zgłoszeniem i przypisanym pracownikiem.
--  Użyteczny dla koordynatora floty.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS rowery_do_serwisu CASCADE;
CREATE VIEW rowery_do_serwisu AS
SELECT
    r.id_rower,
    r.nr_seryjny,
    r.przebieg_km,
    s.opis,
    s.data_zgloszenia,
    COALESCE(p.imie || ' ' || p.nazwisko, '(nieprzypisane)') AS pracownik
FROM rower r
JOIN serwis s     ON s.id_rower = r.id_rower
LEFT JOIN pracownik p ON p.id_pracownik = s.id_pracownik
WHERE r.status = 'serwis'
ORDER BY s.data_zgloszenia;

COMMENT ON VIEW rowery_do_serwisu IS
    'Rowery o statusie serwis wraz ze zgłoszeniami i przypisanymi pracownikami.';


-- ############################################################################
--  CZĘŚĆ B: ZAAWANSOWANE ZAPYTANIA
--  (Każde zapytanie poprzedzone komentarzem z opisem zastosowanej techniki.)
-- ############################################################################

-- ----------------------------------------------------------------------------
--  Zapytanie 1: PODZAPYTANIE w klauzuli WHERE
--  Klienci, którzy wykonali więcej wypożyczeń niż średnia liczba wypożyczeń
--  przypadająca na klienta.
-- ----------------------------------------------------------------------------
-- \echo '== Z1: klienci powyżej średniej liczby wypożyczeń =='
SELECT k.imie || ' ' || k.nazwisko AS klient, count(*) AS wypozyczen
FROM wypozyczenie w
JOIN klient k ON k.id_klient = w.id_klient
GROUP BY k.id_klient, k.imie, k.nazwisko
HAVING count(*) > (
    SELECT count(*)::numeric / count(DISTINCT id_klient)
    FROM wypozyczenie
)
ORDER BY wypozyczen DESC;

-- ----------------------------------------------------------------------------
--  Zapytanie 2: GROUP BY + HAVING
--  Najpopularniejsze stacje startowe (co najmniej 1 wypożyczenie),
--  posortowane malejąco po liczbie wypożyczeń.
-- ----------------------------------------------------------------------------
-- \echo '== Z2: popularność stacji startowych =='
SELECT s.nazwa AS stacja, count(*) AS liczba_startow
FROM wypozyczenie w
JOIN stacja s ON s.id_stacja = w.id_stacja_start
GROUP BY s.id_stacja, s.nazwa
HAVING count(*) >= 1
ORDER BY liczba_startow DESC, s.nazwa;

-- ----------------------------------------------------------------------------
--  Zapytanie 3: PODZAPYTANIE SKORELOWANE
--  Dla każdego roweru: jego ostatnie (najnowsze) wypożyczenie.
--  Podzapytanie odwołuje się do roweru z zapytania zewnętrznego.
-- ----------------------------------------------------------------------------
-- \echo '== Z3: ostatnie wypożyczenie każdego wypożyczanego roweru =='
SELECT r.nr_seryjny, w.czas_start, w.id_klient
FROM wypozyczenie w
JOIN rower r ON r.id_rower = w.id_rower
WHERE w.czas_start = (
    SELECT max(w2.czas_start)
    FROM wypozyczenie w2
    WHERE w2.id_rower = w.id_rower      -- korelacja z zapytaniem zewnętrznym
)
ORDER BY r.nr_seryjny;

-- ----------------------------------------------------------------------------
--  Zapytanie 4: FUNKCJA OKNA (window function)
--  Ranking klientów wg sumy opłaconych płatności, z numerem pozycji
--  oraz udziałem procentowym w całości przychodów.
-- ----------------------------------------------------------------------------
-- \echo '== Z4: ranking klientów wg przychodu (window function) =='
SELECT
    k.imie || ' ' || k.nazwisko AS klient,
    sum(p.kwota) AS przychod,
    RANK() OVER (ORDER BY sum(p.kwota) DESC) AS pozycja,
    round(100.0 * sum(p.kwota) / sum(sum(p.kwota)) OVER (), 1) AS udzial_proc
FROM platnosc p
JOIN klient k ON k.id_klient = p.id_klient
WHERE p.status = 'oplacona'
GROUP BY k.id_klient, k.imie, k.nazwisko
ORDER BY przychod DESC;

-- ----------------------------------------------------------------------------
--  Zapytanie 5: PODZAPYTANIE z NOT EXISTS
--  Rowery, które nigdy nie zostały wypożyczone (np. cały czas dostępne
--  lub od razu trafiły do serwisu).
-- ----------------------------------------------------------------------------
-- \echo '== Z5: rowery nigdy niewypożyczone =='
SELECT r.nr_seryjny, r.status
FROM rower r
WHERE NOT EXISTS (
    SELECT 1 FROM wypozyczenie w WHERE w.id_rower = r.id_rower
)
ORDER BY r.nr_seryjny;

-- ----------------------------------------------------------------------------
--  Zapytanie 6: CTE (Common Table Expression) + agregacja
--  Średni czas trwania zakończonego wypożyczenia w rozbiciu na taryfę klienta.
-- ----------------------------------------------------------------------------
-- \echo '== Z6: średni czas wypożyczenia wg taryfy (CTE) =='
WITH zakonczone AS (
    SELECT
        w.id_klient,
        EXTRACT(EPOCH FROM (w.czas_koniec - w.czas_start)) / 60.0 AS minuty
    FROM wypozyczenie w
    WHERE w.czas_koniec IS NOT NULL
)
SELECT
    t.nazwa AS taryfa,
    count(*) AS liczba_wypozyczen,
    round(avg(z.minuty), 1) AS sredni_czas_min
FROM zakonczone z
JOIN klient k ON k.id_klient = z.id_klient
JOIN taryfa t ON t.id_taryfa = k.id_taryfa
GROUP BY t.nazwa
ORDER BY sredni_czas_min DESC;

-- ============================================================================
--  Koniec skryptu widoków i zapytań.
-- ============================================================================
