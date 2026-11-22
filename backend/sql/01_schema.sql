-- =====================================================================
-- LET'S SEE Properties — PostgreSQL schema v1
-- Target: PostgreSQL 14+ (tested on 16). Backend: Django. Frontend: React.
--
-- Conventions
--   * Entities (users, properties, listings, ...) use uuid PKs (safe to expose in APIs).
--   * Small reference/lookup tables use bigint identity PKs.
--   * Timestamps are timestamptz. Money is numeric(14,2) + explicit currency.
--   * Soft delete via deleted_at on user-facing content (BR-076/077).
--   * Business data is relational. jsonb is used ONLY for genuinely free-form
--     payloads (saved-search criteria, event/audit metadata)  (BR-080).
--   * Permissions are enforced by the backend (BR-073); the DB guards integrity.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive email/username
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- fuzzy text search
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- price-history overlap guard

-- ---------------------------------------------------------------------
-- 0. ENUM TYPES  (small, stable, controlled value sets — BR-012)
--    Extensible sets (property types, amenities, ...) are lookup TABLES instead.
-- ---------------------------------------------------------------------
CREATE TYPE account_status        AS ENUM ('active','suspended','restricted','deactivated','deleted');
CREATE TYPE company_status        AS ENUM ('pending','active','suspended','closed');
CREATE TYPE staff_status          AS ENUM ('invited','active','suspended','removed');
CREATE TYPE role_scope            AS ENUM ('platform','company');
CREATE TYPE geo_level             AS ENUM ('country','region','city','sub_city','woreda','neighborhood');
CREATE TYPE coordinate_precision  AS ENUM ('exact','approximate','none');
CREATE TYPE property_availability AS ENUM ('available','reserved','rented','sold','unavailable');
CREATE TYPE relationship_type     AS ENUM ('owner','agent','manager','authorized_representative');
CREATE TYPE relationship_status   AS ENUM ('pending','active','ended','revoked');
CREATE TYPE attribute_data_type   AS ENUM ('integer','decimal','boolean','text','option');
CREATE TYPE listing_type          AS ENUM ('sale','rent','lease');
CREATE TYPE listing_status        AS ENUM ('draft','pending_review','active','paused','closed','expired','unpublished','removed','archived');
CREATE TYPE price_period          AS ENUM ('total','per_month','per_year');
CREATE TYPE media_type            AS ENUM ('photo','video','floor_plan');
CREATE TYPE verification_kind     AS ENUM ('identity','business','property_ownership');
CREATE TYPE verification_status   AS ENUM ('submitted','under_review','approved','rejected','expired','revoked');
CREATE TYPE conversation_type     AS ENUM ('direct','group','support');
CREATE TYPE conversation_basis    AS ENUM ('customer_started','contact_request','viewing_request','existing_relationship','group_invite','support');
CREATE TYPE participant_role      AS ENUM ('owner','admin','member');
CREATE TYPE message_kind          AS ENUM ('text','listing_share','account_share','viewing_request','image','file','system');
CREATE TYPE viewing_status        AS ENUM ('pending','confirmed','declined','rescheduled','cancelled','completed','no_show');
CREATE TYPE review_status         AS ENUM ('published','under_review','hidden','removed');
CREATE TYPE report_target         AS ENUM ('listing','property','user','company','message','review');
CREATE TYPE report_status         AS ENUM ('open','linked_to_case','dismissed');
CREATE TYPE case_status           AS ENUM ('open','in_review','resolved');
CREATE TYPE moderation_action     AS ENUM ('no_action','warn','hide_content','remove_content','restore_content',
                                           'restrict_account','suspend_account','reinstate_account');
CREATE TYPE promotion_type        AS ENUM ('top_feed','boost','sponsored_listing');
CREATE TYPE promotion_status      AS ENUM ('draft','pending_payment','scheduled','active','paused','expired','cancelled');
CREATE TYPE payment_status        AS ENUM ('pending','succeeded','failed','cancelled','refunded','partially_refunded');
CREATE TYPE advertiser_kind       AS ENUM ('platform','company','user');
CREATE TYPE ad_surface            AS ENUM ('chat','feed');
CREATE TYPE ad_status             AS ENUM ('draft','pending_review','approved','active','paused','ended','rejected');
CREATE TYPE notification_category AS ENUM ('messages','property_alerts','marketing','promotions','system');
CREATE TYPE notification_channel  AS ENUM ('in_app','push','email','sms');
CREATE TYPE ticket_status         AS ENUM ('open','pending','resolved','closed');

-- ---------------------------------------------------------------------
-- 0b. GENERIC TRIGGER FUNCTIONS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- Append-only guard for audit / history tables (BR-053, BR-075).
CREATE OR REPLACE FUNCTION prevent_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME; END $$;

-- ---------------------------------------------------------------------
-- 1. USERS, PROFILES, ROLES, PERMISSIONS
-- ---------------------------------------------------------------------
CREATE TABLE users (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email             citext UNIQUE,
  phone             text   UNIQUE,
  username          citext NOT NULL UNIQUE,
  password_hash     text,                         -- NULL for social-login-only accounts
  status            account_status NOT NULL DEFAULT 'active',
  email_verified_at timestamptz,
  phone_verified_at timestamptz,
  last_login_at     timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT users_has_contact CHECK (email IS NOT NULL OR phone IS NOT NULL)
);
CREATE INDEX users_status_idx ON users(status) WHERE status <> 'active';

CREATE TABLE geo_areas (               -- structured location hierarchy (BR-018)
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  parent_id  bigint REFERENCES geo_areas(id),
  level      geo_level NOT NULL,
  name       text NOT NULL,
  name_am    text,                       -- Amharic name
  slug       text NOT NULL,
  is_active  boolean NOT NULL DEFAULT true,
  UNIQUE (parent_id, slug)
);
CREATE INDEX geo_areas_parent_idx ON geo_areas(parent_id);
CREATE INDEX geo_areas_level_name_idx ON geo_areas(level, name);

