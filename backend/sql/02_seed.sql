-- =====================================================================
-- LET'S SEE Properties — reference/seed data (idempotent-safe on an empty DB)
-- Derived from the business docs + the v40 prototype. Review the geo data:
-- neighborhood -> sub-city parents are a best-effort sample.
-- =====================================================================

INSERT INTO currencies(code, name, symbol) VALUES ('ETB','Ethiopian Birr','Br'), ('USD','US Dollar','$');

INSERT INTO poster_types(code, label) VALUES
 ('landlord','Landlord / Property Owner'), ('agent','Real Estate Agent'),
 ('company','Real Estate Company'), ('manager','Property Manager'), ('developer','Property Developer');

INSERT INTO property_types(code, label, sort_order) VALUES
 ('apartment','Apartment',1), ('house','House',2), ('villa','Villa',3), ('family_house','Family House',4),
 ('condominium','Condominium',5), ('land','Land',6), ('commercial','Commercial Property',7),
 ('office','Office',8), ('warehouse','Warehouse',9);

-- ---- attributes (type-specific fields; add rows to add filters — BR-029) ----
INSERT INTO attribute_definitions(code,label,data_type,unit) VALUES
 ('bedrooms','Bedrooms','integer',NULL), ('bathrooms','Bathrooms','integer',NULL),
 ('floor','Floor','integer',NULL),       ('total_floors','Total floors','integer',NULL),
 ('year_built','Year built','integer',NULL), ('parking_spaces','Parking spaces','integer',NULL),
 ('floor_area_m2','Floor area','decimal','m²'), ('land_size_m2','Land size','decimal','m²'),
 ('ceiling_height_m','Ceiling height','decimal','m'),
 ('furnishing','Furnishing','option',NULL), ('land_use','Zoning / use','option',NULL);

INSERT INTO attribute_options(attribute_id, code, label, sort_order)
SELECT a.id, v.code, v.label, v.ord FROM attribute_definitions a
JOIN (VALUES ('furnishing','furnished','Furnished',1), ('furnishing','semi_furnished','Semi-furnished',2),
             ('furnishing','unfurnished','Unfurnished',3),
             ('land_use','residential','Residential',1), ('land_use','commercial','Commercial',2),
             ('land_use','mixed','Mixed use',3), ('land_use','agricultural','Agricultural',4),
             ('land_use','industrial','Industrial',5)) v(attr,code,label,ord) ON v.attr = a.code;

-- which attributes each type uses (is_required only where it is always meaningful)
INSERT INTO property_type_attributes(property_type_id, attribute_id, is_required, sort_order)
SELECT t.id, a.id, v.req, v.ord
FROM (VALUES
 ('apartment','bedrooms',true,1),('apartment','bathrooms',true,2),('apartment','floor_area_m2',true,3),('apartment','floor',false,4),
 ('apartment','furnishing',false,5),('apartment','parking_spaces',false,6),('apartment','year_built',false,7),
 ('condominium','bedrooms',true,1),('condominium','bathrooms',true,2),('condominium','floor_area_m2',true,3),('condominium','floor',false,4),
 ('condominium','furnishing',false,5),('condominium','parking_spaces',false,6),('condominium','year_built',false,7),
 ('house','bedrooms',true,1),('house','bathrooms',true,2),('house','floor_area_m2',true,3),('house','land_size_m2',false,4),
 ('house','total_floors',false,5),('house','furnishing',false,6),('house','parking_spaces',false,7),('house','year_built',false,8),
 ('family_house','bedrooms',true,1),('family_house','bathrooms',true,2),('family_house','floor_area_m2',true,3),('family_house','land_size_m2',false,4),
 ('family_house','total_floors',false,5),('family_house','furnishing',false,6),('family_house','parking_spaces',false,7),('family_house','year_built',false,8),
 ('villa','bedrooms',true,1),('villa','bathrooms',true,2),('villa','floor_area_m2',true,3),('villa','land_size_m2',false,4),
 ('villa','total_floors',false,5),('villa','furnishing',false,6),('villa','parking_spaces',false,7),('villa','year_built',false,8),
 ('land','land_size_m2',true,1),('land','land_use',false,2),
 ('commercial','floor_area_m2',true,1),('commercial','bathrooms',false,2),('commercial','parking_spaces',false,3),('commercial','year_built',false,4),
 ('office','floor_area_m2',true,1),('office','bathrooms',false,2),('office','floor',false,3),('office','parking_spaces',false,4),('office','furnishing',false,5),
 ('warehouse','floor_area_m2',true,1),('warehouse','ceiling_height_m',false,2),('warehouse','bathrooms',false,3),('warehouse','parking_spaces',false,4)
) v(ptype, attr, req, ord)
JOIN property_types t ON t.code = v.ptype
JOIN attribute_definitions a ON a.code = v.attr;

