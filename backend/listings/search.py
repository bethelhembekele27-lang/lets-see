from decimal import Decimal, InvalidOperation

from django.db import connection
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.throttling import AnonRateThrottle
from rest_framework.views import APIView

from .media import photo_payload
from .views import dict_rows, to_float

LISTING_TYPES = {"sale", "rent", "lease"}
CURRENCIES = {"ETB", "USD"}
MAX_PAGE_SIZE = 50
DEFAULT_PAGE_SIZE = 20

# Rent prices quoted per year are compared as monthly amounts.
PRICE_VALUE = ("CASE WHEN l.listing_type = 'rent' AND pr.period = 'per_year' "
               "THEN pr.amount / 12 ELSE pr.amount END")

SORTS = {
    "newest": "s.published_at DESC, s.listing_id",
    "price_asc": "price_value ASC, s.published_at DESC, s.listing_id",
    "price_desc": "price_value DESC, s.published_at DESC, s.listing_id",
}


class BadParam(Exception):
    pass


class SearchThrottle(AnonRateThrottle):
    """Slows down bots: 120 searches a minute per device."""
    scope = "search"
    rate = "120/min"


def marks(items):
    return ", ".join(["%s"] * len(items))


def csv(raw):
    if not raw:
        return []
    items = [part.strip() for part in raw.split(",") if part.strip()]
    if len(items) > 20:
        raise BadParam("Too many values in one filter (maximum 20).")
    return items


def to_decimal(name, raw):
    try:
        value = Decimal(raw)
    except InvalidOperation:
        raise BadParam(f"{name} must be a number.")
    if not value.is_finite() or value < 0 or value > Decimal("99999999999"):
        raise BadParam(f"{name} is out of range.")
    return value


def to_whole(name, raw, minimum=0, maximum=10**9):
    if not raw.isdigit() or not (minimum <= int(raw) <= maximum):
        raise BadParam(f"{name} must be a whole number.")
    return int(raw)


def attr_sql(code, column, alias):
    return (f"(SELECT v.{column} FROM property_attribute_values v "
            f"JOIN attribute_definitions a ON a.id = v.attribute_id "
            f"WHERE v.property_id = p.id AND a.code = '{code}') AS {alias}")


def build_search(p, attribute_defs):
    """Turn the query string into (sql, params, page, page_size). No database needed."""
    where, params = [], []

    listing_type = p.get("listing_type")
    if listing_type:
        if listing_type not in LISTING_TYPES:
            raise BadParam("listing_type must be sale, rent or lease.")
        where.append("s.listing_type = %s::listing_type")
        params.append(listing_type)

    area = p.get("area")
    if area:
        where.append("%s IN (pl.country_id, pl.region_id, pl.city_id, "
                     "pl.sub_city_id, pl.woreda_id, pl.neighborhood_id)")
        params.append(to_whole("area", area))

    types = csv(p.get("property_type"))
    if types:
        where.append(f"pt.code IN ({marks(types)})")
        params += types

    currency = (p.get("currency") or "ETB").upper()
    if currency not in CURRENCIES:
        raise BadParam("currency must be ETB or USD.")
    min_price, max_price = p.get("min_price"), p.get("max_price")
    if min_price or max_price:
        where.append("pr.currency = %s")
        params.append(currency)
    if min_price:
        where.append(f"{PRICE_VALUE} >= %s")
        params.append(to_decimal("min_price", min_price))
    if max_price:
        where.append(f"{PRICE_VALUE} <= %s")
        params.append(to_decimal("max_price", max_price))

    # min_<field> / max_<field> for numbers, <field>=a,b for option fields
    for key in list(p.keys()):
        if key.startswith(("min_", "max_")) and key not in ("min_price", "max_price"):
            definition = attribute_defs.get(key[4:])
            if definition and definition["data_type"] in ("integer", "decimal"):
                operator = ">=" if key.startswith("min_") else "<="
                where.append(
                    "EXISTS (SELECT 1 FROM property_attribute_values v "
                    "WHERE v.property_id = p.id AND v.attribute_id = %s "
                    f"AND COALESCE(v.value_dec, v.value_int) {operator} %s)")
                params += [definition["id"], to_decimal(key, p.get(key))]
        elif key in attribute_defs and attribute_defs[key]["data_type"] == "option":
            codes = csv(p.get(key))
            if codes:
                where.append(
                    "EXISTS (SELECT 1 FROM property_attribute_values v "
                    "JOIN attribute_options o ON o.id = v.option_id "
                    "WHERE v.property_id = p.id AND v.attribute_id = %s "
                    f"AND o.code IN ({marks(codes)}))")
                params += [attribute_defs[key]["id"]] + codes

    amenities = csv(p.get("amenities"))
    if amenities:
        where.append(
            "(SELECT count(DISTINCT am.code) FROM property_amenities pa "
            "JOIN amenities am ON am.id = pa.amenity_id "
            f"WHERE pa.property_id = p.id AND am.code IN ({marks(amenities)})) = %s")
        params += amenities + [len(set(amenities))]

    q = (p.get("q") or "").strip()[:100]
    if q:
        like = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        where.append("(s.search_vector @@ plainto_tsquery('simple', %s) OR s.title ILIKE %s)")
        params += [q, like]

    sort = p.get("sort") or "newest"
    if sort not in SORTS:
        raise BadParam("sort must be newest, price_asc or price_desc.")
    page = to_whole("page", p.get("page") or "1", minimum=1, maximum=1000)
    page_size = to_whole("page_size", p.get("page_size") or str(DEFAULT_PAGE_SIZE),
                         minimum=1, maximum=MAX_PAGE_SIZE)

    sql = f"""
    SELECT s.listing_id AS id, l.title, s.listing_type::text AS listing_type,
           s.published_at,
           pr.amount, pr.currency, pr.period::text AS period, pr.is_negotiable,
           {PRICE_VALUE} AS price_value,
           pt.code AS property_type_code, pt.label AS property_type_label,
           p.availability_status::text AS availability,
           ci.name AS city, sc.name AS sub_city, ne.name AS neighborhood,
           {attr_sql('bedrooms', 'value_int', 'bedrooms')},
           {attr_sql('bathrooms', 'value_int', 'bathrooms')},
           {attr_sql('floor_area_m2', 'value_dec', 'floor_area_m2')},
           {attr_sql('land_size_m2', 'value_dec', 'land_size_m2')},
           (SELECT m.storage_key FROM media_assets m
             WHERE m.property_id = p.id AND m.is_primary AND m.deleted_at IS NULL) AS cover_key,
           pf.display_name AS poster_name, ppt.code AS poster_type
    FROM v_searchable_listings s
    JOIN listings l ON l.id = s.listing_id
    JOIN properties p ON p.id = s.property_id
    JOIN property_types pt ON pt.id = p.property_type_id
    JOIN listing_prices pr ON pr.listing_id = s.listing_id AND pr.effective_to IS NULL
    LEFT JOIN property_locations pl ON pl.property_id = p.id
    LEFT JOIN geo_areas ci ON ci.id = pl.city_id
    LEFT JOIN geo_areas sc ON sc.id = pl.sub_city_id
    LEFT JOIN geo_areas ne ON ne.id = pl.neighborhood_id
    LEFT JOIN profiles pf ON pf.user_id = s.responsible_user_id
    LEFT JOIN poster_profiles pp ON pp.user_id = s.responsible_user_id
    LEFT JOIN poster_types ppt ON ppt.id = pp.poster_type_id
    WHERE {' AND '.join(where) if where else 'TRUE'}
    ORDER BY {SORTS[sort]}
    LIMIT %s OFFSET %s
    """
    # one extra row tells us whether another page exists, without a slow count
    params += [page_size + 1, (page - 1) * page_size]
    return sql, params, page, page_size