CREATE TABLE profiles (                -- USER 1:1 PROFILE
  user_id            uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  display_name       text NOT NULL,
  bio                text,
  avatar_storage_key text,               -- object-storage key, not the file
  avatar_color       smallint,
  home_city_id       bigint REFERENCES geo_areas(id),
  public_phone       text,
  public_email       citext,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_settings (           -- prototype "Settings" screen
  user_id             uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  theme               text NOT NULL DEFAULT 'system' CHECK (theme IN ('light','dark','system')),
  locale              text NOT NULL DEFAULT 'en',
  show_read_receipts  boolean NOT NULL DEFAULT true,
  show_online_status  boolean NOT NULL DEFAULT true,
  discoverable        boolean NOT NULL DEFAULT true,
  default_listing_type listing_type,
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE blocked_users (
  blocker_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_user_id, blocked_user_id),
  CHECK (blocker_user_id <> blocked_user_id)
);

CREATE TABLE poster_types (            -- Landlord, Agent, Company, Manager, Developer
  id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code  text NOT NULL UNIQUE,
  label text NOT NULL
);

CREATE TABLE poster_profiles (         -- "Start posting" capability (BR-002). Row exists = capability active.
  user_id        uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  poster_type_id smallint NOT NULL REFERENCES poster_types(id),
  license_number text,
  activated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE companies (               -- NOT a user (BR-054)
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL,
  slug           citext NOT NULL UNIQUE,
  description    text,
  logo_storage_key text,
  contact_email  citext,
  contact_phone  text,
  website        text,
  status         company_status NOT NULL DEFAULT 'pending',
  created_by     uuid REFERENCES users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz
);

CREATE TABLE permissions (             -- granular (BR-056)
  id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE,    -- e.g. listing.create
  description text
);

CREATE TABLE roles (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code       text NOT NULL,
  name       text NOT NULL,
  scope      role_scope NOT NULL,
  company_id uuid REFERENCES companies(id) ON DELETE CASCADE,  -- NULL = system role; set = custom company role
  is_system  boolean NOT NULL DEFAULT false,
  CHECK ((scope = 'company') OR company_id IS NULL)
);
CREATE UNIQUE INDEX roles_code_system_uq  ON roles(code) WHERE company_id IS NULL;
CREATE UNIQUE INDEX roles_code_company_uq ON roles(company_id, code) WHERE company_id IS NOT NULL;

CREATE TABLE role_permissions (
  role_id       bigint   NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_id smallint NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE user_roles (              -- platform-scope roles: customer, poster, moderator, admin, support
  user_id    uuid   NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id    bigint NOT NULL REFERENCES roles(id),
  granted_by uuid REFERENCES users(id),
  granted_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  PRIMARY KEY (user_id, role_id)
);

CREATE TABLE company_staff (           -- USER M:N COMPANY, with company-scope role
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid   NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  user_id    uuid   NOT NULL REFERENCES users(id),
  role_id    bigint NOT NULL REFERENCES roles(id),
  position   text,
  status     staff_status NOT NULL DEFAULT 'invited',
  invited_by uuid REFERENCES users(id),
  joined_at  timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, user_id)
);
CREATE INDEX company_staff_user_idx ON company_staff(user_id);

CREATE TABLE teams (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, name)
);
CREATE TABLE team_members (
  team_id          uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  company_staff_id uuid NOT NULL REFERENCES company_staff(id) ON DELETE CASCADE,
  PRIMARY KEY (team_id, company_staff_id)
);

CREATE TABLE official_accounts (       -- explicit official status, never "user_id = 1" (BR-069)
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid UNIQUE REFERENCES users(id),
  company_id uuid UNIQUE REFERENCES companies(id),
  purpose    text NOT NULL DEFAULT 'platform',
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(user_id, company_id) = 1)
);

-- Verification keeps history: one row per submission/decision (BR-006/007)
CREATE TABLE verification_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind             verification_kind NOT NULL DEFAULT 'identity',
  user_id          uuid REFERENCES users(id),
  company_id       uuid REFERENCES companies(id),
  status           verification_status NOT NULL DEFAULT 'submitted',
  submitted_at     timestamptz NOT NULL DEFAULT now(),
  reviewer_id      uuid REFERENCES users(id),
  reviewed_at      timestamptz,
  rejection_reason text,
  expires_at       timestamptz,
  CHECK (num_nonnulls(user_id, company_id) = 1),
  CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL)
);
CREATE INDEX verification_user_idx    ON verification_requests(user_id, status);
CREATE INDEX verification_company_idx ON verification_requests(company_id, status);
CREATE TABLE verification_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id    uuid NOT NULL REFERENCES verification_requests(id) ON DELETE CASCADE,
  doc_type      text NOT NULL,
  storage_key   text NOT NULL,           -- private bucket
  uploaded_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2. PROPERTY DOMAIN
-- ---------------------------------------------------------------------
CREATE TABLE property_types (
  id         smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code       text NOT NULL UNIQUE,
  label      text NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0,
  is_active  boolean NOT NULL DEFAULT true
);

