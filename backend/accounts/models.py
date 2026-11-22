import uuid

from django.contrib.auth.base_user import AbstractBaseUser, BaseUserManager
from django.db import models
from django.utils import timezone


class UserManager(BaseUserManager):
    def create_user(self, username, email=None, phone=None, password=None):
        if not (email or phone):
            raise ValueError("An email or a phone number is required.")
        user = self.model(
            username=username.strip().lower(),
            email=email.strip().lower() if email else None,
            phone=phone.strip() if phone else None,
        )
        user.set_password(password)
        user.save(using=self._db)
        return user


class User(AbstractBaseUser):
    """Maps to the existing `users` table. Django does not create or change it."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    email = models.EmailField(unique=True, null=True, blank=True)
    phone = models.CharField(max_length=32, unique=True, null=True, blank=True)
    username = models.CharField(max_length=150, unique=True)
    password = models.CharField(db_column="password_hash", max_length=255, null=True, blank=True)
    status = models.CharField(max_length=20, default="active")
    email_verified_at = models.DateTimeField(null=True, blank=True)
    phone_verified_at = models.DateTimeField(null=True, blank=True)
    last_login = models.DateTimeField(db_column="last_login_at", null=True, blank=True)
    created_at = models.DateTimeField(default=timezone.now)
    updated_at = models.DateTimeField(auto_now=True)
    deleted_at = models.DateTimeField(null=True, blank=True)

    USERNAME_FIELD = "username"
    REQUIRED_FIELDS = []

    objects = UserManager()

    class Meta:
        db_table = "users"
        managed = False

    @property
    def is_active(self):
        return self.status == "active" and self.deleted_at is None

    # Admin/staff rights will come from the roles tables in a later step.
    @property
    def is_staff(self):
        return False

    @property
    def is_superuser(self):
        return False

    def __str__(self):
        return self.username


class Profile(models.Model):
    user = models.OneToOneField(
        User, primary_key=True, on_delete=models.CASCADE,
        db_column="user_id", related_name="profile",
    )
    display_name = models.CharField(max_length=100)
    bio = models.TextField(null=True, blank=True)
    avatar_storage_key = models.TextField(null=True, blank=True)
    avatar_color = models.SmallIntegerField(null=True, blank=True)
    home_city_id = models.BigIntegerField(null=True, blank=True)
    public_phone = models.CharField(max_length=32, null=True, blank=True)
    public_email = models.EmailField(null=True, blank=True)
    created_at = models.DateTimeField(default=timezone.now)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "profiles"
        managed = False


class UserSettings(models.Model):
    user = models.OneToOneField(
        User, primary_key=True, on_delete=models.CASCADE,
        db_column="user_id", related_name="settings",
    )
    theme = models.CharField(max_length=10, default="system")
    locale = models.CharField(max_length=10, default="en")
    show_read_receipts = models.BooleanField(default=True)
    show_online_status = models.BooleanField(default=True)
    discoverable = models.BooleanField(default=True)
    default_listing_type = models.CharField(max_length=10, null=True, blank=True)
    data_saver = models.BooleanField(default=False)
    quiet_hours_start = models.TimeField(null=True, blank=True)
    quiet_hours_end = models.TimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "user_settings"
        managed = False