def shape(row):
    key = row["cover_key"]
    return {
        "id": row["id"],
        "title": row["title"],
        "listing_type": row["listing_type"],
        "published_at": row["published_at"],
        "price": {"amount": str(row["amount"]), "currency": row["currency"],
                  "period": row["period"], "is_negotiable": row["is_negotiable"]},
        "property_type": {"code": row["property_type_code"],
                          "label": row["property_type_label"]},
        "availability": row["availability"],
        "location": {"city": row["city"], "sub_city": row["sub_city"],
                     "neighborhood": row["neighborhood"]},
        "bedrooms": row["bedrooms"],
        "bathrooms": row["bathrooms"],
        "floor_area_m2": to_float(row["floor_area_m2"]),
        "land_size_m2": to_float(row["land_size_m2"]),
        "cover": photo_payload({"id": None, "storage_key": key})["urls"] if key else None,
        "poster": {"display_name": row["poster_name"], "poster_type": row["poster_type"]},
    }


class SearchView(APIView):
    """
    GET /api/search/
      listing_type=rent|sale|lease     area=<area id, any level>
      property_type=apartment,villa    min_price / max_price / currency=ETB|USD
      min_bedrooms=2  min_bathrooms=1  min_floor_area_m2 / max_land_size_m2 ...
      furnishing=furnished,semi_furnished
      amenities=parking,elevator       (the listing must have all of them)
      q=text                           sort=newest|price_asc|price_desc
      page=1  page_size=20
    Only live listings are returned (the database view hides everything else).
    """
    authentication_classes = []
    permission_classes = [AllowAny]
    throttle_classes = [SearchThrottle]

    def get(self, request):
        with connection.cursor() as cur:
            cur.execute("SELECT id, code, data_type::text AS data_type "
                        "FROM attribute_definitions")
            attribute_defs = {r["code"]: r for r in dict_rows(cur)}
            try:
                sql, params, page, page_size = build_search(request.query_params,
                                                            attribute_defs)
            except BadParam as error:
                return Response({"detail": str(error)}, status=400)
            cur.execute(sql, params)
            rows = dict_rows(cur)
        return Response({
            "results": [shape(r) for r in rows[:page_size]],
            "page": page,
            "page_size": page_size,
            "has_more": len(rows) > page_size,
        })