-- Type-specific attributes without a giant sparse table (BR-014, BR-028/029).
CREATE TABLE attribute_definitions (
  id        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code      text NOT NULL UNIQUE,         -- bedrooms, land_size_m2, furnishing ...
  label     text NOT NULL,
  data_type attribute_data_type NOT NULL,
  unit      text
);
CREATE TABLE attribute_options (        -- values for data_type = 'option'
  id           smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  attribute_id smallint NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
  code         text NOT NULL,
  label        text NOT NULL,
  sort_order   smallint NOT NULL DEFAULT 0,
  UNIQUE (attribute_id, code)
);
CREATE TABLE property_type_attributes ( -- which attributes apply to which type (drives forms + filters)
  property_type_id smallint NOT NULL REFERENCES property_types(id) ON DELETE CASCADE,
  attribute_id     smallint NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
  is_required      boolean NOT NULL DEFAULT false,
  is_filterable    boolean NOT NULL DEFAULT true,
  sort_order       smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (property_type_id, attribute_id)
);

CREATE TABLE amenities (                -- Wi-Fi, Parking, Generator, Solar Power, ...
  id        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code      text NOT NULL UNIQUE,
  label     text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE property_type_amenities (  -- amenities offered per type (e.g. Swimming Pool for Villa)
  property_type_id smallint NOT NULL REFERENCES property_types(id) ON DELETE CASCADE,
  amenity_id       smallint NOT NULL REFERENCES amenities(id) ON DELETE CASCADE,
  PRIMARY KEY (property_type_id, amenity_id)
);

CREATE TABLE properties (               -- the real-world thing, NOT the advertisement (BR-009)
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_type_id    smallint NOT NULL REFERENCES property_types(id),
  name                text,
  description         text,
  availability_status property_availability NOT NULL DEFAULT 'available',
  created_by          uuid REFERENCES users(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz
);
CREATE INDEX properties_type_idx ON properties(property_type_id) WHERE deleted_at IS NULL;

CREATE TABLE property_locations (       -- 1:1 with property; one explicit FK per admin level
  property_id          uuid PRIMARY KEY REFERENCES properties(id) ON DELETE CASCADE,
  country_id           bigint NOT NULL REFERENCES geo_areas(id),
  region_id            bigint REFERENCES geo_areas(id),
  city_id              bigint REFERENCES geo_areas(id),
  sub_city_id          bigint REFERENCES geo_areas(id),
  woreda_id            bigint REFERENCES geo_areas(id),
  neighborhood_id      bigint REFERENCES geo_areas(id),
  address_line         text,
  hide_address         boolean NOT NULL DEFAULT false,
  latitude             numeric(9,6),     -- display-safe coordinates (fuzzed if approximate)
  longitude            numeric(9,6),
  coordinate_precision coordinate_precision NOT NULL DEFAULT 'none',
  CHECK (num_nonnulls(latitude, longitude) IN (0,2)),
  CHECK (latitude  BETWEEN -90  AND 90),
  CHECK (longitude BETWEEN -180 AND 180),
  CHECK ((coordinate_precision = 'none') = (latitude IS NULL))
);
CREATE INDEX property_locations_city_idx   ON property_locations(city_id);
CREATE INDEX property_locations_sub_idx    ON property_locations(sub_city_id);
CREATE INDEX property_locations_neigh_idx  ON property_locations(neighborhood_id);
CREATE INDEX property_locations_coords_idx ON property_locations(latitude, longitude) WHERE latitude IS NOT NULL;

CREATE TABLE property_attribute_values (  -- typed values, one column populated
  property_id  uuid     NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  attribute_id smallint NOT NULL REFERENCES attribute_definitions(id),
  value_int    bigint,
  value_dec    numeric(14,3),
  value_bool   boolean,
  value_text   text,
  option_id    smallint REFERENCES attribute_options(id),
  PRIMARY KEY (property_id, attribute_id),
  CHECK (num_nonnulls(value_int, value_dec, value_bool, value_text, option_id) = 1)
);
CREATE INDEX pav_int_idx    ON property_attribute_values(attribute_id, value_int) WHERE value_int IS NOT NULL;
CREATE INDEX pav_dec_idx    ON property_attribute_values(attribute_id, value_dec) WHERE value_dec IS NOT NULL;
CREATE INDEX pav_option_idx ON property_attribute_values(attribute_id, option_id) WHERE option_id IS NOT NULL;

CREATE TABLE property_amenities (
  property_id uuid     NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  amenity_id  smallint NOT NULL REFERENCES amenities(id),
  PRIMARY KEY (property_id, amenity_id)
);
CREATE INDEX property_amenities_amenity_idx ON property_amenities(amenity_id, property_id);

CREATE TABLE property_relationships (   -- USER/COMPANY M:N PROPERTY (BR-008). No property.owner_id.
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  user_id    uuid REFERENCES users(id),
  company_id uuid REFERENCES companies(id),
  type       relationship_type NOT NULL,
  status     relationship_status NOT NULL DEFAULT 'active',
  start_date date NOT NULL DEFAULT current_date,
  end_date   date,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(user_id, company_id) = 1),
  CHECK (end_date IS NULL OR end_date >= start_date)
);
CREATE UNIQUE INDEX property_rel_active_user_uq
  ON property_relationships(property_id, user_id, type) WHERE user_id IS NOT NULL AND status = 'active';
CREATE UNIQUE INDEX property_rel_active_company_uq
  ON property_relationships(property_id, company_id, type) WHERE company_id IS NOT NULL AND status = 'active';
CREATE INDEX property_rel_user_idx ON property_relationships(user_id) WHERE status = 'active';

-- ---------------------------------------------------------------------
-- 3. LISTINGS & PRICING
-- ---------------------------------------------------------------------
CREATE TABLE currencies (
  code   char(3) PRIMARY KEY,          -- ISO 4217
  name   text NOT NULL,
  symbol text,
  minor_units smallint NOT NULL DEFAULT 2,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE listings (                 -- the marketplace offering (BR-009/010/011)
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id            uuid NOT NULL REFERENCES properties(id),
  listing_type           listing_type NOT NULL,
  status                 listing_status NOT NULL DEFAULT 'draft',
  responsible_user_id    uuid NOT NULL REFERENCES users(id),      -- accountable person
  responsible_company_id uuid REFERENCES companies(id),           -- shown to customers when set
  title                  text NOT NULL,
  description            text,
  contact_phone          text,
  published_at           timestamptz,
  expires_at             timestamptz,
  closed_at              timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  search_vector          tsvector GENERATED ALWAYS AS (
      to_tsvector('simple'::regconfig, coalesce(title,'') || ' ' || coalesce(description,''))) STORED,
  CHECK (expires_at IS NULL OR published_at IS NULL OR expires_at > published_at),
  CHECK (status <> 'active' OR published_at IS NOT NULL)
);
CREATE INDEX listings_property_idx    ON listings(property_id);
CREATE INDEX listings_responsible_idx ON listings(responsible_user_id);
CREATE INDEX listings_company_idx     ON listings(responsible_company_id) WHERE responsible_company_id IS NOT NULL;
-- Hot path: public search only looks at live listings (BR-026)
CREATE INDEX listings_live_idx        ON listings(listing_type, published_at DESC)
  WHERE status = 'active' AND deleted_at IS NULL;
CREATE INDEX listings_expiry_idx      ON listings(expires_at) WHERE status = 'active';
CREATE INDEX listings_search_fts_idx  ON listings USING gin (search_vector);
CREATE INDEX listings_title_trgm_idx  ON listings USING gin (title gin_trgm_ops);

CREATE TABLE listing_prices (           -- price history (BR-015/016/017)
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id     uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  amount         numeric(14,2) NOT NULL CHECK (amount >= 0),
  currency       char(3) NOT NULL DEFAULT 'ETB' REFERENCES currencies(code),
  period         price_period NOT NULL,
  is_negotiable  boolean NOT NULL DEFAULT false,
  effective_from timestamptz NOT NULL DEFAULT now(),
  effective_to   timestamptz,           -- NULL = current price
  created_by     uuid REFERENCES users(id),
  CHECK (effective_to IS NULL OR effective_to >= effective_from),
  EXCLUDE USING gist (listing_id WITH =, tstzrange(effective_from, effective_to) WITH &&)
);
CREATE UNIQUE INDEX listing_prices_one_current_uq ON listing_prices(listing_id) WHERE effective_to IS NULL;
CREATE INDEX listing_prices_current_amount_idx    ON listing_prices(currency, amount) WHERE effective_to IS NULL;

-- Atomically close the current price and open a new one.
CREATE OR REPLACE FUNCTION set_listing_price(
  p_listing uuid, p_amount numeric, p_currency char(3), p_period price_period,
  p_negotiable boolean DEFAULT false, p_by uuid DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE new_id uuid; t timestamptz := clock_timestamp();
BEGIN
  UPDATE listing_prices SET effective_to = t WHERE listing_id = p_listing AND effective_to IS NULL;
  INSERT INTO listing_prices(listing_id, amount, currency, period, is_negotiable, effective_from, created_by)
  VALUES (p_listing, p_amount, p_currency, p_period, p_negotiable, t, p_by) RETURNING id INTO new_id;
  RETURN new_id;
END $$;

-- ---------------------------------------------------------------------
-- 4. MEDIA  (metadata here, bytes in object storage — BR-023)
-- ---------------------------------------------------------------------
CREATE TABLE media_assets (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id   uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  listing_id    uuid REFERENCES listings(id) ON DELETE SET NULL,  -- optional listing-specific media
  uploaded_by   uuid REFERENCES users(id),
  media_type    media_type NOT NULL,
  storage_key   text NOT NULL UNIQUE,
  thumbnail_key text,
  mime_type     text NOT NULL,
  size_bytes    bigint CHECK (size_bytes > 0),
  width         integer,
  height        integer,
  duration_sec  integer,
  caption       text,                    -- "Living room", "Kitchen" ...
  display_order integer NOT NULL DEFAULT 0,
  is_primary    boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  CHECK (NOT is_primary OR media_type = 'photo')
);
CREATE UNIQUE INDEX media_one_primary_uq ON media_assets(property_id) WHERE is_primary AND deleted_at IS NULL;
CREATE INDEX media_property_order_idx    ON media_assets(property_id, display_order) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- 5. DISCOVERY: saved, compare, follows, saved searches, events, feed feedback
-- ---------------------------------------------------------------------
CREATE TABLE saved_listings (
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  listing_id uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  saved_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, listing_id)       -- no duplicate saves (BR-031)
);
CREATE INDEX saved_listings_listing_idx ON saved_listings(listing_id);

CREATE TABLE compare_items (
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  listing_id uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  added_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, listing_id)
);

CREATE TABLE follows (                  -- follow a poster / company channel
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  follower_user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_user_id    uuid REFERENCES users(id) ON DELETE CASCADE,
  target_company_id uuid REFERENCES companies(id) ON DELETE CASCADE,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(target_user_id, target_company_id) = 1),
  CHECK (target_user_id IS DISTINCT FROM follower_user_id)
);
CREATE UNIQUE INDEX follows_user_uq    ON follows(follower_user_id, target_user_id)    WHERE target_user_id IS NOT NULL;
CREATE UNIQUE INDEX follows_company_uq ON follows(follower_user_id, target_company_id) WHERE target_company_id IS NOT NULL;

