INSERT INTO taryfa (nazwa, oplata_poczatkowa, stawka_minuta) VALUES
    ('Standard',  2.00, 0.50),   -- id 1
    ('Student',   1.00, 0.30),   -- id 2
    ('Abonament', 0.00, 0.20);   -- id 3

INSERT INTO klient (email, imie, nazwisko, id_taryfa, zablokowany) VALUES
    ('jan.kowalski@example.com',       'Jan',      'Kowalski',     1, FALSE),  -- id 1
    ('anna.nowak@example.com',         'Anna',     'Nowak',        2, FALSE),  -- id 2
    ('piotr.wisniewski@example.com',   'Piotr',    'Wiśniewski',   1, FALSE),  -- id 3
    ('maria.wojcik@example.com',       'Maria',    'Wójcik',       3, FALSE),  -- id 4
    ('krzysztof.kaczmarek@example.com','Krzysztof','Kaczmarek',    2, FALSE),  -- id 5
    ('agnieszka.mazur@example.com',    'Agnieszka','Mazur',        3, FALSE),  -- id 6
    ('zofia.lewandowska@example.com',  'Zofia',    'Lewandowska',  1, TRUE),   -- id 7 (zablokowana)
    ('tomasz.zielinski@example.com',   'Tomasz',   'Zieliński',    2, FALSE);  -- id 8 (zaległość)

INSERT INTO stacja (nazwa, pojemnosc, szer_geo, dlug_geo) VALUES
    ('Centrum - Metro Centrum',    8, 52.229676, 21.012229),  -- id 1
    ('Mokotów - Pole Mokotowskie', 6, 52.211100, 21.000000),  -- id 2
    ('Wola - Rondo Daszyńskiego',  6, 52.231900, 20.984700),  -- id 3
    ('Praga - ZOO',                6, 52.255900, 21.027500);  -- id 4

INSERT INTO rower (nr_seryjny, status, przebieg_km) VALUES
    ('RW-0001', 'dostepny',     320),  -- id 1
    ('RW-0002', 'dostepny',     540),  -- id 2
    ('RW-0003', 'dostepny',     285),  -- id 3
    ('RW-0004', 'dostepny',     610),  -- id 4
    ('RW-0005', 'dostepny',     420),  -- id 5
    ('RW-0006', 'dostepny',     145),  -- id 6
    ('RW-0007', 'dostepny',     770),  -- id 7
    ('RW-0008', 'wypozyczony',  390),  -- id 8  (aktywne)
    ('RW-0009', 'wypozyczony',  250),  -- id 9  (aktywne)
    ('RW-0010', 'serwis',       890),  -- id 10
    ('RW-0011', 'serwis',       430),  -- id 11
    ('RW-0012', 'serwis',      1020);  -- id 12

INSERT INTO dok (id_stacja, id_rower, status) VALUES
    (1, 1, 'zajety'), (1, 2, 'zajety'), (1, 3, 'zajety'), (1, 4, 'zajety'),
    (1, NULL, 'wolny'), (1, NULL, 'wolny'), (1, NULL, 'wolny'), (1, NULL, 'wolny');
INSERT INTO dok (id_stacja, id_rower, status) VALUES
    (2, 5, 'zajety'), (2, 6, 'zajety'),
    (2, NULL, 'wolny'), (2, NULL, 'wolny'), (2, NULL, 'wolny'), (2, NULL, 'wolny');
INSERT INTO dok (id_stacja, id_rower, status) VALUES
    (3, 7, 'zajety'),
    (3, NULL, 'wolny'), (3, NULL, 'wolny'), (3, NULL, 'wolny'), (3, NULL, 'wolny'), (3, NULL, 'wolny');
INSERT INTO dok (id_stacja, id_rower, status) VALUES
    (4, NULL, 'wolny'), (4, NULL, 'wolny'), (4, NULL, 'wolny'),
    (4, NULL, 'wolny'), (4, NULL, 'wolny'), (4, NULL, 'wolny');

INSERT INTO pracownik (imie, nazwisko, rola) VALUES
    ('Marek',  'Serwisant',    'technik'),        -- id 1
    ('Ewa',    'Kowalczyk',    'technik'),        -- id 2
    ('Robert', 'Operator',     'koordynator'),    -- id 3
    ('Halina', 'Administrator','administrator');  -- id 4

