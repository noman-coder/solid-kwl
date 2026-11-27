from django.apps import AppConfig


class AppConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'app'

    def ready(self):
        import app.signals
        import app.security.signals_security  
        import app.ledger.signals_gl
        import app.order_status_emails   # customer ko order status email
        import app.rider_push_signals    # rider ko push notification (order ready / assign)
        import app.vendor_push_signals   # vendor ko push notification (stock kam / khatam)
        import app.category_signals      # nayi Category -> master category khud (Gemini / keywords)