CREATE TABLE saved_searches (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name           text,
  criteria       jsonb NOT NULL,         -- free-form filter payload: legitimately schemaless
  notify         boolean NOT NULL DEFAULT true,
  is_active      boolean NOT NULL DEFAULT true,
  last_notified_at timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX saved_searches_user_idx ON saved_searches(user_id) WHERE is_active;

CREATE TABLE event_types (
  id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE,
  description text
);

-- Raw events are append-only and PARTITIONED BY MONTH so old data can be
-- rolled up and dropped cheaply (BR-033/034/057/058).
CREATE TABLE analytics_events (
  id           bigint GENERATED ALWAYS AS IDENTITY,
  occurred_at  timestamptz NOT NULL DEFAULT now(),
  event_type_id smallint NOT NULL REFERENCES event_types(id),
  user_id      uuid REFERENCES users(id),
  anonymous_id uuid,                     -- logged-out visitors
  session_id   uuid,
  listing_id   uuid REFERENCES listings(id),
  poster_user_id    uuid,                -- denormalised for poster analytics (no FK on purpose)
  poster_company_id uuid,
  source       text,                     -- feed, search, share_link, chat ...
  metadata     jsonb,
  PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);
CREATE INDEX analytics_events_listing_idx ON analytics_events(listing_id, occurred_at);
CREATE INDEX analytics_events_user_idx    ON analytics_events(user_id, occurred_at) WHERE user_id IS NOT NULL;
CREATE INDEX analytics_events_poster_idx  ON analytics_events(poster_user_id, occurred_at) WHERE poster_user_id IS NOT NULL;
CREATE TABLE analytics_events_default PARTITION OF analytics_events DEFAULT;

CREATE OR REPLACE FUNCTION create_analytics_partition(p_month date) RETURNS void LANGUAGE plpgsql AS $$
DECLARE s date := date_trunc('month', p_month)::date; e date := (date_trunc('month', p_month) + interval '1 month')::date;
        nm text := 'analytics_events_' || to_char(s, 'YYYY_MM');
BEGIN
  IF to_regclass(nm) IS NULL THEN
    EXECUTE format('CREATE TABLE %I PARTITION OF analytics_events FOR VALUES FROM (%L) TO (%L)', nm, s, e);
  END IF;
END $$;
-- Pre-create this month + next 3. Schedule monthly (Celery beat / pg_cron) to keep ahead.
SELECT create_analytics_partition((current_date + (n || ' month')::interval)::date) FROM generate_series(0,3) n;

CREATE TABLE listing_daily_metrics (     -- aggregated rollup (BR-059), filled by a scheduled job
  listing_id        uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  day               date NOT NULL,
  views             integer NOT NULL DEFAULT 0,
  clicks            integer NOT NULL DEFAULT 0,
  saves             integer NOT NULL DEFAULT 0,
  shares            integer NOT NULL DEFAULT 0,
  contacts          integer NOT NULL DEFAULT 0,
  calls             integer NOT NULL DEFAULT 0,
  viewing_requests  integer NOT NULL DEFAULT 0,
  PRIMARY KEY (listing_id, day)
);

CREATE TABLE recently_viewed (           -- read-model derived from view events; never touches the property
  user_id        uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  listing_id     uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  last_viewed_at timestamptz NOT NULL DEFAULT now(),
  view_count     integer NOT NULL DEFAULT 1,
  PRIMARY KEY (user_id, listing_id)
);
CREATE INDEX recently_viewed_user_time_idx ON recently_viewed(user_id, last_viewed_at DESC);

CREATE TABLE feedback_reasons (          -- "Too expensive", "Wrong location", "Already found a property" ...
  id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code  text NOT NULL UNIQUE,
  label text NOT NULL
);
CREATE TABLE recommendation_feedback (   -- negative/positive signal for the ranker (BR-036)
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  listing_id uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  reason_id  smallint NOT NULL REFERENCES feedback_reasons(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, listing_id, reason_id)
);

-- ---------------------------------------------------------------------
-- 6. MESSAGING  (messages belong to conversations — BR-042)
-- ---------------------------------------------------------------------
CREATE TABLE conversations (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type               conversation_type NOT NULL,
  title              text,                          -- groups
  description        text,
  photo_storage_key  text,
  listing_id         uuid REFERENCES listings(id),  -- context: "about this listing"
  company_id         uuid REFERENCES companies(id), -- conversation addressed to a company inbox
  initiated_by_user_id uuid NOT NULL REFERENCES users(id),
  initiation_basis   conversation_basis NOT NULL,   -- why this conversation may exist (BR-039/040)
  direct_key         text UNIQUE,                   -- backend-computed, prevents duplicate direct threads
  invite_code        text UNIQUE,
  members_can_send   boolean NOT NULL DEFAULT true,
  members_can_add    boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (type <> 'direct'  OR initiation_basis IN ('customer_started','contact_request','viewing_request','existing_relationship')),
  CHECK (type <> 'support' OR initiation_basis = 'support'),
  CHECK (type <> 'group'   OR initiation_basis IN ('customer_started','group_invite','existing_relationship'))
);
CREATE INDEX conversations_listing_idx ON conversations(listing_id) WHERE listing_id IS NOT NULL;

CREATE TABLE conversation_participants (
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users(id),
  role            participant_role NOT NULL DEFAULT 'member',
  joined_at       timestamptz NOT NULL DEFAULT now(),
  left_at         timestamptz,
  last_read_message_id uuid,
  archived        boolean NOT NULL DEFAULT false,
  muted           boolean NOT NULL DEFAULT false,
  pinned          boolean NOT NULL DEFAULT false,
  PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX conv_participants_user_idx ON conversation_participants(user_id) WHERE left_at IS NULL;

CREATE TABLE conversation_topics (       -- group sub-threads (prototype "topics")
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  title           text NOT NULL,
  created_by      uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, conversation_id)
);

CREATE TABLE messages (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  topic_id         uuid,
  sender_user_id   uuid NOT NULL,
  kind             message_kind NOT NULL DEFAULT 'text',
  body             text,
  reply_to_id      uuid REFERENCES messages(id),
  forwarded_from_id uuid REFERENCES messages(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  edited_at        timestamptz,
  deleted_at       timestamptz,                 -- "delete for everyone" keeps the row (BR-043)
  -- sender must be a participant; topic must belong to the same conversation
  FOREIGN KEY (conversation_id, sender_user_id) REFERENCES conversation_participants(conversation_id, user_id),
  FOREIGN KEY (topic_id, conversation_id)       REFERENCES conversation_topics(id, conversation_id),
  CHECK (kind IN ('listing_share','account_share','viewing_request','system','image','file') OR body IS NOT NULL OR deleted_at IS NOT NULL)
);
CREATE INDEX messages_conv_time_idx ON messages(conversation_id, created_at DESC);

CREATE TABLE message_user_deletions (    -- "delete for me"
  message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  PRIMARY KEY (message_id, user_id)
);
CREATE TABLE message_listings (          -- shared listing = reference, never a copy (BR-044)
  message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  listing_id uuid NOT NULL REFERENCES listings(id),
  PRIMARY KEY (message_id, listing_id)
);
CREATE TABLE message_account_shares (
  message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    uuid REFERENCES users(id),
  company_id uuid REFERENCES companies(id),
  CHECK (num_nonnulls(user_id, company_id) = 1)
);
CREATE TABLE message_attachments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id  uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  storage_key text NOT NULL,
  mime_type   text NOT NULL,
  file_name   text,
  size_bytes  bigint
);

-- ---------------------------------------------------------------------
-- 7. VIEWING REQUESTS, REVIEWS
-- ---------------------------------------------------------------------
CREATE TABLE viewing_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id       uuid NOT NULL REFERENCES listings(id),
  customer_user_id uuid NOT NULL REFERENCES users(id),
  poster_user_id   uuid NOT NULL REFERENCES users(id),
  conversation_id  uuid REFERENCES conversations(id),
  requested_for    timestamptz NOT NULL,
  note             text,
  status           viewing_status NOT NULL DEFAULT 'pending',
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (customer_user_id <> poster_user_id)
);
CREATE INDEX viewing_customer_idx ON viewing_requests(customer_user_id, requested_for);
CREATE INDEX viewing_poster_idx   ON viewing_requests(poster_user_id, status, requested_for);
CREATE INDEX viewing_listing_idx  ON viewing_requests(listing_id);

