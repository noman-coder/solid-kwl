"""Store location verification (blue tick) + customer location tests."""
from django.contrib.auth.models import User
from django.test import TestCase
from django.urls import reverse

from app.customer.geo import format_distance, haversine_km
from app.models import Vendor, VendorProfile


class GeoHelpersTest(TestCase):
    def test_haversine_zero(self):
        self.assertAlmostEqual(haversine_km(30.3, 71.9, 30.3, 71.9), 0, places=3)

    def test_format_distance(self):
        self.assertEqual(format_distance(2.34), '2.3 km')
        self.assertTrue(format_distance(0.43).endswith(' m'))


class CustomerLocationTest(TestCase):
    def test_set_location_saves_in_session(self):
        r = self.client.post(reverse('set_customer_location'), {'lat': '30.30', 'lng': '71.93', 'accuracy': '40'})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.client.session['customer_location']['lat'], 30.3)

    def test_bad_coordinates_rejected(self):
        r = self.client.post(reverse('set_customer_location'), {'lat': '500', 'lng': '71.93'})
        self.assertEqual(r.status_code, 400)


class VendorLocationVerifyTest(TestCase):
    def setUp(self):
        user = User.objects.create_user('v1', password='pw12345!')
        vendor = Vendor.objects.create(name='Test Store')
        self.profile = VendorProfile.objects.create(
            vendor=vendor, user=user, business_name='Test Store', is_approved=True)
        self.client.login(username='v1', password='pw12345!')
        self.url = reverse('vendor_location_verify')

    def test_privacy_page_opens(self):
        self.assertEqual(self.client.get(self.url).status_code, 200)

    def test_requires_consent(self):
        self.client.post(self.url, {'lat': '30.3', 'lng': '71.9', 'accuracy': '20'})
        self.profile.refresh_from_db()
        self.assertFalse(self.profile.location_verified)

    def test_saves_location_with_consent(self):
        self.client.post(self.url, {'consent': '1', 'lat': '30.3', 'lng': '71.9', 'accuracy': '20'})
        self.profile.refresh_from_db()
        self.assertTrue(self.profile.location_verified)
        self.assertEqual(self.profile.latitude, 30.3)
        self.assertIsNotNone(self.profile.location_consent_at)

    def test_poor_accuracy_rejected(self):
        self.client.post(self.url, {'consent': '1', 'lat': '30.3', 'lng': '71.9', 'accuracy': '5000'})
        self.profile.refresh_from_db()
        self.assertFalse(self.profile.location_verified)
