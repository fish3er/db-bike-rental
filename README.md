# Bike-Sharing System Database (PostgreSQL)

This repository contains the technical documentation and SQL implementation for a city bike-sharing database system. The project models a complete bike-sharing lifecycle, allowing users to rent a bike from one docking station and return it to any other station within the network.

The database was designed as a university project for a Database course and is normalized to the Third Normal Form (3NF).

## Technology Stack

- **RDBMS:** PostgreSQL (Tested on version 16)
- **Design Pattern:** 3rd Normal Form (3NF)

## Key Features

- **Customer & Tariff Management** - registration of customers and assignment of specific billing tariffs
- **Fleet & Station Tracking** - real-time tracking of bikes (available, rented, or in service) and individual docking stations
- **Rentals & Automated Payments** - handling check-outs and returns, with automatic cost calculation based on rental duration and the user's assigned tariff
- **Maintenance & Service** - logging bikes for maintenance and assigning repair tasks to employees
- **Business Logic Enforcement** - utilizing database triggers and constraints to enforce rules, such as blocking users with unpaid debts from renting new bikes

## How to Run

To set up the database locally, execute the SQL scripts in order using `psql` or your preferred PostgreSQL IDE:

```bash
# 1. Build the schema
psql -U postgres -d your_db_name -f 01_ddl.sql

# 2. Populate the tables with test data
psql -U postgres -d your_db_name -f 02_dane.sql

# 3. Generate views and run analytical queries
psql -U postgres -d your_db_name -f 03_widoki_zapytania.sql
```