-- ---- amenities (prototype features + doc examples) ----
INSERT INTO amenities(code,label) VALUES
 ('wifi','Wi-Fi'),('fiber_internet','Fiber Internet'),('parking','Parking'),('shared_parking','Shared Parking'),
 ('backup_generator','Backup Generator'),('solar_power','Solar Power'),('water_tank','Water Tank'),
 ('security_24h','24h Security'),('cctv','CCTV'),('elevator','Elevator'),('balcony','Balcony'),('gym','Gym'),
 ('gated_compound','Gated Compound'),('garden','Garden'),('garage','Garage'),('fenced_compound','Fenced Compound'),
 ('servant_quarter','Servant Quarter'),('swimming_pool','Swimming Pool'),('home_cinema','Home Cinema'),
 ('guest_house','Guest House'),('playground','Playground'),
 ('title_deed','Title Deed'),('road_access','Road Access'),('electricity_nearby','Electricity Nearby'),
 ('water_nearby','Water Nearby'),('corner_plot','Corner Plot'),('flat_terrain','Flat Terrain'),
 ('street_frontage','Street Frontage'),('storage','Storage'),('meeting_room','Meeting Room'),
 ('reception','Reception'),('kitchenette','Kitchenette'),('loading_dock','Loading Dock'),
 ('high_ceiling','High Ceiling'),('truck_access','Truck Access'),('office_space','Office Space');

INSERT INTO property_type_amenities(property_type_id, amenity_id)
SELECT t.id, a.id FROM (VALUES
 ('apartment','elevator'),('apartment','security_24h'),('apartment','balcony'),('apartment','backup_generator'),('apartment','water_tank'),
 ('apartment','gym'),('apartment','cctv'),('apartment','fiber_internet'),('apartment','wifi'),('apartment','gated_compound'),('apartment','parking'),('apartment','solar_power'),
 ('condominium','elevator'),('condominium','balcony'),('condominium','water_tank'),('condominium','shared_parking'),('condominium','fiber_internet'),('condominium','wifi'),('condominium','playground'),('condominium','parking'),
 ('house','garden'),('house','garage'),('house','fenced_compound'),('house','backup_generator'),('house','water_tank'),('house','servant_quarter'),('house','cctv'),('house','fiber_internet'),('house','wifi'),('house','parking'),('house','solar_power'),
 ('family_house','garden'),('family_house','garage'),('family_house','fenced_compound'),('family_house','backup_generator'),('family_house','water_tank'),('family_house','servant_quarter'),('family_house','cctv'),('family_house','parking'),('family_house','solar_power'),
 ('villa','swimming_pool'),('villa','garden'),('villa','garage'),('villa','gated_compound'),('villa','servant_quarter'),('villa','backup_generator'),('villa','home_cinema'),('villa','gym'),('villa','cctv'),('villa','guest_house'),('villa','security_24h'),('villa','wifi'),('villa','parking'),('villa','solar_power'),
 ('land','title_deed'),('land','road_access'),('land','electricity_nearby'),('land','water_nearby'),('land','corner_plot'),('land','fenced_compound'),('land','flat_terrain'),
 ('commercial','street_frontage'),('commercial','backup_generator'),('commercial','storage'),('commercial','cctv'),('commercial','water_tank'),('commercial','security_24h'),('commercial','parking'),('commercial','wifi'),('commercial','solar_power'),
 ('office','elevator'),('office','meeting_room'),('office','fiber_internet'),('office','wifi'),('office','backup_generator'),('office','reception'),('office','cctv'),('office','kitchenette'),('office','security_24h'),('office','parking'),('office','solar_power'),
 ('warehouse','loading_dock'),('warehouse','high_ceiling'),('warehouse','truck_access'),('warehouse','office_space'),('warehouse','cctv'),('warehouse','backup_generator'),('warehouse','fenced_compound'),('warehouse','solar_power')
) v(ptype, amen) JOIN property_types t ON t.code = v.ptype JOIN amenities a ON a.code = v.amen;

