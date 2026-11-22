from django.db import transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import AnonRateThrottle
from rest_framework.views import APIView
from rest_framework_simplejwt.tokens import RefreshToken

from .models import User
from .serializers import (LoginSerializer, ProfileSerializer, RegisterSerializer,
                          UserSerializer, UserSettingsSerializer, find_user)


class AuthThrottle(AnonRateThrottle):
    """Slows down bots: 10 register/login tries per minute per device."""
    scope = "auth"
    rate = "10/min"


def tokens_for(user):
    refresh = RefreshToken.for_user(user)
    return {"refresh": str(refresh), "access": str(refresh.access_token)}


class RegisterView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]
    throttle_classes = [AuthThrottle]

    def post(self, request):
        serializer = RegisterSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        user = serializer.save()
        return Response(
            {"user": UserSerializer(user).data, "tokens": tokens_for(user)},
            status=status.HTTP_201_CREATED,
        )


class LoginView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]
    throttle_classes = [AuthThrottle]

    def post(self, request):
        serializer = LoginSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        user = find_user(serializer.validated_data["identifier"])
        if (user is None
                or not user.check_password(serializer.validated_data["password"])
                or not user.is_active):
            return Response({"detail": "Wrong login or password."},
                            status=status.HTTP_401_UNAUTHORIZED)
        User.objects.filter(pk=user.pk).update(last_login=timezone.now())
        return Response({"user": UserSerializer(user).data, "tokens": tokens_for(user)})


class MeView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return Response(UserSerializer(request.user).data)

    def patch(self, request):
        user = request.user
        profile = ProfileSerializer(user.profile, data=request.data.get("profile", {}), partial=True)
        settings = UserSettingsSerializer(user.settings, data=request.data.get("settings", {}), partial=True)
        profile.is_valid(raise_exception=True)
        settings.is_valid(raise_exception=True)
        with transaction.atomic():
            profile.save()
            settings.save()
        user.refresh_from_db()
        return Response(UserSerializer(user).data)