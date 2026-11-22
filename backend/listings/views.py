from decimal import Decimal, InvalidOperation

from django.db import connection, transaction
from django.utils import timezone
from rest_framework import serializers
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .media import photo_payload
from .serializers import ListingCreateSerializer, ListingUpdateSerializer, check_price_period

STARTABLE_POSTERS = ["landlord", "agent", "manager", "developer"]
RELATIONSHIP_FOR = {"landlord": "owner", "developer": "owner",
                    "agent": "agent", "manager": "manager"}
LEVEL_COLUMNS = {"country": "country_id", "region": "region_id", "city": "city_id",
                 "sub_city": "sub_city_id", "woreda": "woreda_id",
                 "neighborhood": "neighborhood_id"}
TRANSITIONS = {
    "publish": ({"draft", "paused", "unpublished", "expired"}, "active"),
    "pause": ({"active"}, "paused"),
    "close": ({"draft", "active", "paused", "unpublished", "expired"}, "closed"),
}


# ---------- small helpers ----------

def dict_rows(cur):
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def set_actor(cur, user, reason=None):
    """Tells the database who is acting, so status changes are logged with a name."""
    cur.execute("SELECT set_config('app.user_id', %s, true)", [str(user.id)])
    if reason:
        cur.execute("SELECT set_config('app.change_reason', %s, true)", [reason])


def not_found():
    return Response({"detail": "Not found."}, status=404)


def to_float(value):
    return float(value) if value is not None else None


def convert_value(defn, raw, options):
    """Turn one submitted value into (column, value) for property_attribute_values."""
    kind = defn["data_type"]
    if kind in ("integer", "decimal"):
        if isinstance(raw, bool):
            raise ValueError
        number = Decimal(str(raw))
        if number < 0 or number > Decimal("99999999999"):
            raise ValueError
        if kind == "integer":
            if number != number.to_integral_value():
                raise ValueError
            return "value_int", int(number)
        return "value_dec", number
    if kind == "boolean":
        if not isinstance(raw, bool):
            raise ValueError
        return "value_bool", raw
    if kind == "text":
        text = str(raw).strip()
        if not text:
            raise ValueError
        return "value_text", text
    option_id = options.get(defn["id"], {}).get(str(raw))
    if option_id is None:
        raise ValueError
    return "option_id", option_id


# ---------- reading a listing ----------

DETAIL_SQL = """
SELECT l.id, l.listing_type::text AS listing_type, l.status::text AS status,
       l.title, l.description, l.contact_phone, l.published_at, l.expires_at,
       l.created_at, l.responsible_user_id,
       pr.amount, pr.currency, pr.period::text AS period, pr.is_negotiable,
       p.id AS property_id, p.name AS property_name,
       p.availability_status::text AS availability,
       pt.code AS property_type_code, pt.label AS property_type_label,
       u.username, pf.display_name, ppt.code AS poster_type
FROM listings l
JOIN properties p ON p.id = l.property_id
JOIN property_types pt ON pt.id = p.property_type_id
JOIN users u ON u.id = l.responsible_user_id
LEFT JOIN listing_prices pr ON pr.listing_id = l.id AND pr.effective_to IS NULL
LEFT JOIN profiles pf ON pf.user_id = u.id
LEFT JOIN poster_profiles pp ON pp.user_id = u.id
LEFT JOIN poster_types ppt ON ppt.id = pp.poster_type_id
WHERE l.id = %s::uuid AND l.deleted_at IS NULL
"""

ATTRIBUTES_SQL = """
SELECT a.code, a.label, a.unit, a.data_type::text AS data_type,
       v.value_int, v.value_dec, v.value_bool, v.value_text,
       o.code AS option_code, o.label AS option_label
FROM property_attribute_values v
JOIN attribute_definitions a ON a.id = v.attribute_id
LEFT JOIN attribute_options o ON o.id = v.option_id
WHERE v.property_id = %s::uuid
ORDER BY a.id
"""

