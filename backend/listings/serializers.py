from rest_framework import serializers

LISTING_TYPES = ["sale", "rent", "lease"]
PERIODS = ["total", "per_month", "per_year"]


def check_price_period(listing_type, period):
    if listing_type == "sale" and period != "total":
        raise serializers.ValidationError(
            {"price": "A property for sale needs a total price (period: total)."})
    if listing_type == "rent" and period == "total":
        raise serializers.ValidationError(
            {"price": "A rental needs a price per_month or per_year."})


class PriceSerializer(serializers.Serializer):
    amount = serializers.DecimalField(max_digits=14, decimal_places=2, min_value=0)
    currency = serializers.ChoiceField(choices=["ETB", "USD"], default="ETB")
    period = serializers.ChoiceField(choices=PERIODS)
    is_negotiable = serializers.BooleanField(default=False)


class LocationSerializer(serializers.Serializer):
    area_id = serializers.IntegerField()          # most specific area picked
    address_line = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    hide_address = serializers.BooleanField(default=False)
    latitude = serializers.DecimalField(max_digits=9, decimal_places=6, required=False,
                                        allow_null=True, min_value=-90, max_value=90)
    longitude = serializers.DecimalField(max_digits=9, decimal_places=6, required=False,
                                         allow_null=True, min_value=-180, max_value=180)
    coordinate_precision = serializers.ChoiceField(
        choices=["exact", "approximate"], required=False)

    def validate(self, attrs):
        lat, lon = attrs.get("latitude"), attrs.get("longitude")
        if (lat is None) != (lon is None):
            raise serializers.ValidationError("Send both latitude and longitude, or neither.")
        if lat is not None and "coordinate_precision" not in attrs:
            attrs["coordinate_precision"] = "approximate"
        return attrs


class ListingCreateSerializer(serializers.Serializer):
    property_type = serializers.CharField()
    listing_type = serializers.ChoiceField(choices=LISTING_TYPES)
    title = serializers.CharField(max_length=150)
    description = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    contact_phone = serializers.CharField(required=False, allow_blank=True, allow_null=True,
                                          max_length=32)
    property_name = serializers.CharField(required=False, allow_blank=True, allow_null=True,
                                          max_length=150)
    attributes = serializers.DictField(child=serializers.JSONField(), required=False)
    amenities = serializers.ListField(child=serializers.CharField(), required=False)
    location = LocationSerializer()
    price = PriceSerializer()

    def validate(self, attrs):
        check_price_period(attrs["listing_type"], attrs["price"]["period"])
        return attrs


class ListingUpdateSerializer(serializers.Serializer):
    title = serializers.CharField(max_length=150, required=False)
    description = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    contact_phone = serializers.CharField(required=False, allow_blank=True, allow_null=True,
                                          max_length=32)
    price = PriceSerializer(required=False)
