import json
import os

from django.contrib import admin
from django.urls import path, include, re_path
from django.conf import settings
from django.http import JsonResponse, Http404
from django.shortcuts import redirect
from django.views.static import serve
from app import pwa_views

# Custom Handlers
handler404 = 'app.views.custom_page_not_found'
handler500 = 'app.views.custom_server_error'


def assetlinks(request):
    """Android TWA (Play Store) verification file, always public."""
    file_path = os.path.join(settings.BASE_DIR, 'assetlinks.json')
    if not os.path.exists(file_path):
        raise Http404("assetlinks.json not found")
    with open(file_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    return JsonResponse(data, safe=False)


urlpatterns = [
    # PWA: own manifest + service worker (keep FIRST, always public)
    path('manifest.json', pwa_views.pwa_manifest, name='pwa_manifest'),
    path('pwa-icons/<str:name>.png', pwa_views.pwa_icon, name='pwa_icon'),
    path('serviceworker.js', pwa_views.pwa_service_worker, name='pwa_serviceworker'),

    # Play Store (TWA) verification, keep public
    path('.well-known/assetlinks.json', assetlinks, name='assetlinks'),

    # Admin Panel
    path('admin/', admin.site.urls),

    # Frontend (All app URLs)
    path('', include('app.urls')),

    # CEO Module
    path('ceo/', include('ceo_module.urls')),

    # Progressive Web App (PWA) URLs
    path('', include('pwa.urls')),

    # Redirect /accounts/login/ to /login/
    path('accounts/login/', lambda request: redirect('/login/')),

    # GET logout redirect (Django 5.x fix)
    path('accounts/logout/', lambda request: redirect('/logout-redirect/')),
    path('logout-redirect/', lambda request: redirect('/login/'), name='logout_redirect'),
]

# Force-serve media and static files in CI/CD Runner & Cloudflare Tunnel
urlpatterns += [
    re_path(r'^media/(?P<path>.*)$', serve, {'document_root': settings.MEDIA_ROOT}),
    re_path(r'^static/(?P<path>.*)$', serve, {'document_root': settings.STATIC_ROOT}),
]