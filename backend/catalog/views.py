import json

from django.db import connection
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

# The catalog rarely changes, so phones may keep it for an hour.
# That saves mobile data and battery.
CACHE = "public, max-age=3600"
JSON_KEYS = ("attributes", "amenities")
LEVELS = {"country", "region", "city", "sub_city", "woreda", "neighborhood"}


def fetch_all(sql, params=None):
    with connection.cursor() as cur:
        cur.execute(sql, params or [])
        cols = [c[0] for c in cur.description]
        rows = cur.fetchall()
    result = []
    for row in rows:
        item = dict(zip(cols, row))
        for key in JSON_KEYS:
            if isinstance(item.get(key), str):
                item[key] = json.loads(item[key])
        result.append(item)
    return result


def cached(data):
    response = Response(data)
    response["Cache-Control"] = CACHE
    return response


class PublicView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]


class PropertyTypesView(PublicView):
    SQL = """
    SELECT t.id, t.code, t.label,
      COALESCE((
        SELECT json_agg(json_build_object(
          'code', a.code, 'label', a.label, 'data_type', a.data_type::text,
          'unit', a.unit, 'required', pta.is_required, 'filterable', pta.is_filterable,
          'options', COALESCE((
            SELECT json_agg(json_build_object('code', o.code, 'label', o.label)
                            ORDER BY o.sort_order)
            FROM attribute_options o WHERE o.attribute_id = a.id), '[]'::json)
        ) ORDER BY pta.sort_order)
        FROM property_type_attributes pta
        JOIN attribute_definitions a ON a.id = pta.attribute_id
        WHERE pta.property_type_id = t.id), '[]'::json) AS attributes,
      COALESCE((
        SELECT json_agg(json_build_object('code', am.code, 'label', am.label)
                        ORDER BY am.label)
        FROM property_type_amenities pa
        JOIN amenities am ON am.id = pa.amenity_id
        WHERE pa.property_type_id = t.id AND am.is_active), '[]'::json) AS amenities
    FROM property_types t
    WHERE t.is_active
    ORDER BY t.sort_order, t.id
    """

    def get(self, request):
        return cached(fetch_all(self.SQL))


class AreasView(PublicView):
    """
    /api/catalog/areas/                  top level (countries)
    /api/catalog/areas/?parent=5         children of area 5
    /api/catalog/areas/?level=sub_city   all areas at one level
    /api/catalog/areas/?q=bole           search by name (English or Amharic)
    """

    def get(self, request):
        where = ["g.is_active"]
        params = []
        parent = request.query_params.get("parent")
        level = request.query_params.get("level")
        q = request.query_params.get("q", "").strip()

        if parent and parent.isdigit():
            where.append("g.parent_id = %s")
            params.append(int(parent))
        elif level in LEVELS:
            where.append("g.level = %s::geo_level")
            params.append(level)
        elif not q:
            where.append("g.parent_id IS NULL")

        if q:
            where.append("(g.name ILIKE %s OR g.name_am ILIKE %s)")
            params += [f"%{q}%", f"%{q}%"]

        sql = f"""
        SELECT g.id, g.parent_id, g.level::text AS level, g.name, g.name_am, g.slug,
               (SELECT count(*) FROM geo_areas c
                 WHERE c.parent_id = g.id AND c.is_active) AS children
        FROM geo_areas g
        WHERE {' AND '.join(where)}
        ORDER BY g.name
        LIMIT 200
        """
        return cached(fetch_all(sql, params))


class CurrenciesView(PublicView):
    def get(self, request):
        return cached(fetch_all(
            "SELECT code, name, symbol FROM currencies WHERE is_active ORDER BY code"))