LOCATION_SQL = """
SELECT pl.address_line, pl.hide_address, pl.latitude, pl.longitude,
       pl.coordinate_precision::text AS coordinate_precision,
       co.name AS country, re.name AS region, ci.name AS city,
       sc.name AS sub_city, wo.name AS woreda, ne.name AS neighborhood
FROM property_locations pl
JOIN geo_areas co ON co.id = pl.country_id
LEFT JOIN geo_areas re ON re.id = pl.region_id
LEFT JOIN geo_areas ci ON ci.id = pl.city_id
LEFT JOIN geo_areas sc ON sc.id = pl.sub_city_id
LEFT JOIN geo_areas wo ON wo.id = pl.woreda_id
LEFT JOIN geo_areas ne ON ne.id = pl.neighborhood_id
WHERE pl.property_id = %s::uuid
"""


def build_detail(cur, listing_id, viewer_id):
    cur.execute(DETAIL_SQL, [str(listing_id)])
    rows = dict_rows(cur)
    if not rows:
        return None
    row = rows[0]
    is_owner = viewer_id is not None and str(row["responsible_user_id"]) == str(viewer_id)
    live = row["status"] == "active" and (
        row["expires_at"] is None or row["expires_at"] > timezone.now())
    if not (is_owner or live):
        return None

    cur.execute(ATTRIBUTES_SQL, [str(row["property_id"])])
    attributes = []
    for a in dict_rows(cur):
        if a["data_type"] == "option":
            value = {"code": a["option_code"], "label": a["option_label"]}
        elif a["data_type"] == "integer":
            value = a["value_int"]
        elif a["data_type"] == "decimal":
            value = to_float(a["value_dec"])
        elif a["data_type"] == "boolean":
            value = a["value_bool"]
        else:
            value = a["value_text"]
        attributes.append({"code": a["code"], "label": a["label"],
                           "unit": a["unit"], "value": value})

    cur.execute("""SELECT am.code, am.label FROM property_amenities pa
                   JOIN amenities am ON am.id = pa.amenity_id
                   WHERE pa.property_id = %s::uuid ORDER BY am.label""",
                [str(row["property_id"])])
    amenities = dict_rows(cur)

    cur.execute("""SELECT id, storage_key, caption, is_primary, width, height
                   FROM media_assets
                   WHERE property_id = %s::uuid AND media_type = 'photo'
                         AND deleted_at IS NULL
                   ORDER BY is_primary DESC, display_order, created_at""",
                [str(row["property_id"])])
    photos = [photo_payload(r) for r in dict_rows(cur)]

    cur.execute(LOCATION_SQL, [str(row["property_id"])])
    loc_rows = dict_rows(cur)
    location = None
    if loc_rows:
        location = loc_rows[0]
        if location["hide_address"] and not is_owner:
            location["address_line"] = None
        location["latitude"] = to_float(location["latitude"])
        location["longitude"] = to_float(location["longitude"])

    price = None
    if row["amount"] is not None:
        price = {"amount": str(row["amount"]), "currency": row["currency"],
                 "period": row["period"], "is_negotiable": row["is_negotiable"]}

    return {
        "id": row["id"],
        "status": row["status"],
        "listing_type": row["listing_type"],
        "title": row["title"],
        "description": row["description"],
        "contact_phone": row["contact_phone"],
        "published_at": row["published_at"],
        "expires_at": row["expires_at"],
        "price": price,
        "photos": photos,
        "property": {
            "id": row["property_id"],
            "name": row["property_name"],
            "type": {"code": row["property_type_code"], "label": row["property_type_label"]},
            "availability": row["availability"],
            "attributes": attributes,
            "amenities": amenities,
            "location": location,
        },
        "poster": {"username": row["username"], "display_name": row["display_name"],
                   "poster_type": row["poster_type"]},
        "is_owner": is_owner,
    }


# ---------- views ----------

class StartPostingView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        code = request.data.get("poster_type")
        license_number = request.data.get("license_number") or None
        if code not in STARTABLE_POSTERS:
            return Response({"poster_type": f"Choose one of: {', '.join(STARTABLE_POSTERS)}."},
                            status=400)
        with transaction.atomic(), connection.cursor() as cur:
            cur.execute("SELECT id FROM poster_types WHERE code = %s", [code])
            type_id = cur.fetchone()[0]
            cur.execute("""
                INSERT INTO poster_profiles(user_id, poster_type_id, license_number)
                VALUES (%s::uuid, %s, %s)
                ON CONFLICT (user_id) DO UPDATE
                SET poster_type_id = EXCLUDED.poster_type_id,
                    license_number = EXCLUDED.license_number
            """, [str(request.user.id), type_id, license_number])
        return Response({"poster_type": code})


