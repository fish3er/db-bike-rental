# Bike-Sharing System Database (PostgreSQL)

This repository contains the technical documentation and SQL implementation for a city bike-sharing database system. The project models a complete bike-sharing lifecycle, allowing users to rent a bike from one docking station and return it to any other station within the network.

The database was designed as a university project for a Database course and is normalized to the Third Normal Form (3NF).

## Technology Stack

- **RDBMS:** PostgreSQL (Tested on version 16)
- **Design Pattern:** 3rd Normal Form (3NF)
- **Procedural Extension:** PL/pgSQL

## Key Features

- **Customer & Tariff Management** - registration of customers and assignment of specific billing tariffs
- **Fleet & Station Tracking** - real-time tracking of bikes (available, rented, or in service) and individual docking stations
- **Rentals & Automated Payments** - handling check-outs and returns, with automatic cost calculation based on rental duration and the user's assigned tariff
- **Maintenance & Service** - logging bikes for maintenance and assigning repair tasks to employees
- **Business Logic Enforcement** - utilizing database triggers and constraints to enforce rules, such as blocking users with unpaid debts from renting new bikes
- **Atomic Transactions & Concurrency** - advanced handling of race conditions using explicit locks (`SELECT FOR UPDATE`), serializable isolation levels, and retry loops
- **Granular Security** - employs a "deny by default" architecture with role-based access control, column-level privileges, and Row-Level Security (RLS) to restrict clients to their own data

## How to Run

To set up the database locally, execute the SQL scripts in the strict obligatory order using `psql`. Note that functions and triggers must be created before views.

Create the database:

```bash
createdb bike_rental
```

Execute the scripts in the **following** sequence:

```bash
# 1. Build the schema, tables, constraints and indexes
psql -d bike_rental -f 01_ddl.sql

# 2. Populate the tables with test data
psql -d bike_rental -f 02_dane.sql

# 3. Establish functions, procedures and PL/pgSQL triggers
psql -d bike_rental -f 04_funkcje_triggery.sql

# 4. Generate analytical views and advanced queries
psql -d bike_rental -f 03_widoki_zapytania.sql

# 5. Set up transaction mechanisms and isolation levels
psql -d bike_rental -f 05_transakcje.sql

# 6. Configure roles, permissions, and Row-Level Security
psql -d bike_rental -f 06_bezpieczenstwo.sql
```