-- DECISION: a review targets a poster (user OR company) and must hang off a real
-- interaction — a viewing request or a conversation (BR-048/049).
CREATE TABLE reviews (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reviewer_user_id    uuid NOT NULL REFERENCES users(id),
  reviewed_user_id    uuid REFERENCES users(id),
  reviewed_company_id uuid REFERENCES companies(id),
  listing_id          uuid REFERENCES listings(id),
  viewing_request_id  uuid REFERENCES viewing_requests(id),
  conversation_id     uuid REFERENCES conversations(id),
  rating              smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  body                text,
  status              review_status NOT NULL DEFAULT 'published',
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  CHECK (num_nonnulls(reviewed_user_id, reviewed_company_id) = 1),
  CHECK (num_nonnulls(viewing_request_id, conversation_id) >= 1),
  CHECK (reviewer_user_id IS DISTINCT FROM reviewed_user_id)
);
CREATE UNIQUE INDEX reviews_one_per_viewing_uq ON reviews(reviewer_user_id, viewing_request_id) WHERE viewing_request_id IS NOT NULL;
CREATE UNIQUE INDEX reviews_one_per_conv_uq    ON reviews(reviewer_user_id, conversation_id)    WHERE conversation_id    IS NOT NULL;
CREATE INDEX reviews_user_idx    ON reviews(reviewed_user_id,    created_at DESC) WHERE status = 'published';
CREATE INDEX reviews_company_idx ON reviews(reviewed_company_id, created_at DESC) WHERE status = 'published';
CREATE TABLE review_replies (
  review_id      uuid PRIMARY KEY REFERENCES reviews(id) ON DELETE CASCADE,
  author_user_id uuid NOT NULL REFERENCES users(id),
  body           text NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 8. REPORTS & MODERATION  (report -> case -> decision -> action)
-- ---------------------------------------------------------------------
CREATE TABLE report_reasons (
  id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code  text NOT NULL UNIQUE,
  label text NOT NULL
);

CREATE TABLE moderation_cases (          -- many reports about the same thing fold into ONE case
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_type           report_target NOT NULL,
  target_id             uuid NOT NULL,
  status                case_status NOT NULL DEFAULT 'open',
  assigned_moderator_id uuid REFERENCES users(id),
  decision_summary      text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  resolved_at           timestamptz,
  CHECK (status <> 'resolved' OR resolved_at IS NOT NULL)
);
CREATE INDEX moderation_cases_open_idx   ON moderation_cases(status, created_at) WHERE status <> 'resolved';
CREATE INDEX moderation_cases_target_idx ON moderation_cases(target_type, target_id);

CREATE TABLE reports (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_user_id uuid NOT NULL REFERENCES users(id),
  target_type      report_target NOT NULL,
  target_id        uuid NOT NULL,             -- polymorphic; validated by the backend
  reason_id        smallint NOT NULL REFERENCES report_reasons(id),
  description      text,
  status           report_status NOT NULL DEFAULT 'open',
  case_id          uuid REFERENCES moderation_cases(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (reporter_user_id, target_type, target_id, reason_id)  -- no report spam
);
CREATE INDEX reports_target_idx ON reports(target_type, target_id);
CREATE INDEX reports_case_idx   ON reports(case_id);

CREATE TABLE moderation_actions (        -- append-only, auditable (BR-053)
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id      uuid NOT NULL REFERENCES moderation_cases(id),
  moderator_id uuid NOT NULL REFERENCES users(id),
  action       moderation_action NOT NULL,
  target_type  report_target NOT NULL,
  target_id    uuid NOT NULL,
  reason       text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX moderation_actions_case_idx ON moderation_actions(case_id);
CREATE TRIGGER moderation_actions_immutable BEFORE UPDATE OR DELETE ON moderation_actions
  FOR EACH ROW EXECUTE FUNCTION prevent_mutation();

-- ---------------------------------------------------------------------
-- 9. MONETIZATION & ADVERTISING
-- ---------------------------------------------------------------------
CREATE TABLE promotion_packages (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code          text NOT NULL UNIQUE,
  name          text NOT NULL,
  promotion_type promotion_type NOT NULL,
  duration_days smallint NOT NULL CHECK (duration_days > 0),
  price         numeric(14,2) NOT NULL CHECK (price >= 0),
  currency      char(3) NOT NULL DEFAULT 'ETB' REFERENCES currencies(code),
  is_active     boolean NOT NULL DEFAULT true
);

CREATE TABLE promotions (                -- Listing -> Promotion -> Payment (BR-060)
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id           uuid NOT NULL REFERENCES listings(id),
  package_id           bigint REFERENCES promotion_packages(id),
  promotion_type       promotion_type NOT NULL,
  status               promotion_status NOT NULL DEFAULT 'draft',
  starts_at            timestamptz NOT NULL,       -- explicit (BR-063)
  ends_at              timestamptz NOT NULL,
  purchased_by_user_id uuid NOT NULL REFERENCES users(id),
  company_id           uuid REFERENCES companies(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);
CREATE INDEX promotions_listing_idx ON promotions(listing_id);
CREATE INDEX promotions_active_idx  ON promotions(promotion_type, starts_at, ends_at) WHERE status = 'active';

CREATE TABLE advertisers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind       advertiser_kind NOT NULL,
  user_id    uuid REFERENCES users(id),
  company_id uuid REFERENCES companies(id),
  display_name text NOT NULL,
  is_eligible  boolean NOT NULL DEFAULT true,       -- advertiser eligibility
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind = 'platform' AND num_nonnulls(user_id, company_id) = 0)
      OR (kind = 'company'  AND company_id IS NOT NULL AND user_id IS NULL)
      OR (kind = 'user'     AND user_id    IS NOT NULL AND company_id IS NULL))
);
CREATE UNIQUE INDEX advertisers_one_platform_uq ON advertisers(kind) WHERE kind = 'platform';

CREATE TABLE advertisements (            -- own identity; never a "message" (BR-045/046)
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  advertiser_id uuid NOT NULL REFERENCES advertisers(id),
  surface       ad_surface NOT NULL,
  title         text NOT NULL,
  body          text,
  image_storage_key text,
  cta_label     text,
  cta_url       text,                                -- e.g. LET'S SEE "Promote your property" service page
  sponsor_label text NOT NULL DEFAULT 'Sponsored',   -- must always be shown
  status        ad_status NOT NULL DEFAULT 'draft',
  starts_at     timestamptz,
  ends_at       timestamptz,
  max_per_user_per_day    smallint NOT NULL DEFAULT 1,   -- frequency cap (BR-047)
  min_messages_between_ads smallint NOT NULL DEFAULT 20, -- spacing
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at),
  CHECK (length(trim(sponsor_label)) > 0)
);
CREATE INDEX advertisements_serving_idx ON advertisements(surface, starts_at, ends_at) WHERE status = 'active';