class ListingsView(APIView):
    """POST creates a listing (draft). Searching listings comes in Phase 4."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        s = ListingCreateSerializer(data=request.data)
        s.is_valid(raise_exception=True)
        d = s.validated_data
        user = request.user

        with transaction.atomic(), connection.cursor() as cur:
            set_actor(cur, user)

            # 1. Must have started posting
            cur.execute("""SELECT pt.code FROM poster_profiles pp
                           JOIN poster_types pt ON pt.id = pp.poster_type_id
                           WHERE pp.user_id = %s::uuid""", [str(user.id)])
            poster = cur.fetchone()
            if not poster:
                return Response(
                    {"detail": "Start posting first: POST /api/me/start-posting/"}, status=403)

            # 2. Property type
            cur.execute("SELECT id FROM property_types WHERE code = %s AND is_active",
                        [d["property_type"]])
            row = cur.fetchone()
            if not row:
                raise serializers.ValidationError({"property_type": "Unknown property type."})
            type_id = row[0]

            # 3. Type-specific fields
            cur.execute("""SELECT a.id, a.code, a.data_type::text AS data_type, pta.is_required
                           FROM property_type_attributes pta
                           JOIN attribute_definitions a ON a.id = pta.attribute_id
                           WHERE pta.property_type_id = %s""", [type_id])
            allowed = {r["code"]: r for r in dict_rows(cur)}
            cur.execute("""SELECT o.attribute_id, o.code, o.id FROM attribute_options o
                           WHERE o.attribute_id IN (
                             SELECT attribute_id FROM property_type_attributes
                             WHERE property_type_id = %s)""", [type_id])
            options = {}
            for attr_id, code, opt_id in cur.fetchall():
                options.setdefault(attr_id, {})[code] = opt_id

            attrs = d.get("attributes") or {}
            unknown = sorted(set(attrs) - set(allowed))
            if unknown:
                raise serializers.ValidationError(
                    {"attributes": f"Not valid for {d['property_type']}: {', '.join(unknown)}"})
            missing = sorted(c for c, r in allowed.items()
                             if r["is_required"] and c not in attrs)
            if missing:
                raise serializers.ValidationError(
                    {"attributes": f"Required: {', '.join(missing)}"})
            converted = []
            errors = {}
            for code, raw in attrs.items():
                try:
                    column, value = convert_value(allowed[code], raw, options)
                    converted.append((allowed[code]["id"], column, value))
                except (ValueError, TypeError, InvalidOperation):
                    errors[code] = "Invalid value."
            if errors:
                raise serializers.ValidationError({"attributes": errors})

            # 4. Amenities
            cur.execute("""SELECT am.code, am.id FROM property_type_amenities pa
                           JOIN amenities am ON am.id = pa.amenity_id
                           WHERE pa.property_type_id = %s AND am.is_active""", [type_id])
            amenity_ids = dict(cur.fetchall())
            wanted = sorted(set(d.get("amenities") or []))
            bad = [a for a in wanted if a not in amenity_ids]
            if bad:
                raise serializers.ValidationError(
                    {"amenities": f"Not valid for {d['property_type']}: {', '.join(bad)}"})

            # 5. Location: walk up from the chosen area to fill every level
            loc = d["location"]
            cur.execute("""
                WITH RECURSIVE chain AS (
                  SELECT id, parent_id, level::text AS level FROM geo_areas
                  WHERE id = %s AND is_active
                  UNION ALL
                  SELECT g.id, g.parent_id, g.level::text FROM geo_areas g
                  JOIN chain c ON g.id = c.parent_id
                )
                SELECT level, id FROM chain""", [loc["area_id"]])
            levels = dict(cur.fetchall())
            if "country" not in levels:
                raise serializers.ValidationError({"location": "Unknown area."})

            # 6. Write everything
            cur.execute("""INSERT INTO properties(property_type_id, name, created_by)
                           VALUES (%s, %s, %s::uuid) RETURNING id""",
                        [type_id, d.get("property_name") or None, str(user.id)])
            property_id = cur.fetchone()[0]

            lat, lon = loc.get("latitude"), loc.get("longitude")
            precision = loc.get("coordinate_precision") if lat is not None else "none"
            columns = ["property_id", "address_line", "hide_address",
                       "latitude", "longitude", "coordinate_precision"]
            values = [str(property_id), loc.get("address_line") or None,
                      loc["hide_address"], lat, lon, precision]
            for level, column in LEVEL_COLUMNS.items():
                if level in levels:
                    columns.append(column)
                    values.append(levels[level])
            marks = ["%s::uuid"] + ["%s"] * (len(columns) - 1)
            marks[5] = "%s::coordinate_precision"
            cur.execute(f"INSERT INTO property_locations({', '.join(columns)}) "
                        f"VALUES ({', '.join(marks)})", values)

            for attr_id, column, value in converted:
                cur.execute(f"""INSERT INTO property_attribute_values(property_id, attribute_id, {column})
                                VALUES (%s::uuid, %s, %s)""", [str(property_id), attr_id, value])
            for code in wanted:
                cur.execute("""INSERT INTO property_amenities(property_id, amenity_id)
                               VALUES (%s::uuid, %s)""", [str(property_id), amenity_ids[code]])

            cur.execute("""INSERT INTO property_relationships(property_id, user_id, type)
                           VALUES (%s::uuid, %s::uuid, %s::relationship_type)""",
                        [str(property_id), str(user.id), RELATIONSHIP_FOR[poster[0]]])

            cur.execute("""INSERT INTO listings(property_id, listing_type, status,
                               responsible_user_id, title, description, contact_phone)
                           VALUES (%s::uuid, %s::listing_type, 'draft', %s::uuid, %s, %s, %s)
                           RETURNING id""",
                        [str(property_id), d["listing_type"], str(user.id), d["title"],
                         d.get("description") or None,
                         d.get("contact_phone") or user.phone])
            listing_id = cur.fetchone()[0]

            price = d["price"]
            cur.execute("""SELECT set_listing_price(%s::uuid, %s::numeric, %s::char(3),
                                  %s::price_period, %s, %s::uuid)""",
                        [str(listing_id), price["amount"], price["currency"],
                         price["period"], price["is_negotiable"], str(user.id)])

            detail = build_detail(cur, listing_id, user.id)
        return Response(detail, status=201)


class ListingDetailView(APIView):
    def get_permissions(self):
        return [AllowAny()] if self.request.method == "GET" else [IsAuthenticated()]

    def get(self, request, listing_id):
        viewer = request.user.id if request.user.is_authenticated else None
        with connection.cursor() as cur:
            detail = build_detail(cur, listing_id, viewer)
        return Response(detail) if detail else not_found()

    def patch(self, request, listing_id):
        s = ListingUpdateSerializer(data=request.data)
        s.is_valid(raise_exception=True)
        d = s.validated_data
        if not d:
            return Response({"detail": "Nothing to update."}, status=400)
        user = request.user
        with transaction.atomic(), connection.cursor() as cur:
            set_actor(cur, user)
            cur.execute("""SELECT responsible_user_id, listing_type::text FROM listings
                           WHERE id = %s::uuid AND deleted_at IS NULL FOR UPDATE""",
                        [str(listing_id)])
            row = cur.fetchone()
            if not row or str(row[0]) != str(user.id):
                return not_found()

            fields = [(k, d[k] or None) for k in ("title", "description", "contact_phone")
                      if k in d]
            if fields:
                sets = ", ".join(f"{name} = %s" for name, _ in fields)
                cur.execute(f"UPDATE listings SET {sets} WHERE id = %s::uuid",
                            [value for _, value in fields] + [str(listing_id)])

            if "price" in d:
                price = d["price"]
                check_price_period(row[1], price["period"])
                cur.execute("""SELECT amount, currency, period::text, is_negotiable
                               FROM listing_prices
                               WHERE listing_id = %s::uuid AND effective_to IS NULL""",
                            [str(listing_id)])
                current = cur.fetchone()
                new = (price["amount"], price["currency"], price["period"],
                       price["is_negotiable"])
                if current is None or tuple(current) != new:
                    cur.execute("""SELECT set_listing_price(%s::uuid, %s::numeric, %s::char(3),
                                          %s::price_period, %s, %s::uuid)""",
                                [str(listing_id), price["amount"], price["currency"],
                                 price["period"], price["is_negotiable"], str(user.id)])
            detail = build_detail(cur, listing_id, user.id)
        return Response(detail)


class ListingActionView(APIView):
    """POST /api/listings/<id>/publish|pause|close/"""
    permission_classes = [IsAuthenticated]

    def post(self, request, listing_id, action):
        if action not in TRANSITIONS:
            return not_found()
        allowed_from, new_status = TRANSITIONS[action]
        user = request.user
        with transaction.atomic(), connection.cursor() as cur:
            set_actor(cur, user, reason=action)
            cur.execute("""SELECT status::text, responsible_user_id FROM listings
                           WHERE id = %s::uuid AND deleted_at IS NULL FOR UPDATE""",
                        [str(listing_id)])
            row = cur.fetchone()
            if not row or str(row[1]) != str(user.id):
                return not_found()
            current = row[0]
            if current not in allowed_from:
                return Response(
                    {"detail": f"A listing that is '{current}' cannot be {action}ed."},
                    status=409)

            if action == "publish":
                cur.execute("""SELECT 1 FROM listing_prices
                               WHERE listing_id = %s::uuid AND effective_to IS NULL""",
                            [str(listing_id)])
                if not cur.fetchone():
                    return Response({"detail": "Set a price before publishing."}, status=409)
                cur.execute("""SELECT 1 FROM media_assets m
                               JOIN listings l ON l.property_id = m.property_id
                               WHERE l.id = %s::uuid AND m.media_type = 'photo'
                                     AND m.deleted_at IS NULL LIMIT 1""",
                            [str(listing_id)])
                if not cur.fetchone():
                    return Response({"detail": "Add at least one photo before publishing."},
                                    status=409)
                if current == "paused":
                    cur.execute("""UPDATE listings SET status = 'active'
                                   WHERE id = %s::uuid""", [str(listing_id)])
                else:
                    cur.execute("""UPDATE listings SET status = 'active', published_at = now(),
                                       expires_at = now() + interval '60 days', closed_at = NULL
                                   WHERE id = %s::uuid""", [str(listing_id)])
            elif action == "pause":
                cur.execute("UPDATE listings SET status = 'paused' WHERE id = %s::uuid",
                            [str(listing_id)])
            else:
                cur.execute("""UPDATE listings SET status = 'closed', closed_at = now()
                               WHERE id = %s::uuid""", [str(listing_id)])
            detail = build_detail(cur, listing_id, user.id)
        return Response(detail)


class MyListingsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        with connection.cursor() as cur:
            cur.execute("""
                SELECT l.id, l.title, l.listing_type::text AS listing_type,
                       l.status::text AS status, l.published_at, l.expires_at, l.created_at,
                       pr.amount::text AS amount, pr.currency, pr.period::text AS period,
                       pt.code AS property_type,
                       (SELECT m.storage_key FROM media_assets m
                         WHERE m.property_id = p.id AND m.is_primary
                               AND m.deleted_at IS NULL) AS cover_key
                FROM listings l
                JOIN properties p ON p.id = l.property_id
                JOIN property_types pt ON pt.id = p.property_type_id
                LEFT JOIN listing_prices pr ON pr.listing_id = l.id AND pr.effective_to IS NULL
                WHERE l.responsible_user_id = %s::uuid AND l.deleted_at IS NULL
                ORDER BY l.created_at DESC
                LIMIT 100""", [str(request.user.id)])
            rows = dict_rows(cur)
        for r in rows:
            key = r.pop("cover_key")
            r["cover"] = photo_payload({"id": None, "storage_key": key})["urls"] if key else None
        return Response(rows)
