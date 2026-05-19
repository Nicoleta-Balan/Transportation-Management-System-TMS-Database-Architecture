-- ============================================================================
-- Transportation Management System Database Schema
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECTION 1: CORE SCHEMA
-- ----------------------------------------------------------------------------
-- Special cases & exceptions:
--   • CHECK constraints prevent circular routes, invalid seats, bad dates.
--   • Foreign keys enforce station/route integrity.
-- Denormalization:
--   • route_availability, route_statistics, revenue_summary store aggregates.
--   • reservations caches origin/destination names and fare numbers.
-- Temporality:
--   • vat_rates and fare_policies use effective_from / effective_to windows.
-- ============================================================================

DROP TABLE IF EXISTS reservation_status_history CASCADE;
DROP TABLE IF EXISTS reservations CASCADE;
DROP TABLE IF EXISTS fare_policy_history CASCADE;
DROP TABLE IF EXISTS fare_policies CASCADE;
DROP TABLE IF EXISTS route_timetable_entries CASCADE;
DROP TABLE IF EXISTS route_timetables CASCADE;
DROP TABLE IF EXISTS routes CASCADE;
DROP TABLE IF EXISTS stations CASCADE;
DROP TABLE IF EXISTS passenger_categories CASCADE;
DROP TABLE IF EXISTS vehicle_classes CASCADE;
DROP TABLE IF EXISTS vat_rates CASCADE;
DROP TABLE IF EXISTS route_statistics CASCADE;
DROP TABLE IF EXISTS route_availability CASCADE;
DROP TABLE IF EXISTS revenue_summary CASCADE;