CREATE TABLE ad_targeting_rules (        -- one row = AND of its non-null columns; rows OR together
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  advertisement_id uuid NOT NULL REFERENCES advertisements(id) ON DELETE CASCADE,
  geo_area_id      bigint REFERENCES geo_areas(id),
  property_type_id smallint REFERENCES property_types(id),
  listing_type     listing_type,
  CHECK (num_nonnulls(geo_area_id, property_type_id, listing_type) >= 1)
);

CREATE TABLE ad_impressions (            -- sponsored content delivered in a conversation or feed
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  advertisement_id uuid NOT NULL REFERENCES advertisements(id),
  user_id          uuid REFERENCES users(id),
  conversation_id  uuid REFERENCES conversations(id),
  after_message_id uuid REFERENCES messages(id),
  shown_at         timestamptz NOT NULL DEFAULT now(),
  clicked_at       timestamptz,
  dismissed_at     timestamptz
);
CREATE INDEX ad_impressions_user_day_idx ON ad_impressions(user_id, advertisement_id, shown_at);
CREATE INDEX ad_impressions_conv_idx     ON ad_impressions(conversation_id, shown_at) WHERE conversation_id IS NOT NULL;

CREATE TABLE payment_methods (
  code  text PRIMARY KEY,                -- telebirr, chapa, bank_transfer, card, cash ...
  label text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE payments (                  -- own transaction record (BR-064)
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payer_user_id         uuid NOT NULL REFERENCES users(id),
  payer_company_id      uuid REFERENCES companies(id),
  promotion_id          uuid REFERENCES promotions(id),
  advertisement_id      uuid REFERENCES advertisements(id),
  amount                numeric(14,2) NOT NULL CHECK (amount > 0),
  currency              char(3) NOT NULL DEFAULT 'ETB' REFERENCES currencies(code),
  method                text NOT NULL REFERENCES payment_methods(code),
  provider              text,
  transaction_reference text,
  status                payment_status NOT NULL DEFAULT 'pending',
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  paid_at               timestamptz,
  CHECK (num_nonnulls(promotion_id, advertisement_id) = 1),
  CHECK (status <> 'succeeded' OR paid_at IS NOT NULL),
  UNIQUE (provider, transaction_reference)
);
CREATE INDEX payments_payer_idx     ON payments(payer_user_id, created_at DESC);
CREATE INDEX payments_promotion_idx ON payments(promotion_id) WHERE promotion_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 10. NOTIFICATIONS, SUPPORT
-- ---------------------------------------------------------------------
CREATE TABLE notification_types (
  id       smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code     text NOT NULL UNIQUE,
  category notification_category NOT NULL,
  label    text NOT NULL
);
CREATE TABLE notifications (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type_id      smallint NOT NULL REFERENCES notification_types(id),
  title        text NOT NULL,
  body         text,
  listing_id   uuid REFERENCES listings(id) ON DELETE SET NULL,
  conversation_id uuid REFERENCES conversations(id) ON DELETE SET NULL,
  read_at      timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notifications_user_unread_idx ON notifications(user_id, created_at DESC) WHERE read_at IS NULL;
CREATE INDEX notifications_user_idx        ON notifications(user_id, created_at DESC);

CREATE TABLE notification_preferences (
  user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  category notification_category NOT NULL,
  channel  notification_channel  NOT NULL,
  enabled  boolean NOT NULL DEFAULT true,
  PRIMARY KEY (user_id, category, channel)
);
CREATE TABLE push_devices (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform   text NOT NULL CHECK (platform IN ('ios','android','web')),
  token      text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz
);

CREATE TABLE support_tickets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users(id),
  subject         text,
  body            text NOT NULL,
  status          ticket_status NOT NULL DEFAULT 'open',
  assigned_to     uuid REFERENCES users(id),
  conversation_id uuid REFERENCES conversations(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX support_tickets_open_idx ON support_tickets(status, created_at) WHERE status IN ('open','pending');

-- ---------------------------------------------------------------------
-- 11. AUDIT & STATUS HISTORY  (append-only — BR-053/075/076)
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_user_id uuid REFERENCES users(id),
  action        text NOT NULL,              -- account.suspend, verification.approve, permission.change ...
  entity_type   text NOT NULL,
  entity_id     uuid,
  reason        text,
  ip_address    inet,
  metadata      jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_entity_idx ON audit_logs(entity_type, entity_id, created_at DESC);
CREATE INDEX audit_logs_actor_idx  ON audit_logs(actor_user_id, created_at DESC);
CREATE TRIGGER audit_logs_immutable BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION prevent_mutation();

-- One generic history for lifecycle changes (account, listing, promotion, viewing, review, ...).
-- Populated AUTOMATICALLY by triggers below, so no code path can forget it.
CREATE TABLE status_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_type text NOT NULL,                -- table name
  entity_id   uuid NOT NULL,
  from_status text,
  to_status   text NOT NULL,
  changed_by  uuid,                         -- from SET LOCAL app.user_id
  reason      text,                         -- from SET LOCAL app.change_reason
  changed_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX status_history_entity_idx ON status_history(entity_type, entity_id, changed_at);
CREATE TRIGGER status_history_immutable BEFORE UPDATE OR DELETE ON status_history
  FOR EACH ROW EXECUTE FUNCTION prevent_mutation();

-- The Django layer should run, per request/transaction:
--   SET LOCAL app.user_id = '<uuid>';  SET LOCAL app.change_reason = '...';
CREATE OR REPLACE FUNCTION log_status_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE actor uuid := NULLIF(current_setting('app.user_id', true), '')::uuid;
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status::text IS DISTINCT FROM OLD.status::text THEN
    INSERT INTO status_history(entity_type, entity_id, from_status, to_status, changed_by, reason)
    VALUES (TG_TABLE_NAME, NEW.id,
            CASE WHEN TG_OP = 'UPDATE' THEN OLD.status::text END,
            NEW.status::text, actor, NULLIF(current_setting('app.change_reason', true), ''));
  END IF;
  RETURN NEW;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['users','companies','listings','viewing_requests','reviews',
                           'promotions','advertisements','payments','moderation_cases'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION log_status_change()', t || '_status_hist', t);
  END LOOP;
  -- updated_at maintenance
  FOREACH t IN ARRAY ARRAY['users','profiles','user_settings','companies','properties','listings','conversations',
                           'viewing_requests','reviews','promotions','advertisements','payments','support_tickets'] LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t || '_updated_at', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 12. READ VIEWS  (search/API can build on these; independent of the UI — BR-024)
-- ---------------------------------------------------------------------
CREATE VIEW v_listing_current_price AS
  SELECT listing_id, amount, currency, period, is_negotiable FROM listing_prices WHERE effective_to IS NULL;

-- Is this user/company currently verified? (derived from history, never a flag — BR-007)
CREATE VIEW v_verified_subjects AS
  SELECT DISTINCT user_id, company_id FROM verification_requests
  WHERE status = 'approved' AND (expires_at IS NULL OR expires_at > now());

-- Live, searchable listings only: excludes deleted/expired/removed/unpublished/draft/paused (BR-026).
CREATE VIEW v_searchable_listings AS
  SELECT l.id AS listing_id, l.listing_type, l.title, l.published_at, l.search_vector,
         l.responsible_user_id, l.responsible_company_id,
         p.id AS property_id, p.property_type_id, p.availability_status,
         pl.city_id, pl.sub_city_id, pl.neighborhood_id, pl.latitude, pl.longitude,
         pr.amount, pr.currency, pr.period
  FROM listings l
  JOIN properties p           ON p.id = l.property_id AND p.deleted_at IS NULL
  LEFT JOIN property_locations pl ON pl.property_id = p.id
  JOIN listing_prices pr      ON pr.listing_id = l.id AND pr.effective_to IS NULL
  WHERE l.status = 'active' AND l.deleted_at IS NULL
    AND (l.expires_at IS NULL OR l.expires_at > now());
