# Membership Insight Pipeline (Azure SQL + Power BI)

Personal project built to learn Azure SQL. All data is synthetic.

## Questions this project answers
1. Which members are at risk of lapsing?
2. Which CPD events drive engagement?
3. How does survey satisfaction vary by region and role?

## Architecture
Python (Faker) -> Azure SQL (raw -> clean -> model) -> Power BI

## Status
- In progress, October 2026
- Region: Germany West Central (Azure SQL free tier, auto-pauses when idle)
- Day 1: Azure SQL database, firewall and budget alert setup