-- ---- geography (sample; extend via admin/import) ----
INSERT INTO geo_areas(parent_id, level, name, name_am, slug) VALUES (NULL,'country','Ethiopia','ኢትዮጵያ','ethiopia');
WITH c AS (SELECT id FROM geo_areas WHERE slug='ethiopia')
INSERT INTO geo_areas(parent_id, level, name, slug) SELECT c.id,'region',v.n,v.s FROM c,
 (VALUES ('Addis Ababa','addis-ababa'),('Oromia','oromia'),('Sidama','sidama'),('Amhara','amhara')) v(n,s);
INSERT INTO geo_areas(parent_id, level, name, slug)
SELECT r.id,'city',v.n,v.s FROM (VALUES ('addis-ababa','Addis Ababa','addis-ababa'),('oromia','Adama','adama'),
  ('sidama','Hawassa','hawassa'),('amhara','Bahir Dar','bahir-dar')) v(region,n,s)
JOIN geo_areas r ON r.slug = v.region AND r.level='region';
INSERT INTO geo_areas(parent_id, level, name, slug)
SELECT c.id,'sub_city',v.n,v.s FROM geo_areas c,
 (VALUES ('Bole','bole'),('Yeka','yeka'),('Kirkos','kirkos'),('Lideta','lideta'),('Arada','arada'),('Addis Ketema','addis-ketema'),
         ('Kolfe Keranio','kolfe-keranio'),('Gullele','gullele'),('Nifas Silk-Lafto','nifas-silk-lafto'),
         ('Akaki Kality','akaki-kality'),('Lemi Kura','lemi-kura')) v(n,s)
WHERE c.slug='addis-ababa' AND c.level='city';
INSERT INTO geo_areas(parent_id, level, name, slug)
SELECT sc.id,'neighborhood',v.n,v.s FROM (VALUES
 ('bole','Gerji','gerji'),('bole','CMC','cmc'),('bole','Summit','summit'),('bole','Ayat','ayat'),('bole','Old Airport','old-airport'),
 ('kirkos','Kazanchis','kazanchis'),('arada','Piassa','piassa'),('yeka','Megenagna','megenagna'),
 ('nifas-silk-lafto','Lebu','lebu'),('nifas-silk-lafto','Sarbet','sarbet'),('kolfe-keranio','Kolfe','kolfe'),
 ('lideta','Lideta','lideta-area'),('yeka','Yeka','yeka-area'),('gullele','Gulele','gulele-area')) v(sc,n,s)
JOIN geo_areas sc ON sc.slug = v.sc AND sc.level='sub_city';

-- ---- permissions & roles ----
INSERT INTO permissions(code, description) VALUES
 ('listing.create','Create listings'),('listing.edit','Edit listings'),('listing.publish','Publish / unpublish listings'),
 ('listing.delete','Delete listings'),('messages.view','View company messages'),('messages.respond','Respond to messages'),
 ('analytics.view','View analytics'),('team.manage','Manage team & staff'),('profile.manage','Manage company profile'),
 ('promotion.manage','Buy / manage promotions'),
 ('moderation.review','Review reports & cases'),('moderation.act','Take moderation actions'),
 ('verification.review','Approve / reject verification'),('user.suspend','Suspend / restrict accounts'),
 ('support.respond','Answer support conversations'),('admin.audit.view','View audit logs');

