import re

from django.contrib.auth.password_validation import validate_password
from django.db import transaction
from rest_framework import serializers

from .models import Profile, User, UserSettings


def normalize_phone(value):
    """Turn 0911234567, 251911234567 or +251911234567 into +251911234567."""
    if not value:
        return None
    v = re.sub(r"[\s\-()]", "", value)
    if re.fullmatch(r"0[79]\d{8}", v):
        v = "+251" + v[1:]
    elif re.fullmatch(r"251\d{9}", v):
        v = "+" + v
    return v if re.fullmatch(r"\+\d{9,15}", v) else None


def find_user(identifier):
    """Find a user by email, phone number or username."""
    ident = identifier.strip()
    if "@" in ident:
        return User.objects.filter(email=ident.lower()).first()
    phone = normalize_phone(ident)
    if phone:
        user = User.objects.filter(phone=phone).first()
        if user:
            return user
    return User.objects.filter(username=ident.lower()).first()


class RegisterSerializer(serializers.Serializer):
    username = serializers.RegexField(
        r"^[A-Za-z0-9_.]{3,30}$",
        error_messages={"invalid": "Use 3 to 30 letters, numbers, dots or underscores."},
    )
    email = serializers.EmailField(required=False, allow_blank=True, allow_null=True)
    phone = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    password = serializers.CharField(write_only=True, min_length=8)
    display_name = serializers.CharField(max_length=100)

    def validate_username(self, value):
        value = value.lower()
        if User.objects.filter(username=value).exists():
            raise serializers.ValidationError("This username is already taken.")
        return value

    def validate_email(self, value):
        if not value:
            return None
        value = value.strip().lower()
        if User.objects.filter(email=value).exists():
            raise serializers.ValidationError("This email is already registered.")
        return value

    def validate_phone(self, value):
        if not value:
            return None
        phone = normalize_phone(value)
        if phone is None:
            raise serializers.ValidationError("Enter a valid phone number, for example 0911234567.")
        if User.objects.filter(phone=phone).exists():
            raise serializers.ValidationError("This phone number is already registered.")
        return phone

    def validate(self, attrs):
        if not attrs.get("email") and not attrs.get("phone"):
            raise serializers.ValidationError("Provide an email or a phone number.")
        validate_password(attrs["password"])
        return attrs

    def create(self, validated_data):
        with transaction.atomic():
            user = User.objects.create_user(
                username=validated_data["username"],
                email=validated_data.get("email"),
                phone=validated_data.get("phone"),
                password=validated_data["password"],
            )
            Profile.objects.create(user=user, display_name=validated_data["display_name"])
            UserSettings.objects.create(user=user)
        return user


class LoginSerializer(serializers.Serializer):
    identifier = serializers.CharField()   # email, phone or username
    password = serializers.CharField()


class ProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = Profile
        fields = ["display_name", "bio", "avatar_color", "home_city_id",
                  "public_phone", "public_email"]


class UserSettingsSerializer(serializers.ModelSerializer):
    theme = serializers.ChoiceField(choices=["light", "dark", "system"], required=False)
    default_listing_type = serializers.ChoiceField(
        choices=["sale", "rent", "lease"], required=False, allow_null=True)

    class Meta:
        model = UserSettings
        fields = ["theme", "locale", "show_read_receipts", "show_online_status",
                  "discoverable", "default_listing_type", "data_saver",
                  "quiet_hours_start", "quiet_hours_end"]


class UserSerializer(serializers.ModelSerializer):
    profile = ProfileSerializer(read_only=True)
    settings = UserSettingsSerializer(read_only=True)

    class Meta:
        model = User
        fields = ["id", "username", "email", "phone", "status",
                  "created_at", "profile", "settings"]