INSERT INTO wypozyczenie
    (id_klient, id_rower, id_stacja_start, id_stacja_koniec, czas_start, czas_koniec) VALUES
    -- Jan (1) - Standard
    (1, 1, 1, 2, '2025-05-01 08:00', '2025-05-01 08:20'),
    (1, 2, 2, 1, '2025-05-03 17:30', '2025-05-03 18:00'),
    (1, 3, 1, 1, '2025-05-06 09:15', '2025-05-06 09:45'),
    (1, 1, 1, 3, '2025-05-09 12:00', '2025-05-09 12:18'),
    (1, 4, 3, 1, '2025-05-12 07:50', '2025-05-12 08:30'),
    -- Anna (2) - Student
    (2, 5, 2, 3, '2025-05-02 14:00', '2025-05-02 14:25'),
    (2, 6, 1, 1, '2025-05-05 10:10', '2025-05-05 10:40'),
    (2, 3, 3, 2, '2025-05-08 16:00', '2025-05-08 16:50'),
    (2, 7, 2, 2, '2025-05-11 18:30', '2025-05-11 18:45'),
    -- Piotr (3) - Standard
    (3, 2, 1, 4, '2025-05-04 11:00', '2025-05-04 11:35'),
    (3, 5, 4, 1, '2025-05-07 13:20', '2025-05-07 14:05'),
    (3, 1, 2, 2, '2025-05-10 08:40', '2025-05-10 09:10'),
    -- Krzysztof (5) - Student
    (5, 4, 1, 2, '2025-05-03 09:00', '2025-05-03 09:22'),
    (5, 6, 2, 4, '2025-05-06 15:15', '2025-05-06 16:00'),
    (5, 7, 4, 3, '2025-05-13 19:00', '2025-05-13 19:28'),
    -- Maria (4) - Abonament
    (4, 3, 1, 1, '2025-05-05 12:30', '2025-05-05 13:10'),
    (4, 5, 3, 4, '2025-05-14 10:00', '2025-05-14 10:35'),
    -- Tomasz (8) - Student (ZALEGŁA)
    (8, 7, 3, 3, '2025-05-04 09:00', '2025-05-04 09:12'),
    -- AKTYWNE
    (4, 8, 1, NULL, '2025-05-20 10:00', NULL),
    (5, 9, 2, NULL, '2025-05-20 11:30', NULL);

INSERT INTO platnosc (id_klient, id_wypozyczenie, kwota, status, czas) VALUES
    (1,  1, 12.00, 'oplacona', '2025-05-01 08:20'),
    (1,  2, 17.00, 'oplacona', '2025-05-03 18:00'),
    (1,  3, 17.00, 'oplacona', '2025-05-06 09:45'),
    (1,  4, 11.00, 'oplacona', '2025-05-09 12:18'),
    (1,  5, 22.00, 'oplacona', '2025-05-12 08:30'),
    (2,  6,  8.50, 'oplacona', '2025-05-02 14:25'),
    (2,  7, 10.00, 'oplacona', '2025-05-05 10:40'),
    (2,  8, 16.00, 'oplacona', '2025-05-08 16:50'),
    (2,  9,  5.50, 'oplacona', '2025-05-11 18:45'),
    (3, 10, 19.50, 'oplacona', '2025-05-04 11:35'),
    (3, 11, 24.50, 'oplacona', '2025-05-07 14:05'),
    (3, 12, 17.00, 'oplacona', '2025-05-10 09:10'),
    (5, 13,  7.60, 'oplacona', '2025-05-03 09:22'),
    (5, 14, 14.50, 'oplacona', '2025-05-06 16:00'),
    (5, 15,  9.40, 'oplacona', '2025-05-13 19:28'),
    (4, 16,  8.00, 'oplacona', '2025-05-05 13:10'),
    (4, 17,  7.00, 'oplacona', '2025-05-14 10:35'),
    (8, 18,  4.60, 'zalegla',  '2025-05-04 09:12');

INSERT INTO serwis (id_rower, id_pracownik, opis, data_zgloszenia) VALUES
    (10, 1,    'Uszkodzony hamulec tylny, wymiana klocków.',     '2025-05-15 14:00'),
    (11, 2,    'Przebita opona przednia, łatanie dętki.',        '2025-05-18 10:30'),
    (12, NULL, 'Zgłoszenie zgrzytu w przerzutce - do diagnozy.', '2025-05-21 16:45');