INSERT INTO roles(code, name, scope, is_system) VALUES
 ('customer','Customer','platform',true), ('poster','Poster','platform',true),
 ('moderator','Moderator','platform',true), ('admin','Admin','platform',true), ('support','Support agent','platform',true),
 ('company_owner','Company owner','company',true), ('company_listings_staff','Listings staff','company',true),
 ('company_messages_staff','Customer messages','company',true), ('company_analyst','Analyst','company',true);

INSERT INTO role_permissions(role_id, permission_id)
SELECT r.id, p.id FROM (VALUES
 ('moderator','moderation.review'),('moderator','moderation.act'),
 ('support','support.respond'),
 ('admin','moderation.review'),('admin','moderation.act'),('admin','verification.review'),('admin','user.suspend'),
 ('admin','support.respond'),('admin','admin.audit.view'),
 ('company_owner','listing.create'),('company_owner','listing.edit'),('company_owner','listing.publish'),('company_owner','listing.delete'),
 ('company_owner','messages.view'),('company_owner','messages.respond'),('company_owner','analytics.view'),
 ('company_owner','team.manage'),('company_owner','profile.manage'),('company_owner','promotion.manage'),
 ('company_listings_staff','listing.create'),('company_listings_staff','listing.edit'),('company_listings_staff','listing.publish'),
 ('company_messages_staff','messages.view'),('company_messages_staff','messages.respond'),
 ('company_analyst','analytics.view')
) v(role, perm) JOIN roles r ON r.code = v.role AND r.company_id IS NULL JOIN permissions p ON p.code = v.perm;

-- ---- events, feedback, reports, notifications, payments ----
INSERT INTO event_types(code, description) VALUES
 ('listing_impression','Listing shown in a feed/search result'),('listing_viewed','Listing detail opened'),
 ('listing_clicked','Listing card clicked'),('listing_saved','Listing saved'),('listing_unsaved','Listing un-saved'),
 ('listing_shared','Listing shared'),('listing_compared','Added to compare'),('message_started','Conversation started'),
 ('call_initiated','Phone call initiated'),('viewing_requested','Viewing requested'),
 ('search_performed','Search executed'),('poster_profile_viewed','Poster profile opened'),
 ('ad_impression','Ad shown'),('ad_clicked','Ad clicked');

INSERT INTO feedback_reasons(code,label) VALUES
 ('too_expensive','Too expensive'),('wrong_location','Wrong location'),('already_found','Already found a property'),
 ('too_small','Too small'),('wrong_type','Wrong property type'),('not_interested','Not interested'),('hide_poster','Hide this poster');

INSERT INTO report_reasons(code,label) VALUES
 ('scam','Scam'),('fake_property','Fake property'),('wrong_information','Incorrect information'),
 ('misleading_photos','Misleading photos'),('already_sold_or_rented','Property already sold or rented'),
 ('inappropriate_content','Inappropriate content'),('harassment','Harassment'),
 ('duplicate_listing','Duplicate listing'),('fraud','Fraud'),('suspicious_activity','Suspicious activity'),('other','Other');

INSERT INTO notification_types(code, category, label) VALUES
 ('message_received','messages','Someone messaged you'),
 ('listing_saved','property_alerts','Someone saved your property'),
 ('price_changed','property_alerts','Price changed on a saved listing'),
 ('new_matching_listing','property_alerts','New listing matches your saved search'),
 ('viewing_requested','messages','New viewing request'),
 ('viewing_status_changed','messages','Viewing accepted / declined / rescheduled'),
 ('review_received','system','You received a review'),
 ('verification_completed','system','Verification completed'),
 ('promotion_started','promotions','Promotion started'),('promotion_ended','promotions','Promotion ended'),
 ('platform_news','marketing','News from LET''S SEE');

INSERT INTO payment_methods(code,label) VALUES
 ('telebirr','Telebirr'),('chapa','Chapa'),('cbe_birr','CBE Birr'),('bank_transfer','Bank transfer'),('card','Card'),('cash','Cash');

-- LET'S SEE's own advertiser identity (BR-065)
INSERT INTO advertisers(kind, display_name) VALUES ('platform', 'LET''S SEE');
