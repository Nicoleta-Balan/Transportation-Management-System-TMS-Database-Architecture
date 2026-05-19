PostgreSQL database schema designed to manage operations for a transportation network similar to Flixbus operating on buses. The architecture handles stations, route scheduling, temporal fare policies, dynamic seat availability, and reservation processing.

Technologies used: 
 PostgreSQL
 PL/pgSQL (Stored Procedures, Functions, Triggers)


PL/pgSQL: includes custom functions and stored procedures to handle complex business logic, such as dynamic VAT calculations and category-based pricing.
Temporal Data Management: Implements `effective_from` and `effective_to` windows to maintain historical accuracy for fare policies and VAT rates, ensuring past reservations are never retroactively altered.
Denormalization: Uses database triggers to automatically recalculate and update route availability, revenue statistics, and denormalized reservation fields in real-time.
Integrity & Validation: Prevents overbooking, circular routes, and overlapping temporal windows using rigorous `CHECK` constraints and custom `BEFORE`/`AFTER` triggers.
Audit Trails: Dedicated history tables (`reservation_status_history`, `fare_policy_history`) automatically track state mutations for compliance and analytics.
