from django.urls import path

from . import views

urlpatterns = [
    path("property-types/", views.PropertyTypesView.as_view()),
    path("areas/", views.AreasView.as_view()),
    path("currencies/", views.CurrenciesView.as_view()),
]