-- Stores the passenger categories for a route
CREATE TABLE passenger_categories (
    category VARCHAR(20) PRIMARY KEY,
    description TEXT,
    -- Discount percentage will be used for determining the price of the ticket
    discount_percentage DECIMAL(5,2) DEFAULT 0.00,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Used for calculating the price of the ticket, so default values are set to not break the fare policy logic
-- Makes validation possible at the database level and ensures data integrity
INSERT INTO passenger_categories (category, description, discount_percentage) VALUES
('ADULT', 'Adult passenger (no discount)', 0.00),
('CHILD', 'Child passenger (eligible for discounts)', 25.00),
('SENIOR', 'Senior citizen (eligible for discounts)', 30.00),
('STUDENT', 'Student (eligible for discounts)', 20.00);

-- Stores the vehicle classes for a route together with the seat capacify for each class
CREATE TABLE vehicle_classes (
    -- routes and reservations reference the vehicle by the class ID, so the class ID must be unique
    class VARCHAR(20) PRIMARY KEY,
    description TEXT,
    -- Seat capacity is the number of seats available for the vehicle class
    seat_capacity INTEGER NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- Safety check to ensure the seat capacity is greater than 0 to prevent negative seat capacities
    CONSTRAINT chk_vehicle_class_capacity CHECK (seat_capacity > 0)
);
-- Predefined vehicle classes are used to provide referential integrity and validation at the database level
INSERT INTO vehicle_classes (class, description, seat_capacity) VALUES
('STANDARD', 'Standard intercity bus', 50),
('COACH', 'Long-distance, higher-comfort bus', 60),
('MINI_BUS', 'Smaller van or shuttle', 28),
('DOUBLE_DECKER', 'Two-level bus', 80);

CREATE TABLE stations (
    -- SERIAL is a 32-bit integer that is automatically incremented by 1
    id SERIAL PRIMARY KEY,
    -- Stations must have a name and there cannot be two stations with the same name
    name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT,
    -- Stations must have a status and the default status is ACTIVE
    -- validate_station_status trigger will ensure that a station cannot be closed if there are routes using it
    status VARCHAR(50) NOT NULL DEFAULT 'ACTIVE',
    -- Address is optional but when provided must be unique
    address TEXT,
    -- created_at and updated_at are the timestamps of the station creation and last update
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- updated_at value will be kept up to date by the updated_at trigger
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, 
    created_by VARCHAR(100),
    -- updated_by value will be kept up to date by the updated_at trigger
    updated_by VARCHAR(100),
    -- Safety check to ensure the name is between 2 and 100 characters
    CONSTRAINT chk_station_name_length CHECK (CHAR_LENGTH(name) BETWEEN 2 AND 100),
    -- Safety check to ensure the status is one of the allowed values in order to provide data consistency and integrity
    CONSTRAINT chk_station_status CHECK (status IN ('ACTIVE', 'INACTIVE', 'MAINTENANCE', 'CLOSED')),
    -- Safety check to ensure no two stations share the same address in order to provide data consistency and integrity
    CONSTRAINT uq_station_address UNIQUE (address)
);

-- Stores the routes between stations
CREATE TABLE routes (
    -- SERIAL is a 32-bit integer that is automatically incremented by 1
    id SERIAL PRIMARY KEY,
    -- Route must have an origin_station_id which is populated with a value from the stations table
    origin_station_id INTEGER NOT NULL,
    -- Route must have a destination_station_id which is populated with a value from the stations table
    destination_station_id INTEGER NOT NULL,
    -- Route must have a vehicle class which determines the seat capacity
    vehicle_class VARCHAR(20) NOT NULL,
    -- Route must have a distance in kilometers to influence fare calculations
    distance_km DECIMAL(10, 2) NOT NULL,
    -- status is the status of the route and the default status is ACTIVE
    -- status can be used to hide routes that are not currently in use, or to prevent reservations from being made on an unavailable route
    status VARCHAR(50) NOT NULL DEFAULT 'ACTIVE',
    -- created_at and updated_at are the timestamps of the route creation and last update
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- updated_at value will be kept up to date by the updated_at trigger
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- created_by and updated_by are the usernames of the users who created and updated the route
    created_by VARCHAR(100),
    -- updated_by value will be kept up to date by the updated_at trigger
    updated_by VARCHAR(100),
    -- Foreign keys to the stations table
    -- ON DELETE RESTRICT will prevent the route from being deleted if the origin or destination station is deleted
    CONSTRAINT fk_route_origin FOREIGN KEY (origin_station_id)
        REFERENCES stations(id) ON DELETE RESTRICT,
    CONSTRAINT fk_route_destination FOREIGN KEY (destination_station_id)
        REFERENCES stations(id) ON DELETE RESTRICT,
    -- Ensure the vehicle class assigned to the route exists
    CONSTRAINT fk_route_vehicle_class FOREIGN KEY (vehicle_class)
        REFERENCES vehicle_classes(class) ON DELETE RESTRICT,
    -- Safety check to ensure the distance is greater than 0
    CONSTRAINT chk_route_distance CHECK (distance_km > 0),
    -- Safety check to ensure the origin and destination stations are different to prevent circular routes
    CONSTRAINT chk_route_different_stations CHECK (origin_station_id <> destination_station_id),
    -- Safety check to ensure the status is one of the allowed values which provides data consistency and integrity
    CONSTRAINT chk_route_status CHECK (status IN ('ACTIVE', 'INACTIVE', 'SUSPENDED', 'DISCONTINUED'))
);

-- Stores the timetables for a route
CREATE TABLE route_timetables (
    -- SERIAL is a 32-bit integer that is automatically incremented by 1
    id SERIAL PRIMARY KEY,
    -- Route must have a route_id which is populated with a value from the routes table
    route_id INTEGER NOT NULL,
    -- Route timetable must have a name
    name VARCHAR(100) NOT NULL,
    -- Route timetable must have a description
    description TEXT,
    -- effective_from and effective_to provide support for updating timetables over time without modifying historical data
    -- Route timetable must have an effective_from date
    effective_from DATE NOT NULL,
    -- Route timetable must have an effective_to date
    -- When effective_to is NULL, the route timetable is considered to be active indefinitely
    effective_to DATE,
    -- Route timetable must have a status
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    -- created_at and updated_at are the timestamps of the route timetable creation and last update
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- updated_at value will be kept up to date by the updated_at trigger
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- created_by and updated_by are the usernames of the users who created and updated the route timetable
    created_by VARCHAR(100),
    -- updated_by value will be kept up to date by the updated_at trigger
    updated_by VARCHAR(100),
    -- Foreign key to the routes table
    -- ON DELETE CASCADE will delete the route timetable if the route is deleted
    CONSTRAINT fk_route_timetable_route FOREIGN KEY (route_id)
        REFERENCES routes(id) ON DELETE CASCADE,
    -- Safety check to ensure the effective_to date is after the effective_from date so an inverted window is not possible
    CONSTRAINT chk_route_timetable_dates CHECK (effective_to IS NULL OR effective_to >= effective_from),
    -- Safety check to ensure the status is one of the allowed values which provides data consistency and integrity
    CONSTRAINT chk_route_timetable_status CHECK (status IN ('ACTIVE', 'INACTIVE', 'ARCHIVED'))
);

-- Stores individual timetable entries for a route timetable
CREATE TABLE route_timetable_entries (
    -- SERIAL is a 32-bit integer that is automatically incremented by 1
    id SERIAL PRIMARY KEY,
    -- Route timetable must have a timetable_id which is populated with a value from the route_timetables table
    timetable_id INTEGER NOT NULL,
    -- Route timetable must have a departure_time
    departure_time TIME NOT NULL,
    -- Route timetable must have an arrival_time
    arrival_time TIME NOT NULL,
    -- Route timetable can have notes
    notes TEXT,
    -- created_at and updated_at are the timestamps of the route timetable entry creation and last update
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- updated_at value will be kept up to date by the updated_at trigger
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- created_by and updated_by are the usernames of the users who created and updated the route timetable entry
    created_by VARCHAR(100),
    -- updated_by value will be kept up to date by the updated_at trigger
    updated_by VARCHAR(100),
    -- Foreign key to the route_timetables table
    -- ON DELETE CASCADE will delete the route timetable entry if the route timetable is deleted
    CONSTRAINT fk_timetable_entry FOREIGN KEY (timetable_id)
        REFERENCES route_timetables(id) ON DELETE CASCADE,
    -- Safety check to ensure the arrival time is after the departure time so an inverted window is not possible
    CONSTRAINT chk_timetable_entry_times CHECK (arrival_time > departure_time),
    -- Safety check to ensure no two timetable entries share the same timetable_id and departure_time so an inverted window is not possible
    CONSTRAINT uq_timetable_entry UNIQUE (timetable_id, departure_time)
);

-- Stores the fare pricing policies for passenger categories (applies globally to all routes)
CREATE TABLE fare_policies (
    -- SERIAL is a 32-bit integer that is automatically incremented by 1
    id SERIAL PRIMARY KEY,
    -- Fare policy must have a passenger category which is populated with a value from the passenger_categories table
    passenger_category VARCHAR(20) NOT NULL,
    -- Fare policy must have a base price per kilometer for the passenger category
    base_price DECIMAL(10, 2) NOT NULL,
    -- Fare policy must have an effective from date
    effective_from TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- Fare policy must have an effective to date
    -- When effective_to is NULL, the fare policy is considered to be active indefinitely
    effective_to TIMESTAMP,
    -- Fare policy must have a status
    -- The status can be used to hide fare policies that are not currently in use, or to prevent reservations from being made on an unavailable fare policy
    status VARCHAR(50) NOT NULL DEFAULT 'ACTIVE',
    -- created_at and updated_at are the timestamps of the fare policy creation and last update
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- updated_at value will be kept up to date by the updated_at trigger
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- created_by and updated_by are the usernames of the users who created and updated the fare policy
    created_by VARCHAR(100),
    -- updated_by value will be kept up to date by the updated_at trigger
    updated_by VARCHAR(100),
    -- Foreign key to the passenger_categories table
    -- ON DELETE RESTRICT will prevent the fare policy from being deleted if the passenger category is deleted
    CONSTRAINT fk_fare_policy_category FOREIGN KEY (passenger_category)
        REFERENCES passenger_categories(category) ON DELETE RESTRICT,
    -- Safety check to ensure the base price is greater than 0 to prevent negative base prices
    CONSTRAINT chk_fare_price CHECK (base_price >= 0),
    -- Safety check to ensure the effective to date is after the effective from date so an inverted window is not possible
    CONSTRAINT chk_fare_effective_period CHECK (effective_to IS NULL OR effective_to > effective_from),
    -- Safety check to ensure the status is one of the allowed values which provides data consistency and integrity
    CONSTRAINT chk_fare_status CHECK (status IN ('ACTIVE', 'INACTIVE', 'EXPIRED'))
);

CREATE TABLE reservations (
    -- SERIAL is a 32-bit integer that is automatically incremented by 1
    id SERIAL PRIMARY KEY,
    -- Reservation must have a route_id which is populated with a value from the routes table
    route_id INTEGER NOT NULL,
    -- Reservation must have a passenger name
    passenger_name VARCHAR(100) NOT NULL,
    -- Reservation must have a passenger email
    passenger_email VARCHAR(255),
    -- Reservation must have a passenger phone
    passenger_phone VARCHAR(20),
    -- Reservation must have a seat count
    seat_count INTEGER NOT NULL DEFAULT 1,
    -- Reservation must have a status
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
    -- Reservation must have a passenger category
    passenger_category VARCHAR(20) NOT NULL,
    -- Reservation must have a vehicle class
    vehicle_class VARCHAR(20) NOT NULL,
    -- origin_station_name is populated from the origin_station_id of the route using the update_reservation_denormalized_fields trigger
    origin_station_name VARCHAR(100),
    -- destination_station_name is populated from the destination_station_id of the route using the update_reservation_denormalized_fields trigger
    destination_station_name VARCHAR(100),
    -- Reservation base fare is calculated based on the passenger category and distance of the route
    -- base_fare will be used as a starting point before VAT is applied
    -- base_fare will store the calculated base fare at the time of the reservation even though the fare policy may change later
    base_fare DECIMAL(10, 2),
    -- Reservation VAT amount is calculated based on the base fare
    -- vat_amount will store the calculated VAT amount at the time of the reservation even though the VAT rate may change later
    vat_amount DECIMAL(10, 2),
    -- Reservation total fare is calculated based on the base fare and VAT amount
    -- total_fare will store the calculated total fare at the time of the reservation even though the fare policy or VAT rate may change later
    total_fare DECIMAL(10, 2),
    -- departure_time should be populated by the application - the schema does not populate this field
    departure_time TIMESTAMP NOT NULL,
    -- arrival_time should be populated by the application - the schema does not populate this field
    arrival_time TIMESTAMP NOT NULL,
    -- created_at and updated_at are the timestamps of the reservation creation and last update
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- updated_at value will be kept up to date by the updated_at trigger
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- cancelled_at and cancelled_by are the timestamps and username of the user who cancelled the reservation
    cancelled_at TIMESTAMP,
    -- cancelled_by is the username of the user who cancelled the reservation
    cancelled_by VARCHAR(100),
    -- cancellation_reason is the reason for the cancellation
    cancellation_reason TEXT,
    -- created_by is the username of the user who created the reservation
    created_by VARCHAR(100),
    -- updated_by value will be kept up to date by the updated_at trigger
    updated_by VARCHAR(100),
    -- Foreign key to the routes table
    -- ON DELETE RESTRICT will prevent the reservation from being deleted if the route is deleted
    CONSTRAINT fk_reservation_route FOREIGN KEY (route_id)
        REFERENCES routes(id) ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_category FOREIGN KEY (passenger_category)
        REFERENCES passenger_categories(category) ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_vehicle_class FOREIGN KEY (vehicle_class)
        REFERENCES vehicle_classes(class) ON DELETE RESTRICT,
    -- Safety check to ensure the seat count is between 1 and 10 to prevent invalid seat counts
    CONSTRAINT chk_reservation_seat_count CHECK (seat_count BETWEEN 1 AND 10),
    -- Safety check to ensure the status is one of the allowed values which provides data consistency and integrity
    CONSTRAINT chk_reservation_status CHECK (status IN ('PENDING', 'CONFIRMED', 'CANCELLED', 'COMPLETED', 'NO_SHOW')),
    -- Safety check to ensure the arrival time is after the departure time so an inverted window is not possible
    CONSTRAINT chk_reservation_times CHECK (arrival_time > departure_time),
    -- Safety check to ensure the departure time is in the future to prevent reservations for past trips
    CONSTRAINT chk_reservation_future_departure CHECK (departure_time > CURRENT_TIMESTAMP - INTERVAL '1 day'),
    -- Safety check to ensure the passenger email includes an '@' and a dot after it (lightweight validation)
    CONSTRAINT chk_reservation_email_format CHECK (
        passenger_email IS NULL
        OR (
            position('@' IN passenger_email) > 1
            AND position('.' IN substr(passenger_email, position('@' IN passenger_email) + 1)) > 1
        )
    )
);

-- Stores the VAT rates for the system
-- rate_percentage and effective_from/effective_to fields are used by the get_current_vat_rate and get_vat_rate_for_date functions
-- calculate_reservation_fare function uses the rate_percentage and effective_from/effective_to fields to calculate the VAT amount
CREATE TABLE vat_rates (
    -- SERIAL is a 32-bit integer that is automatically incremented by 1
    id SERIAL PRIMARY KEY,
    -- VAT rate must have a rate percentage
    rate_percentage DECIMAL(5, 2) NOT NULL,
    -- VAT rate must have an effective from date
    effective_from TIMESTAMP NOT NULL,
    -- VAT rate must have an effective to date
    -- When effective_to is NULL, the VAT rate is considered to be active indefinitely
    effective_to TIMESTAMP,
    -- VAT rate can have a description
    description TEXT,
    -- VAT rate must have a status
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    -- created_at and updated_at are the timestamps of the VAT rate creation and last update
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- updated_at value will be kept up to date by the updated_at trigger
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- created_by and updated_by are the usernames of the users who created and updated the VAT rate
    created_by VARCHAR(100),
    -- updated_by value will be kept up to date by the updated_at trigger
    updated_by VARCHAR(100),
    -- Safety check to ensure the rate percentage is between 0 and 100 to prevent invalid rate percentages
    CONSTRAINT chk_vat_rate CHECK (rate_percentage BETWEEN 0 AND 100),
    -- Safety check to ensure the effective to date is after the effective from date so an inverted window is not possible
    CONSTRAINT chk_vat_effective_period CHECK (effective_to IS NULL OR effective_to > effective_from),
    -- Safety check to ensure the status is one of the allowed values which provides data consistency and integrity
    CONSTRAINT chk_vat_status CHECK (status IN ('ACTIVE', 'INACTIVE', 'EXPIRED'))
);

-- Stores the history of fare policy changes
-- Supports the maintain_fare_policy_history trigger
-- Supports the audit trail for fare policy changes (created_at, created_by, updated_at, updated_by)
-- Supports temporality and compliance
CREATE TABLE fare_policy_history (
    -- SERIAL is a 32-bit integer that is automatically incremented by 1
    id SERIAL PRIMARY KEY,
    -- Fare policy history must have a fare policy id
    fare_policy_id INTEGER NOT NULL,
    -- Fare policy history must have a passenger category
    passenger_category VARCHAR(20) NOT NULL,
    -- Fare policy history must have a base price
    base_price DECIMAL(10, 2) NOT NULL,
    -- Fare policy history must have an old price
    old_price DECIMAL(10, 2),
    -- Fare policy history must have a change type
    change_type VARCHAR(20) NOT NULL,
    -- Fare policy history must have an effective from date
    effective_from TIMESTAMP NOT NULL,
    -- Fare policy history must have an effective to date
    -- When effective_to is NULL, the fare policy history is considered to be active indefinitely
    effective_to TIMESTAMP,
    -- Fare policy history must have a changed at timestamp
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- Fare policy history must have a changed by username
    changed_by VARCHAR(100),
    -- Fare policy history must have a change reason
    change_reason TEXT,
    -- Foreign key to the fare_policies table
    -- ON DELETE CASCADE will delete the fare policy history if the fare policy is deleted
    CONSTRAINT fk_fare_history_policy FOREIGN KEY (fare_policy_id)
        REFERENCES fare_policies(id) ON DELETE CASCADE,
    -- Safety check to ensure the change type is one of the allowed values which provides data consistency and integrity
    CONSTRAINT chk_fare_history_change_type CHECK (change_type IN ('CREATED', 'UPDATED', 'DELETED', 'ACTIVATED', 'DEACTIVATED'))
);

-- Stores the history of reservation status changes
-- Supports the maintain_reservation_status_history trigger
-- Supports the audit trail for reservation status changes (created_at, created_by, updated_at, updated_by)
-- Supports temporality and compliance
CREATE TABLE reservation_status_history (
    -- SERIAL is a 32-bit integer that is automatically incremented by 1
    id SERIAL PRIMARY KEY,
    -- Reservation status history must have a reservation id
    reservation_id INTEGER NOT NULL,
    -- Reservation status history must have an old status
    old_status VARCHAR(50),
    -- Reservation status history must have a new status
    new_status VARCHAR(50) NOT NULL,
    -- Reservation status history must have a changed at timestamp
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- Reservation status history must have a changed by username
    changed_by VARCHAR(100),
    -- Reservation status history must have a change reason
    change_reason TEXT,
    -- Foreign key to the reservations table
    -- ON DELETE CASCADE will delete the reservation status history if the reservation is deleted
    CONSTRAINT fk_reservation_history FOREIGN KEY (reservation_id)
        REFERENCES reservations(id) ON DELETE CASCADE
);

-- Stores the availability of seats for a route
-- Denormalized table to store the current seat availability for a route
-- Supports the update_route_availability_trigger trigger which fires after every insert/update/delete on the reservations table
-- update_route_availability_trigger calls the update_route_availability procedure which recalculates the available seats
CREATE TABLE route_availability (
    -- Route availability must have a route id
    route_id INTEGER PRIMARY KEY,
    -- Route availability must have a total capacity
    total_capacity INTEGER NOT NULL,
    -- Route availability must have a booked seats
    booked_seats INTEGER NOT NULL DEFAULT 0,
    -- Route availability must have a available seats
    available_seats INTEGER NOT NULL,
    -- Route availability must have a last updated timestamp
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- Foreign key to the routes table
    -- ON DELETE CASCADE will delete the route availability if the route is deleted
    CONSTRAINT fk_route_availability FOREIGN KEY (route_id)
        REFERENCES routes(id) ON DELETE CASCADE,
    -- Safety check to ensure the booked seats is greater than or equal to 0 to prevent invalid booked seats
    CONSTRAINT chk_availability_seats CHECK (booked_seats >= 0 AND available_seats >= 0),
    -- Safety check to ensure the total capacity is greater than or equal to the booked seats and available seats to prevent invalid total capacity
    -- The total capacity is the sum of the booked seats and available seats
    CONSTRAINT chk_availability_capacity CHECK (booked_seats + available_seats <= total_capacity)
);

CREATE TABLE route_statistics (
    route_id BIGINT PRIMARY KEY,
    total_reservations INTEGER DEFAULT 0,
    confirmed_reservations INTEGER DEFAULT 0,
    cancelled_reservations INTEGER DEFAULT 0,
    total_revenue DECIMAL(15, 2) DEFAULT 0.00,
    average_occupancy_rate DECIMAL(5, 2) DEFAULT 0.00,
    last_calculated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_route_statistics FOREIGN KEY (route_id)
        REFERENCES routes(id) ON DELETE CASCADE,
    CONSTRAINT chk_statistics_reservations CHECK (total_reservations >= 0),
    CONSTRAINT chk_statistics_revenue CHECK (total_revenue >= 0),
    CONSTRAINT chk_statistics_occupancy CHECK (average_occupancy_rate BETWEEN 0 AND 100)
);

CREATE TABLE revenue_summary (
    id SERIAL PRIMARY KEY,
    summary_date DATE NOT NULL,
    route_id BIGINT,
    passenger_category VARCHAR(20),
    vehicle_class VARCHAR(20),
    reservation_count INTEGER DEFAULT 0,
    total_revenue DECIMAL(15, 2) DEFAULT 0.00,
    total_vat DECIMAL(15, 2) DEFAULT 0.00,
    net_revenue DECIMAL(15, 2) DEFAULT 0.00,
    calculated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_revenue_route FOREIGN KEY (route_id)
        REFERENCES routes(id) ON DELETE SET NULL,
    CONSTRAINT fk_revenue_category FOREIGN KEY (passenger_category)
        REFERENCES passenger_categories(category) ON DELETE SET NULL,
    CONSTRAINT fk_revenue_vehicle_class FOREIGN KEY (vehicle_class)
        REFERENCES vehicle_classes(class) ON DELETE SET NULL,
    CONSTRAINT chk_revenue_summary CHECK (reservation_count >= 0 AND total_revenue >= 0)
);

-- ============================================================================
-- SECTION 2: FUNCTIONS & PROCEDURES
-- ----------------------------------------------------------------------------
-- Functions encapsulate VAT / fare lookups, seat availability checks, revenue
-- calculations, and timetable analytics.
-- Special cases & exceptions:
--   • Each critical function/procedure validates prerequisites and raises a
--     descriptive exception (e.g., missing route, duplicate policy).
-- Denormalization:
--   • Stored procedures refresh aggregated tables after changes.
-- Temporality:
--   • VAT and fare helpers accept timestamps so historic queries return the
--     correct values.
-- ============================================================================

-- Helper functions -----------------------------------------------------------
CREATE OR REPLACE FUNCTION get_current_vat_rate()
RETURNS DECIMAL(5, 2) AS $$
DECLARE
    current_rate DECIMAL(5, 2);
BEGIN
    SELECT rate_percentage INTO current_rate
    FROM vat_rates
    WHERE effective_from <= CURRENT_TIMESTAMP
      AND (effective_to IS NULL OR effective_to > CURRENT_TIMESTAMP)
    ORDER BY effective_from DESC
    LIMIT 1;
    
    IF current_rate IS NULL THEN
        RETURN 0.00;
    END IF;
    
    RETURN current_rate;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_vat_rate_for_date(check_date TIMESTAMP)
RETURNS DECIMAL(5, 2) AS $$
DECLARE
    rate DECIMAL(5, 2);
BEGIN
    SELECT rate_percentage INTO rate
    FROM vat_rates
    WHERE effective_from <= check_date
      AND (effective_to IS NULL OR effective_to > check_date)
    ORDER BY effective_from DESC
    LIMIT 1;
    
    IF rate IS NULL THEN
        RETURN 0.00;
    END IF;
    
    RETURN rate;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_active_fare_policy(
    p_passenger_category VARCHAR(20),
    p_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
RETURNS DECIMAL(10, 2) AS $$
DECLARE
    fare_price DECIMAL(10, 2);
BEGIN
    SELECT base_price INTO fare_price
    FROM fare_policies
    WHERE passenger_category = p_passenger_category
      AND status = 'ACTIVE'
      AND effective_from <= p_date
      AND (effective_to IS NULL OR effective_to > p_date)
    ORDER BY effective_from DESC
    LIMIT 1;
    
    IF fare_price IS NULL THEN
        RAISE EXCEPTION 'No active fare policy found for category %', 
            p_passenger_category;
    END IF;
    
    RETURN fare_price;
END;
$$ LANGUAGE plpgsql;

-- Fare calculation -----------------------------------------------------------
CREATE OR REPLACE FUNCTION calculate_fare_with_vat(
    p_base_price DECIMAL(10, 2),
    p_seat_count INTEGER,
    p_vat_rate DECIMAL(5, 2) DEFAULT NULL
)
RETURNS TABLE (
    base_fare DECIMAL(10, 2),
    vat_amount DECIMAL(10, 2),
    total_fare DECIMAL(10, 2)
) AS $$
DECLARE
    v_vat_rate DECIMAL(5, 2);
    v_base_total DECIMAL(10, 2);
    v_vat_amount DECIMAL(10, 2);
    v_total_fare DECIMAL(10, 2);
BEGIN
    IF p_vat_rate IS NULL THEN
        v_vat_rate := get_current_vat_rate();
    ELSE
        v_vat_rate := p_vat_rate;
    END IF;
    
    v_base_total := p_base_price * p_seat_count;
    v_vat_amount := ROUND(v_base_total * (v_vat_rate / 100.0), 2);
    v_total_fare := v_base_total + v_vat_amount;
    
    RETURN QUERY SELECT v_base_total, v_vat_amount, v_total_fare;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_reservation_fare(
    p_route_id INTEGER,
    p_passenger_category VARCHAR(20),
    p_seat_count INTEGER,
    p_reservation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
RETURNS TABLE (
    base_fare DECIMAL(10, 2),
    vat_amount DECIMAL(10, 2),
    total_fare DECIMAL(10, 2),
    vat_rate DECIMAL(5, 2)
) AS $$
DECLARE
    v_base_price DECIMAL(10, 2);
    v_vat_rate DECIMAL(5, 2);
    v_calculated_fare RECORD;
    v_distance DECIMAL(10, 2);
    v_base_price_per_seat DECIMAL(10, 2);
BEGIN
    v_base_price := get_active_fare_policy(p_passenger_category, p_reservation_date);
    v_vat_rate := get_vat_rate_for_date(p_reservation_date);
    
    SELECT distance_km INTO v_distance
    FROM routes
    WHERE id = p_route_id;
    
    IF v_distance IS NULL THEN
        RAISE EXCEPTION 'Route % not found when calculating reservation fare', p_route_id;
    END IF;
    
    v_base_price_per_seat := v_base_price * v_distance;
    
    SELECT * INTO v_calculated_fare
    FROM calculate_fare_with_vat(v_base_price_per_seat, p_seat_count, v_vat_rate);
    
    RETURN QUERY SELECT 
        v_calculated_fare.base_fare,
        v_calculated_fare.vat_amount,
        v_calculated_fare.total_fare,
        v_vat_rate;
END;
$$ LANGUAGE plpgsql;

-- Availability and analytics helpers ----------------------------------------
CREATE OR REPLACE FUNCTION check_seat_availability(
    p_route_id INTEGER,
    p_required_seats INTEGER
)
RETURNS BOOLEAN AS $$
DECLARE
    v_available_seats INTEGER;
BEGIN
    SELECT available_seats INTO v_available_seats
    FROM route_availability
    WHERE route_id = p_route_id;
    
    IF v_available_seats IS NULL THEN
        RETURN FALSE;
    END IF;
    
    RETURN v_available_seats >= p_required_seats;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_available_seats(p_route_id INTEGER)
RETURNS INTEGER AS $$
DECLARE
    v_available_seats INTEGER;
BEGIN
    SELECT available_seats INTO v_available_seats
    FROM route_availability
    WHERE route_id = p_route_id;
    
    IF v_available_seats IS NULL THEN
        RETURN 0;
    END IF;
    
    RETURN v_available_seats;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_booked_seats(
    p_route_id INTEGER,
    p_departure_time TIMESTAMP,
    p_arrival_time TIMESTAMP
)
RETURNS INTEGER AS $$
DECLARE
    v_booked_seats INTEGER;
BEGIN
    SELECT COALESCE(SUM(seat_count), 0) INTO v_booked_seats
    FROM reservations
    WHERE route_id = p_route_id
      AND status IN ('PENDING', 'CONFIRMED')
      AND departure_time < p_arrival_time
      AND arrival_time > p_departure_time;
    
    RETURN v_booked_seats;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_total_revenue()
RETURNS DECIMAL(15, 2) AS $$
DECLARE
    v_total_revenue DECIMAL(15, 2);
BEGIN
    SELECT COALESCE(SUM(total_fare), 0.00) INTO v_total_revenue
    FROM reservations
    WHERE status = 'CONFIRMED';
    
    RETURN v_total_revenue;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_route_revenue(p_route_id INTEGER)
RETURNS DECIMAL(15, 2) AS $$
DECLARE
    v_revenue DECIMAL(15, 2);
BEGIN
    SELECT COALESCE(SUM(total_fare), 0.00) INTO v_revenue
    FROM reservations
    WHERE route_id = p_route_id
      AND status = 'CONFIRMED';
    
    RETURN v_revenue;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_revenue_for_period(
    p_start_date TIMESTAMP,
    p_end_date TIMESTAMP
)
RETURNS TABLE (
    total_revenue DECIMAL(15, 2),
    total_vat DECIMAL(15, 2),
    net_revenue DECIMAL(15, 2),
    reservation_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COALESCE(SUM(total_fare), 0.00),
        COALESCE(SUM(vat_amount), 0.00),
        COALESCE(SUM(base_fare), 0.00),
        COUNT(*)
    FROM reservations
    WHERE status = 'CONFIRMED'
      AND created_at BETWEEN p_start_date AND p_end_date;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_route_statistics(p_route_id INTEGER)
RETURNS TABLE (
    total_reservations BIGINT,
    confirmed_reservations BIGINT,
    cancelled_reservations BIGINT,
    total_revenue DECIMAL(15, 2),
    average_occupancy_rate DECIMAL(5, 2)
) AS $$
DECLARE
    v_total_capacity INTEGER;
    v_total_reservations BIGINT;
    v_confirmed_reservations BIGINT;
    v_cancelled_reservations BIGINT;
    v_total_revenue DECIMAL(15, 2);
    v_avg_occupancy DECIMAL(5, 2);
BEGIN
    SELECT vc.seat_capacity INTO v_total_capacity
    FROM routes r
    JOIN vehicle_classes vc ON r.vehicle_class = vc.class
    WHERE r.id = p_route_id;
    
    IF v_total_capacity IS NULL THEN
        RAISE EXCEPTION 'Seat capacity not defined for route %', p_route_id;
    END IF;
    
    SELECT 
        COUNT(*),
        COUNT(*) FILTER (WHERE status = 'CONFIRMED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED'),
        COALESCE(SUM(total_fare) FILTER (WHERE status = 'CONFIRMED'), 0.00)
    INTO 
        v_total_reservations,
        v_confirmed_reservations,
        v_cancelled_reservations,
        v_total_revenue
    FROM reservations
    WHERE route_id = p_route_id;
    
    IF v_total_reservations > 0 THEN
        SELECT COALESCE(SUM(seat_count), 0) INTO v_avg_occupancy
        FROM reservations
        WHERE route_id = p_route_id AND status = 'CONFIRMED';
        
        v_avg_occupancy := ROUND((v_avg_occupancy::DECIMAL / v_total_capacity::DECIMAL) * 100, 2);
    ELSE
        v_avg_occupancy := 0.00;
    END IF;
    
    RETURN QUERY SELECT 
        v_total_reservations,
        v_confirmed_reservations,
        v_cancelled_reservations,
        v_total_revenue,
        v_avg_occupancy;
END;
$$ LANGUAGE plpgsql;

-- Stored procedures ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE update_route_availability(p_route_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_total_capacity INTEGER;
    v_booked_seats INTEGER;
    v_available_seats INTEGER;
BEGIN
    SELECT vc.seat_capacity INTO v_total_capacity
    FROM routes r
    JOIN vehicle_classes vc ON r.vehicle_class = vc.class
    WHERE r.id = p_route_id;
    
    IF v_total_capacity IS NULL THEN
        RAISE EXCEPTION 'Seat capacity not defined for route %', p_route_id;
    END IF;
    
    SELECT COALESCE(SUM(seat_count), 0) INTO v_booked_seats
    FROM reservations
    WHERE route_id = p_route_id
      AND status IN ('PENDING', 'CONFIRMED');
    
    v_available_seats := GREATEST(0, v_total_capacity - v_booked_seats);
    
    INSERT INTO route_availability (route_id, total_capacity, booked_seats, available_seats, last_updated)
    VALUES (p_route_id, v_total_capacity, v_booked_seats, v_available_seats, CURRENT_TIMESTAMP)
    ON CONFLICT (route_id) 
    DO UPDATE SET
        total_capacity = EXCLUDED.total_capacity,
        booked_seats = EXCLUDED.booked_seats,
        available_seats = EXCLUDED.available_seats,
        last_updated = CURRENT_TIMESTAMP;
END;
$$;

CREATE OR REPLACE PROCEDURE update_route_statistics(p_route_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_stats RECORD;
BEGIN
    SELECT * INTO v_stats
    FROM calculate_route_statistics(p_route_id);
    
    INSERT INTO route_statistics (
        route_id,
        total_reservations,
        confirmed_reservations,
        cancelled_reservations,
        total_revenue,
        average_occupancy_rate,
        last_calculated
    )
    VALUES (
        p_route_id,
        v_stats.total_reservations,
        v_stats.confirmed_reservations,
        v_stats.cancelled_reservations,
        v_stats.total_revenue,
        v_stats.average_occupancy_rate,
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (route_id)
    DO UPDATE SET
        total_reservations = EXCLUDED.total_reservations,
        confirmed_reservations = EXCLUDED.confirmed_reservations,
        cancelled_reservations = EXCLUDED.cancelled_reservations,
        total_revenue = EXCLUDED.total_revenue,
        average_occupancy_rate = EXCLUDED.average_occupancy_rate,
        last_calculated = CURRENT_TIMESTAMP;
END;
$$;

CREATE OR REPLACE PROCEDURE cancel_reservation(
    p_reservation_id BIGINT,
    p_cancelled_by VARCHAR(100),
    p_reason TEXT DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_route_id INTEGER;
    v_current_status VARCHAR(50);
BEGIN
    SELECT route_id, status INTO v_route_id, v_current_status
    FROM reservations
    WHERE id = p_reservation_id;
    
    IF v_route_id IS NULL THEN
        RAISE EXCEPTION 'Reservation % not found', p_reservation_id;
    END IF;
    
    IF v_current_status = 'CANCELLED' THEN
        RAISE EXCEPTION 'Reservation % is already cancelled', p_reservation_id;
    END IF;
    
    IF v_current_status = 'COMPLETED' THEN
        RAISE EXCEPTION 'Cannot cancel a completed reservation (id=%)', p_reservation_id;
    END IF;
    
    UPDATE reservations
    SET status = 'CANCELLED',
        cancelled_at = CURRENT_TIMESTAMP,
        cancelled_by = p_cancelled_by,
        cancellation_reason = p_reason,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_reservation_id;
    
    INSERT INTO reservation_status_history (reservation_id, old_status, new_status, changed_by, change_reason)
    VALUES (p_reservation_id, v_current_status, 'CANCELLED', p_cancelled_by, p_reason);
    
    CALL update_route_availability(v_route_id);
    CALL update_route_statistics(v_route_id);
END;
$$;

CREATE OR REPLACE PROCEDURE confirm_reservation(
    p_reservation_id BIGINT,
    p_confirmed_by VARCHAR(100)
)
LANGUAGE plpgsql AS $$
DECLARE
    v_route_id INTEGER;
    v_current_status VARCHAR(50);
BEGIN
    SELECT route_id, status INTO v_route_id, v_current_status
    FROM reservations
    WHERE id = p_reservation_id;
    
    IF v_route_id IS NULL THEN
        RAISE EXCEPTION 'Reservation % not found', p_reservation_id;
    END IF;
    
    IF v_current_status = 'CONFIRMED' THEN
        RAISE EXCEPTION 'Reservation % is already confirmed', p_reservation_id;
    END IF;
    
    IF v_current_status = 'CANCELLED' THEN
        RAISE EXCEPTION 'Cannot confirm a cancelled reservation (id=%)', p_reservation_id;
    END IF;
    
    UPDATE reservations
    SET status = 'CONFIRMED',
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_confirmed_by
    WHERE id = p_reservation_id;
    
    INSERT INTO reservation_status_history (reservation_id, old_status, new_status, changed_by)
    VALUES (p_reservation_id, v_current_status, 'CONFIRMED', p_confirmed_by);
    
    CALL update_route_availability(v_route_id);
    CALL update_route_statistics(v_route_id);
END;
$$;

CREATE OR REPLACE PROCEDURE generate_revenue_summary(p_summary_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM revenue_summary
    WHERE summary_date = p_summary_date;
    
    INSERT INTO revenue_summary (
        summary_date,
        route_id,
        passenger_category,
        vehicle_class,
        reservation_count,
        total_revenue,
        total_vat,
        net_revenue,
        calculated_at
    )
    SELECT 
        p_summary_date,
        route_id,
        passenger_category,
        vehicle_class,
        COUNT(*),
        SUM(total_fare),
        SUM(vat_amount),
        SUM(base_fare),
        CURRENT_TIMESTAMP
    FROM reservations
    WHERE status = 'CONFIRMED'
      AND DATE(created_at) = p_summary_date
    GROUP BY route_id, passenger_category, vehicle_class;
    
    INSERT INTO revenue_summary (
        summary_date,
        route_id,
        passenger_category,
        vehicle_class,
        reservation_count,
        total_revenue,
        total_vat,
        net_revenue,
        calculated_at
    )
    SELECT 
        p_summary_date,
        NULL,
        NULL,
        NULL,
        COUNT(*),
        SUM(total_fare),
        SUM(vat_amount),
        SUM(base_fare),
        CURRENT_TIMESTAMP
    FROM reservations
    WHERE status = 'CONFIRMED'
      AND DATE(created_at) = p_summary_date;
END;
$$;

CREATE OR REPLACE PROCEDURE initialize_all_route_availability()
LANGUAGE plpgsql AS $$
DECLARE
    route_record RECORD;
BEGIN
    FOR route_record IN SELECT id FROM routes LOOP
        BEGIN
            CALL update_route_availability(route_record.id);
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE PROCEDURE initialize_all_route_statistics()
LANGUAGE plpgsql AS $$
DECLARE
    route_record RECORD;
BEGIN
    FOR route_record IN SELECT id FROM routes LOOP
        BEGIN
            CALL update_route_statistics(route_record.id);
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END LOOP;
END;
$$;

-- ============================================================================
-- SECTION 3: TRIGGERS
-- ----------------------------------------------------------------------------
-- Triggers enforce complex validation, automate denormalized field updates, and
-- maintain audit history.
--
-- Special cases & exceptions:
--   • Seat capacity check runs before insert/update; it considers overlapping
--     reservations and raises capacity errors.
--   • Fare/VAT policy triggers prevent overlapping effective periods.
-- Denormalization:
--   • Reservation trigger fills origin/destination names and fare totals.
--   • Route availability/statistics recalculated automatically after changes.
-- ============================================================================

-- Validation trigger functions ----------------------------------------------
CREATE OR REPLACE FUNCTION validate_route_creation()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.origin_station_id = NEW.destination_station_id THEN
        RAISE EXCEPTION 'Route cannot have the same origin and destination station (circular route not allowed)';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_reservation_times()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.arrival_time <= NEW.departure_time THEN
        RAISE EXCEPTION 'Arrival time must be after departure time';
    END IF;
    IF NEW.departure_time < (CURRENT_TIMESTAMP - INTERVAL '1 day') THEN
        RAISE EXCEPTION 'Departure time cannot be more than 1 day in the past';
    END IF;
    IF NEW.departure_time > (CURRENT_TIMESTAMP + INTERVAL '1 year') THEN
        RAISE EXCEPTION 'Departure time cannot be more than 1 year in the future';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_seat_capacity()
RETURNS TRIGGER AS $$
DECLARE
    v_route_capacity INTEGER;
    v_current_booked INTEGER;
BEGIN
    SELECT vc.seat_capacity INTO v_route_capacity
    FROM routes r
    JOIN vehicle_classes vc ON r.vehicle_class = vc.class
    WHERE r.id = NEW.route_id;
    
    IF v_route_capacity IS NULL THEN
        RAISE EXCEPTION 'Seat capacity not defined for route %', NEW.route_id;
    END IF;
    
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;
    END IF;
    
    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.status IN ('PENDING', 'CONFIRMED')) THEN
        SELECT COALESCE(SUM(seat_count), 0) INTO v_current_booked
        FROM reservations
        WHERE route_id = NEW.route_id
          AND status IN ('PENDING', 'CONFIRMED')
          AND (TG_OP = 'INSERT' OR id != NEW.id)
          AND departure_time < NEW.arrival_time
          AND arrival_time > NEW.departure_time;
        
        IF (v_current_booked + NEW.seat_count) > v_route_capacity THEN
            RAISE EXCEPTION 'Insufficient capacity: Requested % seats, but only % seats available (capacity: %)',
                NEW.seat_count, (v_route_capacity - v_current_booked), v_route_capacity;
        END IF;
        
        IF NEW.seat_count <= 0 THEN
            RAISE EXCEPTION 'Seat count must be greater than 0';
        END IF;
        
        IF NEW.seat_count > 10 THEN
            RAISE EXCEPTION 'Maximum 10 seats can be booked per reservation';
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_fare_policy_dates()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.effective_to IS NOT NULL AND NEW.effective_to <= NEW.effective_from THEN
        RAISE EXCEPTION 'Effective end date must be after effective start date';
    END IF;
    
    IF NEW.status = 'ACTIVE' THEN
        IF EXISTS (
            SELECT 1 FROM fare_policies
            WHERE passenger_category = NEW.passenger_category
              AND status = 'ACTIVE'
              AND id <> NEW.id
              AND (
                  (effective_to IS NULL AND NEW.effective_to IS NULL) OR
                  (effective_to IS NULL AND NEW.effective_from <= CURRENT_TIMESTAMP) OR
                  (NEW.effective_to IS NULL AND effective_from <= CURRENT_TIMESTAMP) OR
                  (NEW.effective_from <= COALESCE(effective_to, '9999-12-31'::TIMESTAMP)
                   AND COALESCE(NEW.effective_to, '9999-12-31'::TIMESTAMP) >= effective_from)
              )
        ) THEN
            RAISE EXCEPTION 'Overlapping active fare policy exists for category %',
                NEW.passenger_category;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_vat_rate_dates()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.effective_to IS NOT NULL AND NEW.effective_to <= NEW.effective_from THEN
        RAISE EXCEPTION 'Effective end date must be after effective start date';
    END IF;
    
    IF EXISTS (
        SELECT 1 FROM vat_rates
        WHERE id <> NEW.id
          AND NEW.effective_from <= COALESCE(effective_to, '9999-12-31'::TIMESTAMP)
          AND COALESCE(NEW.effective_to, '9999-12-31'::TIMESTAMP) >= effective_from
    ) THEN
        RAISE EXCEPTION 'Overlapping VAT rate exists for the specified date range';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_station_status()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'CLOSED' AND OLD.status <> 'CLOSED' THEN
        IF EXISTS (
            SELECT 1 FROM routes
            WHERE (origin_station_id = NEW.id OR destination_station_id = NEW.id)
              AND status = 'ACTIVE'
        ) THEN
            RAISE EXCEPTION 'Cannot close station % because it has active routes', NEW.name;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_reservation_denormalized_fields()
RETURNS TRIGGER AS $$
DECLARE
    v_origin_name VARCHAR(100);
    v_destination_name VARCHAR(100);
    v_route_class VARCHAR(20);
    v_base_price DECIMAL(10, 2);
    v_distance DECIMAL(10, 2);
    v_base_price_per_seat DECIMAL(10, 2);
    v_fare_calc RECORD;
BEGIN
    IF TG_OP = 'INSERT' OR 
       (TG_OP = 'UPDATE' AND (
           OLD.route_id <> NEW.route_id OR
           OLD.passenger_category <> NEW.passenger_category OR
           OLD.seat_count <> NEW.seat_count
       )) THEN
        
        SELECT 
            origin.name,
            destination.name,
            r.vehicle_class,
            r.distance_km
        INTO 
            v_origin_name,
            v_destination_name,
            v_route_class,
            v_distance
        FROM routes r
        JOIN stations origin ON r.origin_station_id = origin.id
        JOIN stations destination ON r.destination_station_id = destination.id
        WHERE r.id = NEW.route_id;
        
        NEW.vehicle_class := v_route_class;
        
        BEGIN
            v_base_price := get_active_fare_policy(
                NEW.passenger_category,
                COALESCE(NEW.departure_time, CURRENT_TIMESTAMP)
            );
        EXCEPTION
            WHEN OTHERS THEN
                v_base_price := 0.00;
        END;
        
        v_base_price_per_seat := v_base_price * COALESCE(v_distance, 0);
        
        SELECT * INTO v_fare_calc
        FROM calculate_fare_with_vat(
            v_base_price_per_seat,
            NEW.seat_count,
            get_vat_rate_for_date(COALESCE(NEW.departure_time, CURRENT_TIMESTAMP)::timestamp)
        );
        
        NEW.origin_station_name := v_origin_name;
        NEW.destination_station_name := v_destination_name;
        NEW.base_fare := v_fare_calc.base_fare;
        NEW.vat_amount := v_fare_calc.vat_amount;
        NEW.total_fare := v_fare_calc.total_fare;
    END IF;
    
    IF TG_OP = 'UPDATE' THEN
        NEW.updated_at := CURRENT_TIMESTAMP;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_route_availability_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_route_id INTEGER;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_route_id := OLD.route_id;
    ELSE
        v_route_id := NEW.route_id;
    END IF;
    
    CALL update_route_availability(v_route_id);
    CALL update_route_statistics(v_route_id);
    
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION maintain_reservation_status_history()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.status <> NEW.status THEN
        INSERT INTO reservation_status_history (
            reservation_id,
            old_status,
            new_status,
            changed_at,
            changed_by,
            change_reason
        )
        VALUES (
            NEW.id,
            OLD.status,
            NEW.status,
            CURRENT_TIMESTAMP,
            NEW.updated_by,
            CASE 
                WHEN NEW.status = 'CANCELLED' THEN NEW.cancellation_reason
                ELSE NULL
            END
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION maintain_fare_policy_history()
RETURNS TRIGGER AS $$
DECLARE
    v_change_type VARCHAR(20);
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_change_type := 'CREATED';
        INSERT INTO fare_policy_history (
            fare_policy_id,
            passenger_category,
            base_price,
            old_price,
            change_type,
            effective_from,
            effective_to,
            changed_at,
            changed_by
        )
        VALUES (
            NEW.id,
            NEW.passenger_category,
            NEW.base_price,
            NULL,
            v_change_type,
            NEW.effective_from,
            NEW.effective_to,
            CURRENT_TIMESTAMP,
            NEW.created_by
        );
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.status <> NEW.status THEN
            IF NEW.status = 'ACTIVE' THEN
                v_change_type := 'ACTIVATED';
            ELSIF NEW.status = 'INACTIVE' THEN
                v_change_type := 'DEACTIVATED';
            ELSE
                v_change_type := 'UPDATED';
            END IF;
        ELSE
            v_change_type := 'UPDATED';
        END IF;
        
        IF OLD.base_price <> NEW.base_price OR 
           OLD.status <> NEW.status OR
           OLD.effective_from <> NEW.effective_from OR
           OLD.effective_to <> NEW.effective_to THEN
            
            INSERT INTO fare_policy_history (
                fare_policy_id,
                passenger_category,
                base_price,
                old_price,
                change_type,
                effective_from,
                effective_to,
                changed_at,
                changed_by
            )
            VALUES (
                NEW.id,
                NEW.passenger_category,
                NEW.base_price,
                OLD.base_price,
                v_change_type,
                NEW.effective_from,
                NEW.effective_to,
                CURRENT_TIMESTAMP,
                NEW.updated_by
            );
        END IF;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO fare_policy_history (
            fare_policy_id,
            passenger_category,
            base_price,
            old_price,
            change_type,
            effective_from,
            effective_to,
            changed_at,
            changed_by
        )
        VALUES (
            OLD.id,
            OLD.passenger_category,
            NULL,
            OLD.base_price,
            'DELETED',
            OLD.effective_from,
            OLD.effective_to,
            CURRENT_TIMESTAMP,
            'SYSTEM'
        );
    END IF;
    
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_route_on_change()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    
    IF TG_OP = 'UPDATE' AND OLD.vehicle_class <> NEW.vehicle_class THEN
        CALL update_route_availability(NEW.id);
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_station_on_change()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    
    IF TG_OP = 'UPDATE' AND OLD.name <> NEW.name THEN
        UPDATE reservations
        SET origin_station_name = NEW.name
        WHERE route_id IN (
            SELECT id FROM routes WHERE origin_station_id = NEW.id
        );
        
        UPDATE reservations
        SET destination_station_name = NEW.name
        WHERE route_id IN (
            SELECT id FROM routes WHERE destination_station_id = NEW.id
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_validate_route_creation
    BEFORE INSERT OR UPDATE ON routes
    FOR EACH ROW
    EXECUTE FUNCTION validate_route_creation();

CREATE TRIGGER trigger_validate_reservation_times
    BEFORE INSERT OR UPDATE ON reservations
    FOR EACH ROW
    EXECUTE FUNCTION validate_reservation_times();

CREATE TRIGGER trigger_validate_seat_capacity
    BEFORE INSERT OR UPDATE ON reservations
    FOR EACH ROW
    EXECUTE FUNCTION validate_seat_capacity();

CREATE TRIGGER trigger_validate_fare_policy_dates
    BEFORE INSERT OR UPDATE ON fare_policies
    FOR EACH ROW
    EXECUTE FUNCTION validate_fare_policy_dates();

CREATE TRIGGER trigger_validate_vat_rate_dates
    BEFORE INSERT OR UPDATE ON vat_rates
    FOR EACH ROW
    EXECUTE FUNCTION validate_vat_rate_dates();

CREATE TRIGGER trigger_validate_station_status
    BEFORE UPDATE ON stations
    FOR EACH ROW
    EXECUTE FUNCTION validate_station_status();

CREATE TRIGGER trigger_update_reservation_denormalized
    BEFORE INSERT OR UPDATE ON reservations
    FOR EACH ROW
    EXECUTE FUNCTION update_reservation_denormalized_fields();

CREATE TRIGGER trigger_update_route_availability
    AFTER INSERT OR UPDATE OR DELETE ON reservations
    FOR EACH ROW
    EXECUTE FUNCTION update_route_availability_trigger();

CREATE TRIGGER trigger_maintain_reservation_status_history
    AFTER UPDATE ON reservations
    FOR EACH ROW
    EXECUTE FUNCTION maintain_reservation_status_history();

CREATE TRIGGER trigger_maintain_fare_policy_history
    AFTER INSERT OR UPDATE OR DELETE ON fare_policies
    FOR EACH ROW
    EXECUTE FUNCTION maintain_fare_policy_history();

CREATE TRIGGER trigger_update_route_on_change
    BEFORE UPDATE ON routes
    FOR EACH ROW
    EXECUTE FUNCTION update_route_on_change();

CREATE TRIGGER trigger_update_station_on_change
    BEFORE UPDATE ON stations
    FOR EACH ROW
    EXECUTE FUNCTION update_station_on_change();

CREATE TRIGGER trigger_update_route_timetable_timestamp
    BEFORE UPDATE ON route_timetables
    FOR EACH ROW
    EXECUTE FUNCTION updated_at();

CREATE TRIGGER trigger_update_route_timetable_entry_timestamp
    BEFORE UPDATE ON route_timetable_entries
    FOR EACH ROW
    EXECUTE FUNCTION updated_at();

CREATE OR REPLACE FUNCTION prevent_station_deletion()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM routes
        WHERE origin_station_id = OLD.id OR destination_station_id = OLD.id
    ) THEN
        RAISE EXCEPTION 'Cannot delete station % because it is used in routes', OLD.name;
    END IF;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_prevent_station_deletion
    BEFORE DELETE ON stations
    FOR EACH ROW
    EXECUTE FUNCTION prevent_station_deletion();

CREATE OR REPLACE FUNCTION prevent_route_deletion()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM reservations
        WHERE route_id = OLD.id
    ) THEN
        RAISE EXCEPTION 'Cannot delete route % because it has reservations', OLD.id;
    END IF;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_prevent_route_deletion
    BEFORE DELETE ON routes
    FOR EACH ROW
    EXECUTE FUNCTION prevent_route_deletion();

CREATE OR REPLACE FUNCTION create_route_availability()
RETURNS TRIGGER AS $$
DECLARE
    v_capacity INTEGER;
BEGIN
    SELECT seat_capacity INTO v_capacity
    FROM vehicle_classes
    WHERE class = NEW.vehicle_class;
    
    IF v_capacity IS NULL THEN
        RAISE EXCEPTION 'Seat capacity not defined for vehicle class % (route %)', NEW.vehicle_class, NEW.id;
    END IF;
    
    INSERT INTO route_availability (route_id, total_capacity, booked_seats, available_seats, last_updated)
    VALUES (NEW.id, v_capacity, 0, v_capacity, CURRENT_TIMESTAMP)
    ON CONFLICT (route_id) DO NOTHING;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_create_route_availability
    AFTER INSERT ON routes
    FOR EACH ROW
    EXECUTE FUNCTION create_route_availability();

CREATE OR REPLACE FUNCTION create_route_statistics()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO route_statistics (route_id, total_reservations, confirmed_reservations, cancelled_reservations, total_revenue, average_occupancy_rate, last_calculated)
    VALUES (NEW.id, 0, 0, 0, 0.00, 0.00, CURRENT_TIMESTAMP)
    ON CONFLICT (route_id) DO NOTHING;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_create_route_statistics
    AFTER INSERT ON routes
    FOR EACH ROW
    EXECUTE FUNCTION create_route_statistics();

-- ============================================================================
-- SECTION 4: INITIALIZE DENORMALIZED TABLES
-- ----------------------------------------------------------------------------
-- Ensures route availability and statistics have seed rows for every route,
-- even if routes were created before triggers existed. Exceptions are swallowed
-- so re-running the script is safe.
-- ============================================================================

DO $$
DECLARE
    route_record RECORD;
BEGIN
    FOR route_record IN SELECT id FROM routes LOOP
        BEGIN
            CALL update_route_availability(route_record.id);
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END LOOP;
END $$;

DO $$
DECLARE
    route_record RECORD;
BEGIN
    FOR route_record IN SELECT id FROM routes LOOP
        BEGIN
            CALL update_route_statistics(route_record.id);
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END LOOP;
END $$;

-- ============================================================================
-- SECTION 5: SAMPLE DATA
-- ----------------------------------------------------------------------------
-- Inserts stations, routes, timetables, fare policies, reservations. Triggers
-- automatically populate denormalized columns.
-- ============================================================================

INSERT INTO stations (name, description, status, address, created_by) VALUES
('Central Station', 'Main transportation hub in the city center', 'ACTIVE', '123 Main Street, City Center', 'ADMIN'),
('North Terminal', 'Northern terminal serving suburban areas', 'ACTIVE', '456 North Avenue, Suburbs', 'ADMIN'),
('South Station', 'Southern terminal serving industrial areas', 'ACTIVE', '789 South Boulevard, Industrial District', 'ADMIN'),
('East Depot', 'Eastern depot serving residential areas', 'ACTIVE', '321 East Road, Residential Area', 'ADMIN'),
('West Hub', 'Western hub serving commercial districts', 'ACTIVE', '654 West Street, Commercial District', 'ADMIN'),
('Airport Terminal', 'Terminal serving the international airport', 'ACTIVE', 'Airport Road, Airport District', 'ADMIN');

INSERT INTO routes (origin_station_id, destination_station_id, vehicle_class, distance_km, status, created_by) VALUES
((SELECT id FROM stations WHERE name = 'Central Station'), (SELECT id FROM stations WHERE name = 'North Terminal'), 'STANDARD', 24.5, 'ACTIVE', 'ADMIN'),
((SELECT id FROM stations WHERE name = 'Central Station'), (SELECT id FROM stations WHERE name = 'South Station'), 'STANDARD', 31.2, 'ACTIVE', 'ADMIN'),
((SELECT id FROM stations WHERE name = 'Central Station'), (SELECT id FROM stations WHERE name = 'East Depot'), 'MINI_BUS', 18.6, 'ACTIVE', 'ADMIN'),
((SELECT id FROM stations WHERE name = 'Central Station'), (SELECT id FROM stations WHERE name = 'West Hub'), 'STANDARD', 16.9, 'ACTIVE', 'ADMIN'),
((SELECT id FROM stations WHERE name = 'Central Station'), (SELECT id FROM stations WHERE name = 'Airport Terminal'), 'COACH', 42.3, 'ACTIVE', 'ADMIN'),
((SELECT id FROM stations WHERE name = 'North Terminal'), (SELECT id FROM stations WHERE name = 'South Station'), 'COACH', 55.7, 'ACTIVE', 'ADMIN'),
((SELECT id FROM stations WHERE name = 'North Terminal'), (SELECT id FROM stations WHERE name = 'Airport Terminal'), 'COACH', 47.8, 'ACTIVE', 'ADMIN'),
((SELECT id FROM stations WHERE name = 'East Depot'), (SELECT id FROM stations WHERE name = 'West Hub'), 'MINI_BUS', 22.4, 'ACTIVE', 'ADMIN'),
((SELECT id FROM stations WHERE name = 'South Station'), (SELECT id FROM stations WHERE name = 'Airport Terminal'), 'DOUBLE_DECKER', 49.5, 'ACTIVE', 'ADMIN');

INSERT INTO vat_rates (rate_percentage, effective_from, effective_to, status, description, created_by)
VALUES
    (9.00, '2023-01-01 00:00:00', '2023-12-31 23:59:59', 'EXPIRED', 'Legacy reduced VAT rate', 'ADMIN'),
    (19.00, '2024-01-01 00:00:00', NULL, 'ACTIVE', 'Standard VAT rate', 'ADMIN');

WITH route_ct_to_nt AS (
    SELECT r.id
    FROM routes r
    JOIN stations s1 ON r.origin_station_id = s1.id
    JOIN stations s2 ON r.destination_station_id = s2.id
    WHERE s1.name = 'Central Station' AND s2.name = 'North Terminal'
    LIMIT 1
), weekday_timetable AS (
    INSERT INTO route_timetables (route_id, name, description, effective_from, status, created_by)
    SELECT id, 'Weekday Morning Schedule', 'Morning commuter departures Monday to Friday', '2025-01-01', 'ACTIVE', 'ADMIN'
    FROM route_ct_to_nt
    RETURNING id
)
INSERT INTO route_timetable_entries (timetable_id, departure_time, arrival_time, notes)
SELECT weekday_timetable.id, v.departure_time, v.arrival_time, v.notes
FROM weekday_timetable
CROSS JOIN (
    VALUES
        (TIME '07:30', TIME '08:15', 'Morning commuter express'),
        (TIME '18:00', TIME '18:45', 'Evening return service')
) AS v(departure_time, arrival_time, notes);

WITH route_ct_to_airport AS (
    SELECT r.id
    FROM routes r
    JOIN stations s1 ON r.origin_station_id = s1.id
    JOIN stations s2 ON r.destination_station_id = s2.id
    WHERE s1.name = 'Central Station' AND s2.name = 'Airport Terminal'
    LIMIT 1
), weekend_timetable AS (
    INSERT INTO route_timetables (route_id, name, description, effective_from, status, created_by)
    SELECT id, 'Weekend Airport Shuttle', 'Frequent airport runs on weekends', '2025-01-01', 'ACTIVE', 'ADMIN'
    FROM route_ct_to_airport
    RETURNING id
)
INSERT INTO route_timetable_entries (timetable_id, departure_time, arrival_time, notes)
SELECT weekend_timetable.id, v.departure_time, v.arrival_time, v.notes
FROM weekend_timetable
CROSS JOIN (
    VALUES
        (TIME '06:00', TIME '06:50', 'Early shuttle'),
        (TIME '10:00', TIME '10:50', 'Mid-morning shuttle'),
        (TIME '14:00', TIME '14:50', 'Afternoon shuttle'),
        (TIME '18:00', TIME '18:50', 'Evening shuttle')
) AS v(departure_time, arrival_time, notes);

INSERT INTO fare_policies (passenger_category, base_price, effective_from, status, created_by)
SELECT 
    pc.category,
    ROUND(
        25.00 * (1 - COALESCE(pc.discount_percentage, 0) / 100.0),
        2
    ) AS base_price,
    '2024-01-01 00:00:00'::TIMESTAMP,
    'ACTIVE',
    'ADMIN'
FROM passenger_categories pc;

DO $$
DECLARE
    v_route_id INTEGER;
    v_route_class VARCHAR(20);
    v_departure_time TIMESTAMP;
    v_arrival_time TIMESTAMP;
BEGIN
    SELECT id, vehicle_class INTO v_route_id, v_route_class
    FROM routes
    ORDER BY id
    LIMIT 1;
    
    FOR i IN 1..5 LOOP
        v_departure_time := CURRENT_TIMESTAMP + (i || ' days')::INTERVAL + '09:00:00'::TIME;
        v_arrival_time := v_departure_time + '45 minutes'::INTERVAL;
        
        INSERT INTO reservations (
            route_id,
            passenger_name,
            passenger_email,
            passenger_phone,
            seat_count,
            status,
            passenger_category,
            vehicle_class,
            departure_time,
            arrival_time,
            created_by
        ) VALUES (
            v_route_id,
            'Passenger ' || i,
            'passenger' || i || '@example.com',
            '+1234567890' || i,
            1 + (i % 3),
            CASE WHEN i <= 3 THEN 'CONFIRMED' ELSE 'PENDING' END,
            CASE (i % 4)
                WHEN 0 THEN 'ADULT'
                WHEN 1 THEN 'CHILD'
                WHEN 2 THEN 'SENIOR'
                ELSE 'STUDENT'
            END,
            v_route_class,
            v_departure_time,
            v_arrival_time,
            'ADMIN'
        );
    END LOOP;
END $$;

DO $$
DECLARE
    v_reservation_id INTEGER;
BEGIN
    SELECT id INTO v_reservation_id
    FROM reservations
    ORDER BY id
    LIMIT 1;
    
    IF v_reservation_id IS NOT NULL THEN
        CALL cancel_reservation(v_reservation_id, 'ADMIN', 'Sample cancellation to populate history');
    END IF;
END $$;

CALL generate_revenue_summary(CURRENT_DATE);

COMMIT;

