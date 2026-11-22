from django.urls import path

from . import photo_views, search, views

urlpatterns = [
    path("me/start-posting/", views.StartPostingView.as_view()),
    path("me/listings/", views.MyListingsView.as_view()),
    path("search/", search.SearchView.as_view()),
    path("listings/", views.ListingsView.as_view()),
    path("listings/<uuid:listing_id>/", views.ListingDetailView.as_view()),
    path("listings/<uuid:listing_id>/photos/", photo_views.PhotosView.as_view()),
    path("listings/<uuid:listing_id>/photos/<uuid:photo_id>/",
         photo_views.PhotoDetailView.as_view()),
    path("listings/<uuid:listing_id>/photos/<uuid:photo_id>/primary/",
         photo_views.PhotoPrimaryView.as_view()),
    path("listings/<uuid:listing_id>/<str:action>/", views.ListingActionView.as_view()),
]