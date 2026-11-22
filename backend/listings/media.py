
import io
import uuid
 
from django.core.files.base import ContentFile
from django.core.files.storage import default_storage
from PIL import Image, ImageOps, UnidentifiedImageError
 
MAX_UPLOAD_BYTES = 10 * 1024 * 1024      # 10 MB per photo
MAX_PHOTOS_PER_LISTING = 20
MAX_PHOTOS_PER_UPLOAD = 10
ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}
 
# suffix -> (longest side in pixels, JPEG quality)
# l = large (full screen), m = medium (normal lists), s = small (Data Saver, thumbnails)
SIZES = {"l": (1600, 82), "m": (800, 78), "s": (400, 70)}
 
 
class BadImage(Exception):
    pass
 
 
def process_image(uploaded):
    """Check an uploaded photo and make the three JPEG sizes.
 
    Returns ({'l': bytes, 'm': bytes, 's': bytes}, (width, height) of the large one).
    Re-saving also removes hidden data from the photo, such as the GPS position.
    """
    if uploaded.size > MAX_UPLOAD_BYTES:
        raise BadImage("The photo is larger than 10 MB.")
    try:
        img = Image.open(uploaded)
        file_format = img.format
        img.load()
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError,
            Image.DecompressionBombError):
        raise BadImage("This file is not a valid photo.")
    if file_format not in ALLOWED_FORMATS:
        raise BadImage("Use a JPEG, PNG or WebP photo.")
 
    img = ImageOps.exif_transpose(img)          # fixes photos taken sideways
    if img.mode in ("RGBA", "LA", "P"):
        rgba = img.convert("RGBA")
        flat = Image.new("RGB", rgba.size, (255, 255, 255))
        flat.paste(rgba, mask=rgba.split()[-1])
        img = flat
    else:
        img = img.convert("RGB")
 
    variants = {}
    large_size = img.size
    for suffix, (side, quality) in SIZES.items():
        copy = img.copy()
        copy.thumbnail((side, side), Image.Resampling.LANCZOS)   # never enlarges
        buffer = io.BytesIO()
        copy.save(buffer, "JPEG", quality=quality, optimize=True, progressive=True)
        variants[suffix] = buffer.getvalue()
        if suffix == "l":
            large_size = copy.size
    return variants, large_size
 
 
def save_variants(property_id, variants):
    """Store the three sizes. Returns (large_key, small_key)."""
    base = f"properties/{property_id}/{uuid.uuid4().hex}"
    for suffix, data in variants.items():
        default_storage.save(f"{base}_{suffix}.jpg", ContentFile(data))
    return f"{base}_l.jpg", f"{base}_s.jpg"
 
 
def key_for(large_key, suffix):
    return large_key[:-len("_l.jpg")] + f"_{suffix}.jpg"
 
 
def photo_payload(row):
    large = row["storage_key"]
    return {
        "id": row["id"],
        "caption": row.get("caption"),
        "is_primary": row.get("is_primary", False),
        "width": row.get("width"),
        "height": row.get("height"),
        "urls": {
            "small": default_storage.url(key_for(large, "s")),
            "medium": default_storage.url(key_for(large, "m")),
            "large": default_storage.url(large),
        },
    }
 