from django.db import connection, transaction
from rest_framework.parsers import FormParser, MultiPartParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .media import (MAX_PHOTOS_PER_LISTING, MAX_PHOTOS_PER_UPLOAD, BadImage,
                    photo_payload, process_image, save_variants)
from .views import dict_rows, not_found, set_actor

PHOTO_COLUMNS = "id, storage_key, caption, is_primary, width, height"


def lock_owned_listing(cur, listing_id, user):
    """Returns (property_id, status), or None if the listing isn't yours."""
    cur.execute("""SELECT property_id, status::text, responsible_user_id FROM listings
                   WHERE id = %s::uuid AND deleted_at IS NULL FOR UPDATE""",
                [str(listing_id)])
    row = cur.fetchone()
    if not row or str(row[2]) != str(user.id):
        return None
    return row[0], row[1]


class PhotosView(APIView):
    """POST /api/listings/<id>/photos/  (form field 'photos', one or several files)"""
    permission_classes = [IsAuthenticated]
    parser_classes = [MultiPartParser, FormParser]

    def post(self, request, listing_id):
        user = request.user
        with connection.cursor() as cur:
            cur.execute("""SELECT 1 FROM listings WHERE id = %s::uuid AND deleted_at IS NULL
                           AND responsible_user_id = %s::uuid""",
                        [str(listing_id), str(user.id)])
            if not cur.fetchone():
                return not_found()

        files = request.FILES.getlist("photos") + request.FILES.getlist("photo")
        if not files:
            return Response({"detail": "Send at least one photo in the 'photos' field."},
                            status=400)
        if len(files) > MAX_PHOTOS_PER_UPLOAD:
            return Response(
                {"detail": f"Upload at most {MAX_PHOTOS_PER_UPLOAD} photos at a time."},
                status=400)

        processed = []
        for f in files:                      # check every photo before saving any
            try:
                variants, size = process_image(f)
            except BadImage as error:
                return Response({"detail": f"{f.name}: {error}"}, status=400)
            processed.append((variants, size))
        caption = request.data.get("caption") or None if len(files) == 1 else None

        with transaction.atomic(), connection.cursor() as cur:
            set_actor(cur, user)
            owned = lock_owned_listing(cur, listing_id, user)
            if owned is None:
                return not_found()
            property_id = owned[0]
            cur.execute("""SELECT count(*), COALESCE(max(display_order), -1),
                                  COALESCE(bool_or(is_primary), false)
                           FROM media_assets
                           WHERE property_id = %s::uuid AND media_type = 'photo'
                                 AND deleted_at IS NULL""", [str(property_id)])
            existing, last_order, has_primary = cur.fetchone()
            if existing + len(processed) > MAX_PHOTOS_PER_LISTING:
                return Response(
                    {"detail": f"A listing can have at most {MAX_PHOTOS_PER_LISTING} photos."},
                    status=400)

            created = []
            for index, (variants, (width, height)) in enumerate(processed):
                large_key, small_key = save_variants(property_id, variants)
                cur.execute(f"""
                    INSERT INTO media_assets(property_id, listing_id, uploaded_by, media_type,
                        storage_key, thumbnail_key, mime_type, size_bytes, width, height,
                        caption, display_order, is_primary)
                    VALUES (%s::uuid, %s::uuid, %s::uuid, 'photo', %s, %s, 'image/jpeg',
                        %s, %s, %s, %s, %s, %s)
                    RETURNING {PHOTO_COLUMNS}""",
                            [str(property_id), str(listing_id), str(user.id), large_key,
                             small_key, len(variants["l"]), width, height, caption,
                             last_order + 1 + index, (not has_primary and index == 0)])
                created.append(photo_payload(dict_rows(cur)[0]))
        return Response({"photos": created}, status=201)


class PhotoDetailView(APIView):
    """DELETE /api/listings/<id>/photos/<photo_id>/"""
    permission_classes = [IsAuthenticated]

    def delete(self, request, listing_id, photo_id):
        user = request.user
        with transaction.atomic(), connection.cursor() as cur:
            set_actor(cur, user)
            owned = lock_owned_listing(cur, listing_id, user)
            if owned is None:
                return not_found()
            property_id, status = owned
            cur.execute("""SELECT is_primary FROM media_assets
                           WHERE id = %s::uuid AND property_id = %s::uuid
                                 AND media_type = 'photo' AND deleted_at IS NULL
                           FOR UPDATE""", [str(photo_id), str(property_id)])
            row = cur.fetchone()
            if not row:
                return not_found()
            cur.execute("""SELECT count(*) FROM media_assets
                           WHERE property_id = %s::uuid AND media_type = 'photo'
                                 AND deleted_at IS NULL""", [str(property_id)])
            if status == "active" and cur.fetchone()[0] <= 1:
                return Response(
                    {"detail": "A live listing needs at least one photo. "
                               "Add another photo first, or pause the listing."},
                    status=409)
            cur.execute("""UPDATE media_assets SET deleted_at = now(), is_primary = false
                           WHERE id = %s::uuid""", [str(photo_id)])
            if row[0]:       # it was the main photo: promote the next one
                cur.execute("""
                    UPDATE media_assets SET is_primary = true
                    WHERE id = (SELECT id FROM media_assets
                                WHERE property_id = %s::uuid AND media_type = 'photo'
                                      AND deleted_at IS NULL
                                ORDER BY display_order, created_at LIMIT 1)""",
                            [str(property_id)])
        return Response(status=204)


class PhotoPrimaryView(APIView):
    """POST /api/listings/<id>/photos/<photo_id>/primary/  makes it the main photo"""
    permission_classes = [IsAuthenticated]

    def post(self, request, listing_id, photo_id):
        user = request.user
        with transaction.atomic(), connection.cursor() as cur:
            set_actor(cur, user)
            owned = lock_owned_listing(cur, listing_id, user)
            if owned is None:
                return not_found()
            property_id = owned[0]
            cur.execute("""SELECT 1 FROM media_assets
                           WHERE id = %s::uuid AND property_id = %s::uuid
                                 AND media_type = 'photo' AND deleted_at IS NULL""",
                        [str(photo_id), str(property_id)])
            if not cur.fetchone():
                return not_found()
            cur.execute("""UPDATE media_assets SET is_primary = false
                           WHERE property_id = %s::uuid AND is_primary
                                 AND deleted_at IS NULL""", [str(property_id)])
            cur.execute("UPDATE media_assets SET is_primary = true WHERE id = %s::uuid",
                        [str(photo_id)])
            cur.execute(f"""SELECT {PHOTO_COLUMNS} FROM media_assets
                            WHERE id = %s::uuid""", [str(photo_id)])
            return Response(photo_payload(dict_rows(cur)[0]))
